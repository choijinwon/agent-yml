# Argo Python Image Build WorkflowTemplate

폐쇄망 환경에서 Bitbucket Source와 Nexus PyPI Wheel을 사용해 원격 BuildKit으로 Python 이미지를 빌드하고 Harbor에 Push하는 Argo WorkflowTemplate이다.
Nexus 다운로드는 병목이 아닌 것으로 확인되어 별도 속도 체크 Task는 제거했고, Dependency Image Cache와 BuildKit Layer Cache 중심으로 배포 시간을 줄인다.

## 주요 파일

- `workflowtemplate.yaml`: Kubernetes/Argo 적용용 YAML
- `workflowtemplate.json`: YAML과 의미상 동일한 적용용 표준 JSON
- `workflowtemplate.annotated.jsonc`: 주요 Parameter, Volume, Task, Template 설명이 포함된 검토용 JSONC
- `secrets.yaml`, `secrets.json`: Harbor와 Bitbucket Secret 예시; Nexus 다운로드는 익명 접근
- `nexus-concurrency-limit.yaml`, `nexus-concurrency-limit.json`: Nexus Wheel 다운로드 동시성 제한
- `build-tools/`: Dockerfile Template, Build Spec Schema 및 검증 Script
- `docs/argo-workflow-current-issues-meeting-preread-3pages.pptx`: 미팅 전 공유용 현재 이슈 3장 보고서
- `DELIVERABLE.md`: 전체 매니페스트와 운영 설명 통합본

## 적용 전 필수 작업

`CHANGE_ME`와 `sha256:000...000` 자리표시자를 실제 내부 주소, StorageClass 및 이미지 Digest로 모두 교체해야 한다. Harbor와 Bitbucket 인증정보는 Git에 커밋하지 말고 운영 Secret 관리 시스템을 통해 주입한다. Nexus PyPI 다운로드에는 인증정보를 사용하지 않는다.

```bash
kubectl apply -f secrets.yaml
kubectl apply -f nexus-concurrency-limit.yaml
kubectl apply -f workflowtemplate.yaml
```

`workflowtemplate.annotated.jsonc`는 주석이 포함되어 Kubernetes에 직접 적용할 수 없다. 적용에는 `workflowtemplate.json` 또는 YAML을 사용한다.

## 검증

```bash
ruby generate_jsonc.rb
ruby verify_manifests.rb
python3 -m py_compile build-tools/scripts/*.py
```
