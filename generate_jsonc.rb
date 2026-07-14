#!/usr/bin/env ruby
require "json"

SOURCE = "workflowtemplate.json"
TARGET = "workflowtemplate.annotated.jsonc"

PARAMETER_COMMENTS = {
  "bitbucket-address-user-code" => "빌드할 애플리케이션의 내부 Bitbucket Git 주소",
  "runtime-image" => "반드시 @sha256:<64 hex>로 고정한 Python Runtime 이미지",
  "nexus-pypi-url" => "외부 PyPI 대신 사용할 내부 Nexus Simple Index URL",
  "registry-address" => "최종 이미지를 Push할 내부 Harbor 주소",
  "registry-project" => "Harbor 내 애플리케이션 프로젝트 이름",
  "image-tag" => "최종 이미지 Tag; Digest는 BuildKit Metadata에서 별도로 기록",
  "cache-registry-address" => "Workflow 간 BuildKit Layer를 재사용할 Harbor Cache 경로",
  "buildkit-address" => "원격 BuildKit daemon 주소",
  "python-abi" => "Dependency Image Cache Key에 포함할 Python ABI(예: cp311)",
  "target-platform" => "Dependency Image Cache Key에 포함할 OS-Architecture(예: linux-amd64)",
  "force-rebuild-dependencies" => "true이면 기존 Dependency Image가 있어도 강제로 재생성",
  "notification-server-url" => "Build Report POST 대상; 빈 문자열이면 알림 생략"
}.freeze

TASK_COMMENTS = {
  "get-repository-name-from-git" => "Git URL에서 안전한 Repository 이름 추출",
  "clone-source" => "SSH Secret을 사용해 Source를 Workspace PVC로 Shallow Clone",
  "validate-runtime-image" => "Runtime 이미지가 Digest 고정 형식인지 검증",
  "validate-lock" => "requirements.lock 우선 탐색 및 SHA-256 계산",
  "check-dependency-image" => "Lock·Runtime·ABI·Platform Key로 Harbor Dependency Image 조회",
  "download-wheels" => "Dependency Cache MISS일 때만 Nexus에서 Wheel 다운로드",
  "prepare-build-context" => "Source·Wheel·Lock과 Dependency Image Stage를 조합해 BuildKit Context 생성",
  "build-dependency-image" => "Cache MISS일 때만 Dependency Image 생성 후 Digest 고정",
  "build-release-image" => "단일 BuildKit 호출로 test를 실행한 뒤 release Target을 Harbor에 Push",
  "parse-image-digest" => "BuildKit 결과에서 sha256 Digest를 엄격하게 추출",
  "generate-build-report" => "빌드·Wheel·Dependency Cache 지표를 Build Report JSON으로 집계",
  "notify-build-result" => "알림 URL이 있으면 Build Report를 재시도 포함 POST"
}.freeze

TEMPLATE_COMMENTS = TASK_COMMENTS.merge(
  "main" => "Workflow 전체 의존 관계와 병렬 실행 경로를 정의하는 Main DAG"
).freeze

VOLUME_COMMENTS = {
  "workspace" => "Task Pod 사이에서 Source·Wheelhouse·생성물·Report를 공유하는 Workflow 전용 RWX PVC",
  "registry-auth" => "Harbor Pull/Push 및 Registry Cache 인증용 Docker config Secret",
  "bitbucket-ssh" => "Bitbucket Private Key와 검증된 known_hosts를 제공하는 Secret",
}.freeze

KEY_COMMENTS = {
  '"metadata": {' => "현재 Kubernetes 객체의 이름·Namespace 등 식별 정보",
  '"spec": {' => "현재 객체의 실행 또는 리소스 사양",
  '"arguments": {' => "Workflow 또는 Task에 전달하는 Parameter 묶음",
  '"volumeClaimTemplates": [' => "각 Workflow 실행마다 생성되는 공유 Workspace PVC",
  '"volumes": [' => "외부 시스템 인증을 Pod에 제공하는 Secret Volume",
  '"templates": [' => "Main DAG와 실제 실행 Script Template 전체 목록",
  '"dag": {' => "Task의 의존 관계와 병렬 실행 구조",
  '"tasks": [' => "12개 Workflow Task; Dependency Image Cache와 depends 조건으로 실행 순서 제어",
  '"synchronization": {' => "ConfigMap Semaphore를 사용해 Nexus 동시 다운로드 수 제한",
  '"inputs": {' => "Task가 arguments.parameters로 전달받는 입력",
  '"outputs": {' => "후속 Task가 참조할 Parameter 및 Artifact",
  '"script": {' => "별도 Pod에서 실행되는 내부 Harbor 이미지와 Shell Script",
  '"volumeMounts": [' => "현재 Script가 사용할 PVC 또는 Secret Mount"
}.freeze

lines = File.readlines(SOURCE, chomp: true)
output = [
  "// 주의: JSONC는 설명/검토용이다. kubectl/argo 적용에는 workflowtemplate.json을 사용한다.",
  "// 이 파일에서 주석 전용 행을 제거하면 workflowtemplate.json과 의미상 완전히 동일하다."
]

lines.each do |line|
  stripped = line.strip
  indent = line[/\A */].size

  if (comment = KEY_COMMENTS[stripped])
    output << "#{' ' * indent}// #{comment}"
  end

  if (match = stripped.match(/\A"name": "([^"]+)"/))
    name = match[1]
    comment = case indent
              when 10
                PARAMETER_COMMENTS[name] || VOLUME_COMMENTS[name]
              when 14
                TASK_COMMENTS[name]
              when 8
                TEMPLATE_COMMENTS[name] || VOLUME_COMMENTS[name]
              end
    output << "#{' ' * indent}// #{comment}" if comment
  end

  output << line
end

File.write(TARGET, output.join("\n") + "\n")

# JSONC에서 Codex가 생성한 주석 전용 행만 제거한 뒤 원본과 Deep Equality를 확인한다.
stripped_jsonc = output.reject { |line| line.lstrip.start_with?("//") }.join("\n")
raise "JSONC content differs from source JSON" unless JSON.parse(stripped_jsonc) == JSON.parse(File.read(SOURCE))

puts "generated #{TARGET}; comment-stripped content matches #{SOURCE}"
