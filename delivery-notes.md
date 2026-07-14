## 8. Runtime Contract 기준 정의

AI/ML 환경에서는 같은 Docker 이미지인지보다 같은 Runtime Contract인지가 더 중요하다. Training, Batch Job, Serving, Inference가 아래 기준을 공유하면 같은 실행 환경에서 동작한다고 판단한다.

- Runtime Image Digest: 공통 Runtime Contract 이미지는 반드시 `@sha256:` digest로 고정한다.
- OS Base Digest: 배포판, glibc, 시스템 패키지 기준이 동일해야 한다.
- Accelerator ABI: GPU Driver 호환성, CUDA/ROCm, cuDNN, NCCL 같은 가속기 ABI 기준이 동일해야 한다.
- Language Runtime: Python 버전, Python ABI, pip/uv 같은 패키지 실행 기준이 동일해야 한다.
- ML Framework: PyTorch, TensorFlow, vLLM, Triton 등 핵심 ML Framework와 ABI가 동일해야 한다.
- ML Ops Common: 로깅, 모니터링, 인증, 인증서, 공통 유틸리티, 사내 CA Trust 기준이 동일해야 한다.
- Target Platform: OS/Architecture와 가속기 대상 플랫폼이 동일해야 한다.
- Security and Path Contract: 실행 UID/GID, 기본 작업 디렉터리, 환경 변수, 모델/프로젝트 배치 경로가 동일해야 한다.

따라서 운영 방향은 Training/Job/Serving/Inference 이미지를 하나로 합치는 것이 아니라, digest로 고정한 Runtime Contract 위에 `workload-role=train|job|serve|infer` Role Head와 Project/App Layer만 얇게 추가하고, 모델은 외부 Artifact Reference로 관리하는 것이다.

## 9. 추천 이미지 계층구조

운영 이미지는 아래 계층을 기준으로 관리한다. L0~L5는 공통 Runtime Contract의 기준이며, L6 이후만 워크로드와 프로젝트 특성에 따라 얇게 분리한다.

| Layer | 이름 | 포함 항목 | 운영 원칙 |
|---|---|---|---|
| L0 | Source Base | Ubuntu, Debian, UBI, NVIDIA CUDA 등 외부 원천 이미지 | 반드시 digest pin |
| L1 | OS Foundation | OS 패키지, glibc, CA Trust, timezone, 기본 보안 패키지 | 변경 주기 낮게 관리 |
| L2 | Accelerator ABI | CUDA/ROCm, cuDNN, NCCL, GPU Driver 호환 ABI | GPU 노드/드라이버와 호환성 고정 |
| L3 | Language Runtime | Python, Python ABI, uv/pip, 기본 런타임 도구 | ABI 단위로 고정 |
| L4 | ML Framework | PyTorch, TensorFlow, vLLM, Triton 등 | Framework/Accelerator ABI 조합 고정 |
| L5 | ML Ops Common | logging, metrics, tracing, auth, cert, 사내 CA, 공통 유틸리티 | 조직 공통 운영 기준으로 관리 |
| L6 | Role Head | train / job / serve / infer 역할별 실행 Head | 역할 차이만 얇게 추가 |
| L7 | Project / App | 프로젝트 코드, API/Batch 진입점, 설정 | 소스 변경 중심 레이어 |
| L8 | Model Artifact Reference | model weights, tokenizer, config 같은 실제 모델 파일의 외부 위치와 Artifact Contract | 모델 파일은 기본적으로 이미지에 포함하지 않고 배포 Runtime에서 주입 |

이 구조에서 “같은 환경”은 L0~L5 Runtime Contract와 Target Platform/Python ABI/Security Contract가 같은 경우를 의미한다. L6~L7은 역할과 프로젝트 차이를 표현하는 얇은 계층이고, L8은 모델 파일을 이미지에 넣는 계층이 아니라 외부 Model Artifact Reference와 Contract를 기록하는 계층이다.

## 10. Runtime Lineage 관리 원칙

이미지 이름을 업무명 중심으로 만들면 Training, Batch Job, Serving, Inference가 늘어날수록 이름과 저장소가 빠르게 복잡해진다. 운영 이미지는 업무명이 아니라 Runtime Lineage, Role, Project/App 순서로 관리한다.

권장 이미지 명명 규칙:

```text
<registry>/<registry-project>/<runtime-lineage>/<workload-role>/<project-app>:<tag>
```

예시:

```text
harbor.internal/applications/python311-cuda124/train/recommendation-trainer:2026.07.14
harbor.internal/applications/python311-cuda124/serve/recommendation-api:2026.07.14
harbor.internal/applications/python311-cpu/job/feature-batch:2026.07.14
harbor.internal/applications/python311-cuda124/infer/reranker-model:2026.07.14
```

이 구조에서 `runtime-lineage`는 Runtime Contract 계열을 나타낸다. 예를 들어 `python311-cuda124`, `python311-cpu`, `python310-rocm6`처럼 Python/Accelerator/Framework 호환 계열을 표현한다. `workload-role`은 `train`, `job`, `serve`, `infer` 중 하나로 제한하고, 마지막 경로에는 프로젝트 또는 앱 이름을 둔다.

현재 WorkflowTemplate의 최종 이미지 경로는 아래 형식으로 생성된다.

```text
{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/{{workflow.parameters.runtime-lineage}}/{{workflow.parameters.workload-role}}/{{repository-name}}:{{workflow.parameters.image-tag}}
```

BuildKit Registry Cache도 같은 계열/역할/프로젝트 기준으로 분리한다.

```text
{{workflow.parameters.cache-registry-address}}/{{workflow.parameters.runtime-lineage}}/{{workflow.parameters.workload-role}}/{{repository-name}}:buildcache
```

## 11. Training/Serving 관계 패턴

Training과 Serving은 무조건 하나의 이미지로 합치지 않고, 모델 실행 방식에 따라 두 가지 패턴으로 나눈다.

| 패턴 | 적용 대상 | 운영 기준 |
|---|---|---|
| 패턴 A: 엄격한 환경 동일성(`strict`) | PyTorch, TensorFlow, Scikit-learn, custom Python 모델처럼 학습 코드와 추론 코드가 같은 Python Runtime을 써야 하는 경우 | Training/Job/Serving/Inference가 동일한 Runtime Contract Digest와 Python ABI, ML Framework, Accelerator ABI를 공유한다. |
| 패턴 B: 최적화 Inference Runtime(`optimized`) | Triton, TensorRT, vLLM, ONNX Runtime 같은 추론 서버 Runtime을 사용하는 경우 | Serving 환경은 학습 환경과 완전히 같지 않을 수 있다. 대신 모델 산출물의 Artifact Contract와 검증 파이프라인을 필수로 둔다. |

Triton은 NGC의 pre-built Docker Image와 Model Repository 구조를 기준으로 모델을 서빙할 수 있다. 이 경우 운영상 중요한 기준은 “학습 이미지와 서빙 이미지가 같은가”가 아니라, 학습 결과물이 서빙 Runtime의 Artifact Contract를 만족하는지와 배포 전 검증이 통과되는지다.

현재 WorkflowTemplate은 아래 세 파라미터로 이 관계를 명시한다.

```text
training-serving-pattern = strict | optimized
inference-server-runtime = python-runtime | triton | tensorrt | vllm | onnxruntime | custom
artifact-contract-file   = artifact-contract.json
```

`optimized` 패턴은 `workload-role=serve|infer`에서만 허용한다. 또한 Source 안에 `artifact-contract-file`이 존재하지 않으면 Build Context 생성 단계에서 실패시킨다. 즉 성능 최적화 Serving을 선택할수록 Runtime 동일성보다 Artifact Contract와 검증 파이프라인을 더 강하게 관리한다.

## 12. 선언형 Docker Image Builder Spec

Docker Image는 프로젝트마다 사람이 Dockerfile을 직접 관리하는 방식으로 운영하지 않는다. 중앙 Image Builder 카테고리를 선언형 Spec으로 두고, WorkflowTemplate은 그 Spec을 기준으로 Dockerfile, 레이어 정책, 검증 규칙, Build Report 메타데이터를 생성한다.

현재 WorkflowTemplate은 아래 파라미터를 사용한다.

```text
image-builder-category  = ai-ml-python
image-builder-spec-file = image-builder.spec.json
```

`prepare-build-context` 단계는 Build Context 안에 `image-builder.spec.json`을 생성하고, 최종 이미지에도 `/image-builder/image-builder.spec.json`으로 포함한다. 이 Spec에는 다음 내용이 들어간다.

- Builder Mode: `declarative-spec`
- 중앙 카테고리: `ai-ml-python`
- Runtime Lineage, Workload Role, Training/Serving Pattern
- L0~L8 Layer 정책
- Runtime Digest 고정, Role 값 제한, optimized Serving의 Artifact Contract 필수 검증
- 프로젝트별 수동 Dockerfile 관리 금지(`manualDockerfilePerProject=false`)

즉 운영 기준은 “각 프로젝트 Dockerfile을 누가 어떻게 수정했는가”가 아니라, “중앙 선언형 Image Builder Spec과 Runtime Contract를 만족하는가”로 바뀐다. 이 구조가 있어야 Training, Batch Job, Serving, Inference 이미지가 늘어나도 레이어 정책과 검증 기준이 흩어지지 않는다.

## 13. Dockerfile multi-stage + target 구조

Dockerfile은 단일 거대 빌드가 아니라 multi-stage + target 구조로 운영한다. 목적은 변경 빈도가 낮은 Runtime/Dependency 계층과 변경 빈도가 높은 Project/Model 계층을 분리하고, 필요한 Target만 BuildKit이 선택적으로 빌드하게 만드는 것이다.

현재 WorkflowTemplate의 Dockerfile Stage는 다음 순서다.

```text
runtime-contract
  → dependency-image
  → dependencies
  → role-head
  → test
  → project-app
  → model-artifact
  → release
```

Build Target은 역할별로 분리한다.

| Target | 용도 | Push 여부 |
|---|---|---|
| `dependency-image` | Lock Hash + Runtime Digest 기준 Dependency Image 생성 | Harbor Dependency Cache에 Push |
| `test` | 최종 이미지에 포함되기 전 compile/test 강제 실행 | Push하지 않음 |
| `release` | Project/App과 외부 Model Artifact Reference 계약을 포함한 최종 배포 이미지 | Harbor Application Repository에 Push |

Release Target은 `test` Stage의 성공 표식(`/test-passed`)을 복사하므로 테스트가 통과하지 않으면 최종 이미지가 생성되지 않는다. 운영 원칙은 “여러 Dockerfile을 따로 관리”가 아니라 “하나의 선언형 Builder Spec에서 Stage/Target을 고정하고, BuildKit Target만 선택”하는 방식이다.

## 14. 모델 Artifact 외부화 원칙

모델 파일은 기본적으로 Docker 이미지에 넣지 않는다. 모델은 코드보다 용량이 크고 교체 주기가 다르며, 이미지에 포함하면 Build Context 전송, BuildKit Cache, Harbor Push/Pull, 배포 Rollout 시간이 모두 커진다. 따라서 기본 운영 단위는 “앱 이미지 + 외부 모델 Artifact”로 분리한다.

현재 WorkflowTemplate은 아래 정책을 기본값이자 허용값으로 사용한다.

```text
model-artifact-policy    = external
model-artifact-reference = <PVC, Object Storage, Model Registry, Triton Model Repository 등 외부 위치>
```

구현상 `prepare-build-context` 단계의 `.dockerignore`에서 아래 디렉터리를 Build Context에서 제외한다.

```text
app/model
app/models
app/model-artifacts
```

최종 이미지의 L8 Stage는 모델 파일을 복사하지 않고, `/model-artifacts/README.txt`에 “모델은 배포 Runtime에서 주입한다”는 계약만 남긴다. Serving/Inference 배포 시에는 PVC, Object Storage, Model Registry, Triton Model Repository 같은 외부 저장소를 통해 모델을 주입한다.

예외적으로 모델을 이미지에 넣어야 하는 경우는 별도 승인된 Builder Category와 별도 Policy로 분리해야 한다. 현재 기본 템플릿은 `embedded` 모델을 허용하지 않는다.

## 15. Builder 보안·재현성 필수 기능

보안과 재현성은 Builder의 선택 기능이 아니라 필수 통과 조건이다. 이미지가 빠르게 만들어져도 같은 입력에서 같은 결과를 재현할 수 없거나, 운영 보안 기준을 우회할 수 있으면 배포 가능한 이미지로 보지 않는다.

현재 WorkflowTemplate은 `image-builder.spec.json`, `build-spec.json`, Build Report에 아래 정책을 모두 기록한다.

```json
{
  "securityReproducibilityPolicy": {
    "required": true,
    "runtimeDigestPinned": true,
    "dependencyDigestPinned": true,
    "lockHashRequired": true,
    "noLatestTags": true,
    "nonRootUserRequired": true,
    "modelExternalByDefault": true,
    "buildReportRequired": true,
    "reproducibilityKey": "runtimeDigest+lockHash+pythonAbi+targetPlatform+builderSpec"
  }
}
```

필수 체크는 다음과 같다.

| 구분 | 필수 조건 | 현재 반영 방식 |
|---|---|---|
| Runtime 재현성 | Runtime 이미지는 반드시 `@sha256:` Digest로 고정 | `validate-runtime-image`에서 형식 검증 |
| Dependency 재현성 | Dependency Image는 Lock Hash + Runtime Digest + Python ABI + Target Platform 기준 | Dependency Cache Key와 Digest Reference 생성 |
| Source 재현성 | Dependency Lock Hash 기록 | `validate-lock`에서 SHA-256 산출 |
| Image 결과 재현성 | 최종 Image Digest 기록 | BuildKit metadata에서 `imageDigest` 추출 |
| 실행 보안 | non-root 사용자 실행 | Dockerfile `USER 10001:10001` |
| Tag 정책 | `latest` 금지와 내부 이미지 Digest Pin | `verify_manifests.rb` 검증 |
| 모델 보안 | 모델 파일은 이미지에 미포함 | `model-artifact-policy=external`과 `.dockerignore` |
| 감사 가능성 | Build Report 생성 필수 | `generate-build-report`에서 정책과 결과 기록 |

Build Spec 검증 스크립트도 `securityReproducibilityPolicy`와 `securityReproducibilityChecks`를 검사한다. 따라서 Builder를 확장하더라도 Digest Pin, Lock Hash, non-root, 모델 외부화, Build Report 같은 기준이 빠지면 검증 단계에서 실패하도록 설계한다.

## 16. BuildKit Registry Cache 설명

PVC와 Registry Cache의 수명과 목적을 분리했다.

- `workspace` PVC: 현재 Workflow의 `/workspace/generated/context`, `/workspace/generated`, `/workspace/output`을 Pod 사이에서 공유한다. Source와 Wheelhouse를 처음부터 Build Context 하위에 생성해 중간 전체 복사를 제거한다.
- Runtime Contract: Training, Batch Job, Serving, Inference 이미지를 하나로 합치지 않는다. OS Base, Accelerator ABI, Language Runtime, ML Framework, ML Ops Common을 포함한 공통 Runtime Contract 이미지를 `@sha256:` digest로 고정하고, `workload-role=train|job|serve|infer` 값으로 얇은 Role Head만 분기한다.
- Harbor Dependency Image: `requirements.lock SHA-256 + Runtime Digest + Python ABI + Target Platform`을 Key로 `/python-deps:<key>`를 조회한다. HIT이면 Nexus 다운로드와 `pip install`을 생략하고 Harbor Digest로 고정해 재사용한다. MISS이면 Mutex 획득 후 다시 조회하고 한 번만 생성한다.
- Nexus: 다운로드 시간이 짧은 것으로 확인되어 별도 속도 체크 Task는 제거했다. 병목 분석은 BuildKit 실행, Dependency Image 생성, Layer Cache 재사용 여부에 집중한다.
- Harbor Registry Cache: 단일 Release Build에서 Registry Cache를 Import하고 `--export-cache type=registry,ref=...,mode=min`으로 애플리케이션 레이어만 갱신한다. Release Stage가 Test Stage의 성공 표식을 의존하므로 별도의 Test BuildKit 호출 없이 테스트가 강제된다.
- Harbor Application Repository: `harbor.CHANGE_ME.internal/applications/<runtime-lineage>/<workload-role>/<repository>:<tag>`에 `release` Target만 Push한다. 배포와 기록에는 BuildKit metadata에서 얻은 Digest를 함께 사용한다.

Cache Repository에는 애플리케이션 배포 보존 정책과 다른 정리 정책을 적용해야 한다. 여러 빌드가 같은 `:buildcache` Tag를 동시에 갱신할 수 있으므로, 충돌이 문제라면 브랜치/플랫폼별 Cache Tag를 추가한다.

## 17. 주요 Task 실행 흐름

```text
get-repository-name-from-git ─→ clone-source ─→ validate-lock ─┐
validate-runtime-image ─────────────────────────────────────────┼→ check-dependency-image
                                                                              ↓
                        download-wheels(HIT이면 생략) → prepare-build-context
                                                                              ↓
        Runtime Contract(L0~L5) → Role Head(L6) → Project/App(L7) → Model Artifact Reference(L8)
                                                                              ↓
                              build-dependency-image(HIT이면 재사용)
                                                                                              │
validate-runtime-image ───────────────────────────────────────────────────────────────────────┤
                                                                                              ↓
→ build-release-image(test 포함) → parse-image-digest
    → generate-build-report → notify-build-result
```

`get-repository-name-from-git`, `clone-source`, `validate-runtime-image`가 병렬로 시작된다. Nexus 다운로드는 이미 짧은 구간으로 확인했으므로 별도 진단 Task를 두지 않는다. Dependency Image HIT이면 Nexus 다운로드와 Dependency Build를 생략한다. MISS이면 Nexus에서 Wheel을 받고 Lock Hash 단위 Mutex 안에서 Harbor를 재조회한 뒤 Dependency Image를 생성한다. Release Build는 digest 고정 Runtime Contract 위에 Role Head와 Project/App만 얇게 추가하고, 모델 파일은 이미지가 아니라 외부 Artifact Reference로 주입한다. Harbor 조회의 404/manifest unknown만 MISS로 취급하며 인증·네트워크·5xx 오류는 실패 처리한다.

## 18. Build Report JSON 예시

```json
{
  "workflowName": "python-build-abc12",
  "workflowUid": "12345678-1234-1234-1234-123456789012",
  "namespace": "argo",
  "repositoryName": "sample-api",
  "imageReference": "harbor.internal/applications/python311-cuda124/serve/sample-api:1.0.0",
  "imageDigest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "parentImageDigest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "runtimeImage": "harbor.internal/runtime/python311@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "runtimeLineage": "python311-cuda124",
  "imageNamingConvention": "<registry>/<project>/<runtime-lineage>/<workload-role>/<project-app>:<tag>",
  "workloadRole": "serve",
  "trainingServingPattern": "optimized",
  "inferenceServerRuntime": "triton",
  "artifactContractFile": "artifact-contract.json",
  "artifactContractRequired": true,
  "modelArtifactPolicy": "external",
  "modelArtifactReference": "s3://model-registry/sample-api/2026-07-14",
  "modelFilesEmbedded": false,
  "modelInjectionRequired": true,
  "imageBuilderMode": "declarative-spec",
  "imageBuilderCategory": "ai-ml-python",
  "imageBuilderSpecFile": "image-builder.spec.json",
  "builderSpecDriven": true,
  "manualDockerfilePerProject": false,
  "dockerfileStrategy": "multi-stage-target",
  "buildTargets": {
    "dependency": "dependency-image",
    "test": "test",
    "release": "release"
  },
  "releaseTarget": "release",
  "pushOnlyReleaseTarget": true,
  "releaseRequiresTestStage": true,
  "securityReproducibilityPolicy": {
    "required": true,
    "runtimeDigestPinned": true,
    "dependencyDigestPinned": true,
    "lockHashRequired": true,
    "noLatestTags": true,
    "nonRootUserRequired": true,
    "modelExternalByDefault": true,
    "buildReportRequired": true,
    "reproducibilityKey": "runtimeDigest+lockHash+pythonAbi+targetPlatform+builderSpec"
  },
  "securityReproducibilityChecks": [
    "runtime-image-digest-pinned",
    "dependency-image-digest-pinned",
    "lock-hash-recorded",
    "image-digest-recorded",
    "non-root-user",
    "model-external",
    "no-latest-tags",
    "build-report-generated"
  ],
  "recommendedImageLayers": [
    {"level": "L0", "name": "source-base"},
    {"level": "L1", "name": "os-foundation"},
    {"level": "L2", "name": "accelerator-abi"},
    {"level": "L3", "name": "language-runtime"},
    {"level": "L4", "name": "ml-framework"},
    {"level": "L5", "name": "ml-ops-common"},
    {"level": "L6", "name": "role-head"},
    {"level": "L7", "name": "project-app"},
    {"level": "L8", "name": "model-artifact-reference"}
  ],
  "lockFileName": "requirements.lock",
  "lockHash": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "wheelCount": 42,
  "wheelTotalBytes": 104857600,
  "wheelDownloadSeconds": 38,
  "averageDownloadBytesPerSecond": 2759410,
  "dependencyCacheStatus": "HIT",
  "dependencyCacheKey": "<lock-hash>-<runtime-digest>-cp311-linux-amd64",
  "dependencyImageReference": "harbor.internal/build-cache/python-deps@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  "dependencyImageResult": "REUSED",
  "dependencyBuildSeconds": 0,
  "buildSeconds": 74,
  "packageRepository": "nexus",
  "wheelOnly": true,
  "status": "SUCCEEDED",
  "timestamp": "2026-07-13T09:00:00Z"
}
```

## 19. 운영 환경에서 변경할 값 목록

| 위치 | 변경 값 |
|---|---|
| Workflow Parameter | Bitbucket URL, Runtime Contract Image와 실제 SHA-256, Runtime Lineage, Training/Serving 패턴, Inference Server Runtime, Artifact Contract 파일명, Model Artifact Policy/Reference, Image Builder Category, Image Builder Spec 파일명, Nexus URL, Harbor 주소/프로젝트, 이미지 Tag, Cache 주소, BuildKit 주소, Python ABI, Target Platform, Workload Role, Dependency 강제 재생성 여부, 알림 URL |
| Workflow Script Image | `python-tools`, `git-tools`, `curl-jq`, `python-build-tools`, `buildkit-client-tools`의 내부 Harbor 주소와 실제 SHA-256 |
| PVC | `CHANGE_ME-rwx-storage`, 용량, 필요 시 Access Mode |
| `registry-auth` | 실제 Harbor Host 및 자격 증명 |
| `bitbucket-ssh` | Private Key와 검증된 `known_hosts` Host Key |
| Nexus 다운로드 인증 | 익명 다운로드 사용, 별도 Secret 불필요 |
| ConfigMap | Nexus가 허용하는 동시 Wheel 다운로드 수 |
| Build Tools Dockerfile | 폐쇄망 내부 Python Base Image와 실제 SHA-256 |
| Dockerfile Template | 애플리케이션 실행 모듈/명령과 비-root UID가 실제 Runtime Image에 존재하는지 확인 |

`sha256:000...000`은 형식 검증을 통과시키기 위한 자리표시자일 뿐 실제 이미지가 아니므로 전부 교체해야 한다. `CHANGE_ME`가 하나라도 남은 상태로 배포하지 않는다.

## 20. YAML과 JSON 구조 일치 여부 확인표

| 대상 | 확인 결과 | 검증 방법 |
|---|---|---|
| WorkflowTemplate | 일치 | Ruby YAML 파싱 결과와 JSON 파싱 결과 Deep Equality |
| Task/Template 이름 | 일치 | 이름 중복 및 참조 대상 존재 검사 |
| Task Arguments/Template Inputs | 일치 | Parameter 이름 정렬 후 완전 일치 검사 |
| Volumes/Volume Mounts | 일치 | Mount가 선언된 Secret/PVC를 참조하는지 검사 |
| Secret List | 일치 | YAML/JSON Deep Equality |
| ConfigMap | 일치 | YAML/JSON Deep Equality |
| Script 안전 기본값 | 일치 | 모든 Script의 `set -euo pipefail` 검사 |
| 내부 이미지 고정 | 일치 | 모든 Script Image의 `@sha256:` 및 `latest` 미사용 검사 |

재검증 명령:

```bash
ruby verify_manifests.rb
python3 -m py_compile build-tools/scripts/*.py
```

## 21. 운영상 한계와 주의사항

- Argo Controller가 Output Artifact를 저장하려면 Namespace/Controller에 Artifact Repository가 구성되어 있어야 한다. 파일은 PVC에도 남지만 Artifact 업로드 설정이 없으면 Artifact Output 단계가 실패할 수 있다.
- `buildSeconds`는 Test Stage·Release Stage·Cache Export·Harbor Push를 포함한 단일 BuildKit 호출의 전체 시간이며 `push-seconds`는 호환성을 위해 `0`이다. 정확한 Push 시간 분리가 필요하면 Registry 이벤트/Telemetry를 결합해야 한다.
- 원격 BuildKit이 TLS/mTLS를 요구하면 BuildKit 인증용 Secret Volume과 `buildctl --tlscacert/--tlscert/--tlskey`를 추가해야 한다. 현재 요구사항에 그 Secret이 정의되지 않아 주소 및 사내 CA 신뢰가 Client Image에 준비됐다는 전제다.
- `buildkit-client-tools` 이미지에는 `buildctl`, `crane`, `jq`, `sha256sum`이 모두 포함되어야 한다. `crane`은 Harbor Dependency Image의 Digest 조회와 오류 분류에 사용한다.
- Dependency Image Tag는 Cache 조회에만 사용하고 애플리케이션 Build에는 항상 `@sha256:` Digest가 포함된 Reference를 전달한다. 보안 갱신 시 `force-rebuild-dependencies=true`로 재생성한다.
- `ReadWriteMany` StorageClass가 클러스터에 실제로 있어야 한다. NFS 계열 Storage에서는 소유권/성능/파일 잠금 정책도 확인한다.
- Secret 예시는 배포 구조를 보여주기 위한 자리표시자다. 실제 값은 Git에 저장하지 말고 External Secrets/Sealed Secrets/Vault 같은 운영 Secret 관리 경로로 주입한다.
- Bitbucket `known_hosts`는 `ssh-keyscan` 결과를 무검증으로 사용하지 말고 관리자가 별도 채널로 확인한 Host Key를 고정한다.
- NetworkPolicy로 Bitbucket, Nexus, Harbor, BuildKit, 알림 서버와 DNS 이외의 Egress를 차단해야 “외부 PyPI 접근 금지”를 인프라 계층에서도 강제할 수 있다.
- `requirements.lock`은 플랫폼/CPU/Python ABI에 맞는 Wheel만 포함해야 한다. `requirements.txt` fallback은 마이그레이션 경고를 내지만 운영에서는 정책 Admission으로 금지하는 편이 안전하다.
- Test Target은 `tests/`가 존재하면 `pytest`를 실행한다. `pytest`가 Lock에 포함되지 않는 조직은 전용 Test Lock 또는 테스트 실행 명령을 Build Tools Template에 반영해야 한다.
- 현재 로컬 환경에는 연결된 Kubernetes API와 Argo CRD Schema가 없어 서버 측 Dry Run은 수행하지 못했다. 실제 배포 전 대상 클러스터에서 `kubectl apply --server-side --dry-run=server`와 Argo 버전 호환성 검증이 필요하다.
