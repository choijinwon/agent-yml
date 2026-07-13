## 9. BuildKit Registry Cache 설명

PVC와 Registry Cache의 수명과 목적을 분리했다.

- `workspace` PVC: 현재 Workflow의 `/workspace/source`, `/workspace/wheelhouse`, `/workspace/generated`, `/workspace/output`을 Pod 사이에서 공유한다. Workflow가 삭제되면 PVC도 Workflow 소유권에 따라 정리되는 전용 작업 공간이다.
- Harbor Registry Cache: `harbor.CHANGE_ME.internal/build-cache/<repository>:buildcache`에 BuildKit 레이어를 저장해 다음 Workflow에서 재사용한다. 두 빌드 모두 `--import-cache type=registry,ref=...`를 사용하고, `--export-cache type=registry,ref=...,mode=max`로 갱신한다.
- Harbor Application Repository: `harbor.CHANGE_ME.internal/applications/<repository>:<tag>`에 `release` Target만 Push한다. 배포와 기록에는 BuildKit metadata에서 얻은 Digest를 함께 사용한다.

Cache Repository에는 애플리케이션 배포 보존 정책과 다른 정리 정책을 적용해야 한다. 여러 빌드가 같은 `:buildcache` Tag를 동시에 갱신할 수 있으므로, 충돌이 문제라면 브랜치/플랫폼별 Cache Tag를 추가한다.

## 10. 주요 Task 실행 흐름

```text
get-repository-name-from-git ─→ clone-source ─→ validate-lock
                                               │
validate-runtime-image                         │
                                               ├─→ download-wheels ─┬→ verify-wheelhouse ─┐
report-zeus-connectivity ──────────────────────┘                    └→ report-zeus-after-download
                                                                                              │
validate-runtime-image ───────────────────────────────────────────────────────────────────────┤
                                                                                              ↓
prepare-build-context → build-test-target → build-release-image → parse-image-digest
    → generate-build-report → notify-build-result
```

`get-repository-name-from-git`, `validate-runtime-image`, `report-zeus-connectivity`는 동시에 시작한다. `verify-wheelhouse`와 `report-zeus-after-download`도 Wheel 다운로드 직후 병렬로 실행한다. Zeus Wheel 다운로드 Task는 `zeus-concurrency-limit/wheel-downloads` 세마포어를 사용한다.

## 11. Build Report JSON 예시

```json
{
  "workflowName": "python-build-abc12",
  "workflowUid": "12345678-1234-1234-1234-123456789012",
  "namespace": "argo",
  "repositoryName": "sample-api",
  "imageReference": "harbor.internal/applications/sample-api:1.0.0",
  "imageDigest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "parentImageDigest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "runtimeImage": "harbor.internal/runtime/python311@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "lockFileName": "requirements.lock",
  "lockHash": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "wheelCount": 42,
  "wheelTotalBytes": 104857600,
  "wheelDownloadSeconds": 38,
  "averageDownloadBytesPerSecond": 2759410,
  "zeusBeforeDownloadTotalSeconds": 0.421,
  "zeusAfterDownloadTotalSeconds": 1.812,
  "buildSeconds": 74,
  "packageRepository": "zeus",
  "wheelOnly": true,
  "status": "SUCCEEDED",
  "timestamp": "2026-07-13T09:00:00Z"
}
```

## 12. 운영 환경에서 변경할 값 목록

| 위치 | 변경 값 |
|---|---|
| Workflow Parameter | Bitbucket URL, Runtime Image와 실제 SHA-256, Zeus URL, Harbor 주소/프로젝트, 이미지 Tag, Cache 주소, BuildKit 주소, 알림 URL |
| Workflow Script Image | `python-tools`, `git-tools`, `curl-jq`, `python-build-tools`, `buildkit-client-tools`의 내부 Harbor 주소와 실제 SHA-256 |
| PVC | `CHANGE_ME-rwx-storage`, 용량, 필요 시 Access Mode |
| `registry-auth` | 실제 Harbor Host 및 자격 증명 |
| `bitbucket-ssh` | Private Key와 검증된 `known_hosts` Host Key |
| `zeus-pypi-auth` | Zeus 전용 최소 권한 계정 |
| ConfigMap | Zeus가 허용하는 동시 Wheel 다운로드 수 |
| Build Tools Dockerfile | 폐쇄망 내부 Python Base Image와 실제 SHA-256 |
| Dockerfile Template | 애플리케이션 실행 모듈/명령과 비-root UID가 실제 Runtime Image에 존재하는지 확인 |

`sha256:000...000`은 형식 검증을 통과시키기 위한 자리표시자일 뿐 실제 이미지가 아니므로 전부 교체해야 한다. `CHANGE_ME`가 하나라도 남은 상태로 배포하지 않는다.

## 13. YAML과 JSON 구조 일치 여부 확인표

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

## 14. 운영상 한계와 주의사항

- Argo Controller가 Output Artifact를 저장하려면 Namespace/Controller에 Artifact Repository가 구성되어 있어야 한다. 파일은 PVC에도 남지만 Artifact 업로드 설정이 없으면 Artifact Output 단계가 실패할 수 있다.
- `buildctl`의 단일 Build/Push 호출은 Push 시간만 별도로 제공하지 않는다. 따라서 `build-seconds`는 Build와 Push를 포함한 전체 시간이고 `push-seconds`는 명시적으로 `0`이다. 정확한 분리가 필요하면 Registry 이벤트/Telemetry를 결합하거나 Build와 Push를 분리해야 한다.
- 원격 BuildKit이 TLS/mTLS를 요구하면 BuildKit 인증용 Secret Volume과 `buildctl --tlscacert/--tlscert/--tlskey`를 추가해야 한다. 현재 요구사항에 그 Secret이 정의되지 않아 주소 및 사내 CA 신뢰가 Client Image에 준비됐다는 전제다.
- `ReadWriteMany` StorageClass가 클러스터에 실제로 있어야 한다. NFS 계열 Storage에서는 소유권/성능/파일 잠금 정책도 확인한다.
- Secret 예시는 배포 구조를 보여주기 위한 자리표시자다. 실제 값은 Git에 저장하지 말고 External Secrets/Sealed Secrets/Vault 같은 운영 Secret 관리 경로로 주입한다.
- Bitbucket `known_hosts`는 `ssh-keyscan` 결과를 무검증으로 사용하지 말고 관리자가 별도 채널로 확인한 Host Key를 고정한다.
- NetworkPolicy로 Bitbucket, Zeus, Harbor, BuildKit, 알림 서버와 DNS 이외의 Egress를 차단해야 “외부 PyPI 접근 금지”를 인프라 계층에서도 강제할 수 있다.
- `requirements.lock`은 플랫폼/CPU/Python ABI에 맞는 Wheel만 포함해야 한다. `requirements.txt` fallback은 마이그레이션 경고를 내지만 운영에서는 정책 Admission으로 금지하는 편이 안전하다.
- Test Target은 `tests/`가 존재하면 `pytest`를 실행한다. `pytest`가 Lock에 포함되지 않는 조직은 전용 Test Lock 또는 테스트 실행 명령을 Build Tools Template에 반영해야 한다.
- 현재 로컬 환경에는 연결된 Kubernetes API와 Argo CRD Schema가 없어 서버 측 Dry Run은 수행하지 못했다. 실제 배포 전 대상 클러스터에서 `kubectl apply --server-side --dry-run=server`와 Argo 버전 호환성 검증이 필요하다.
