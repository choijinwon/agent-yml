# Argo Python Image Build WorkflowTemplate

폐쇄망 환경에서 Bitbucket Source와 Nexus PyPI Wheel을 사용해 원격 BuildKit으로 Python 이미지를 빌드하고 Harbor에 Push하는 Argo WorkflowTemplate이다.
Nexus 다운로드는 병목이 아닌 것으로 확인되어 별도 속도 체크 Task는 제거했고, Dependency Image Cache와 BuildKit Layer Cache 중심으로 배포 시간을 줄인다.
Training, Batch Job, Serving, Inference는 하나의 거대 이미지로 합치지 않고 digest 고정 Runtime Contract 위에 얇은 Role Head와 Project/App Layer만 추가한다.
같은 환경 여부는 Docker 이미지명이 아니라 Runtime Image Digest, OS Base, Accelerator ABI, Language Runtime, ML Framework, ML Ops Common, Target Platform, Python ABI, 보안/경로 계약이 같은지로 판단한다.
권장 이미지 계층은 L0 Source Base, L1 OS Foundation, L2 Accelerator ABI, L3 Language Runtime, L4 ML Framework, L5 ML Ops Common, L6 Role Head, L7 Project/App, L8 Model Artifact Reference 순서로 관리한다.
모델 파일은 기본적으로 Docker 이미지에 넣지 않는다. `model-artifact-policy=external`을 기본값으로 두고, `app/model`, `app/models`, `app/model-artifacts`는 Build Context에서 제외하며 배포 Runtime에서 PVC/Object Storage/Model Registry로 주입한다.
이미지 이름은 업무명 중심이 아니라 `<registry>/<project>/<runtime-lineage>/<workload-role>/<project-app>:<tag>` 형식의 Runtime Lineage 기준으로 관리한다.
Training/Serving 관계는 `strict`와 `optimized` 두 패턴으로 구분한다. `strict`는 PyTorch/TensorFlow/Scikit-learn/custom Python처럼 학습·추론이 같은 Python Runtime Contract를 공유하는 방식이고, `optimized`는 Triton/TensorRT/vLLM/ONNX Runtime처럼 추론 서버 Runtime을 분리하되 Artifact Contract와 검증 파이프라인을 필수로 두는 방식이다.
Docker Image Builder는 프로젝트별 Dockerfile을 사람이 직접 관리하는 방식이 아니라, 중앙 선언형 `image-builder.spec.json`과 `image-builder-category` 기준으로 레이어 정책, 검증 규칙, Report 메타데이터를 생성하는 방식이다.
Dockerfile은 multi-stage + target 구조로 운영한다. Dependency 전용 Target은 `dependency-image`, 테스트 포함 최종 배포 Target은 `release`이며 Harbor에는 `release` Target만 Push한다.
보안과 재현성은 Builder의 필수 기능이다. Runtime/Dependency Digest Pin, Lock Hash, non-root 실행, `latest` 금지, 모델 외부화, Build Report 생성을 `securityReproducibilityPolicy`로 기록하고 검증한다.

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
