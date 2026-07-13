# Argo Python Image Build WorkflowTemplate

폐쇄망 환경에서 Bitbucket Source와 Zeus PyPI Wheel을 사용해 원격 BuildKit으로 Python 이미지를 빌드하고 Harbor에 Push하는 Argo WorkflowTemplate이다.

## 주요 파일

- `workflowtemplate.yaml`: Kubernetes/Argo 적용용 YAML
- `workflowtemplate.json`: YAML과 의미상 동일한 적용용 표준 JSON
- `workflowtemplate.annotated.jsonc`: 주요 Parameter, Volume, Task, Template 설명이 포함된 검토용 JSONC
- `secrets.yaml`, `secrets.json`: Harbor, Bitbucket, Zeus Secret 예시
- `zeus-concurrency-limit.yaml`, `zeus-concurrency-limit.json`: Zeus Wheel 다운로드 동시성 제한
- `build-tools/`: Dockerfile Template, Build Spec Schema 및 검증 Script
- `docs/argo-workflow-current-issues-meeting-preread-3pages.pptx`: 미팅 전 공유용 현재 이슈 3장 보고서
- `DELIVERABLE.md`: 전체 매니페스트와 운영 설명 통합본

## 적용 전 필수 작업

`CHANGE_ME`와 `sha256:000...000` 자리표시자를 실제 내부 주소, StorageClass 및 이미지 Digest로 모두 교체해야 한다. Secret 예시의 실제 인증정보는 Git에 커밋하지 말고 운영 Secret 관리 시스템을 통해 주입한다.

```bash
kubectl apply -f secrets.yaml
kubectl apply -f zeus-concurrency-limit.yaml
kubectl apply -f workflowtemplate.yaml
```

`workflowtemplate.annotated.jsonc`는 주석이 포함되어 Kubernetes에 직접 적용할 수 없다. 적용에는 `workflowtemplate.json` 또는 YAML을 사용한다.

## 검증

```bash
ruby generate_jsonc.rb
ruby verify_manifests.rb
python3 -m py_compile build-tools/scripts/*.py
```
