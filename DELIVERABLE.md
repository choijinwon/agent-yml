# 폐쇄망 Python Build Argo WorkflowTemplate 전체 산출물

Nexus PyPI는 인증 없이 익명으로 Wheel을 다운로드한다. Nexus 다운로드는 병목이 아닌 것으로 확인되어 별도 속도 체크 Task는 제거했다. 현재 병목 관리는 BuildKit 실행, Dependency Image 생성, Layer Cache 재사용 여부에 집중한다. Runtime Contract를 digest로 고정하고 L0~L8 계층 중 L6 Role Head, L7 Project/App, L8 Model Artifact만 워크로드별로 얇게 추가한다. 이미지 이름은 Runtime Lineage + Role + Project/App 기준으로 관리한다. Training/Serving 관계는 strict와 optimized 두 패턴으로 분리하며, optimized inference runtime은 Artifact Contract와 검증 파이프라인을 필수로 둔다. Dependency Image Cache HIT이면 Nexus 다운로드와 pip install을 모두 생략한다.

## 1. 전체 Argo WorkflowTemplate YAML

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: run-python-image-template-with-buildkit
  namespace: argo
  labels:
    workflows.argoproj.io/creator: system-serviceaccount-argo-argo-server
spec:
  entrypoint: main
  serviceAccountName: argo-kserver
  arguments:
    parameters:
    - name: bitbucket-address-user-code
      value: git@bitbucket.CHANGE_ME.internal:project/sample-api.git
    - name: runtime-image
      value: harbor.CHANGE_ME.internal/runtime/python311@sha256:0000000000000000000000000000000000000000000000000000000000000000
    - name: runtime-lineage
      value: python311-cpu
    - name: nexus-pypi-url
      value: https://nexus.CHANGE_ME.internal/simple
    - name: registry-address
      value: harbor.CHANGE_ME.internal
    - name: registry-project
      value: applications
    - name: image-tag
      value: 1.0.0
    - name: cache-registry-address
      value: harbor.CHANGE_ME.internal/build-cache
    - name: buildkit-address
      value: tcp://buildkitd.CHANGE_ME.internal:1234
    - name: notification-server-url
      value: ''
    - name: python-abi
      value: cp311
    - name: target-platform
      value: linux-amd64
    - name: workload-role
      value: serve
    - name: training-serving-pattern
      value: strict
    - name: inference-server-runtime
      value: python-runtime
    - name: artifact-contract-file
      value: artifact-contract.json
    - name: model-artifact-policy
      value: external
    - name: model-artifact-reference
      value: ''
    - name: image-builder-category
      value: ai-ml-python
    - name: image-builder-spec-file
      value: image-builder.spec.json
    - name: force-rebuild-dependencies
      value: 'false'
  volumeClaimTemplates:
  - metadata:
      name: workspace
    spec:
      accessModes:
      - ReadWriteMany
      storageClassName: CHANGE_ME-rwx-storage
      resources:
        requests:
          storage: 20Gi
  volumes:
  - name: registry-auth
    secret:
      secretName: registry-auth
  - name: bitbucket-ssh
    secret:
      secretName: bitbucket-ssh
      defaultMode: 256
  templates:
  - name: main
    dag:
      tasks:
      - name: get-repository-name-from-git
        template: get-repository-name-from-git
        arguments:
          parameters:
          - name: git-address
            value: "{{workflow.parameters.bitbucket-address-user-code}}"
      - name: clone-source
        depends: get-repository-name-from-git.Succeeded
        template: clone-source
        arguments:
          parameters:
          - name: git-address
            value: "{{workflow.parameters.bitbucket-address-user-code}}"
      - name: validate-runtime-image
        template: validate-runtime-image
        arguments:
          parameters:
          - name: runtime-image
            value: "{{workflow.parameters.runtime-image}}"
      - name: validate-lock
        depends: clone-source.Succeeded
        template: validate-lock
      - name: check-dependency-image
        depends: validate-lock.Succeeded && validate-runtime-image.Succeeded
        template: check-dependency-image
        arguments:
          parameters:
          - name: cache-registry-address
            value: "{{workflow.parameters.cache-registry-address}}"
          - name: lock-hash
            value: "{{tasks.validate-lock.outputs.parameters.lock-hash}}"
          - name: runtime-image-digest
            value: "{{tasks.validate-runtime-image.outputs.parameters.parent-image-digest}}"
          - name: python-abi
            value: "{{workflow.parameters.python-abi}}"
          - name: target-platform
            value: "{{workflow.parameters.target-platform}}"
          - name: force-rebuild
            value: "{{workflow.parameters.force-rebuild-dependencies}}"
      - name: download-wheels
        depends: check-dependency-image.Succeeded
        template: download-wheels
        arguments:
          parameters:
          - name: nexus-pypi-url
            value: "{{workflow.parameters.nexus-pypi-url}}"
          - name: lock-file-name
            value: "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
          - name: dependency-cache-status
            value: "{{tasks.check-dependency-image.outputs.parameters.cache-status}}"
      - name: prepare-build-context
        depends: validate-runtime-image.Succeeded && download-wheels.Succeeded
        template: prepare-build-context
        arguments:
          parameters:
          - name: repository-name
            value: "{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}"
          - name: runtime-image
            value: "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
          - name: runtime-lineage
            value: "{{workflow.parameters.runtime-lineage}}"
          - name: parent-image-digest
            value: "{{tasks.validate-runtime-image.outputs.parameters.parent-image-digest}}"
          - name: lock-file-name
            value: "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
          - name: lock-hash
            value: "{{tasks.validate-lock.outputs.parameters.lock-hash}}"
          - name: image-reference
            value: "{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/{{workflow.parameters.runtime-lineage}}/{{workflow.parameters.workload-role}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:{{workflow.parameters.image-tag}}"
          - name: cache-reference
            value: "{{workflow.parameters.cache-registry-address}}/{{workflow.parameters.runtime-lineage}}/{{workflow.parameters.workload-role}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:buildcache"
          - name: dependency-cache-status
            value: "{{tasks.check-dependency-image.outputs.parameters.cache-status}}"
          - name: workload-role
            value: "{{workflow.parameters.workload-role}}"
          - name: training-serving-pattern
            value: "{{workflow.parameters.training-serving-pattern}}"
          - name: inference-server-runtime
            value: "{{workflow.parameters.inference-server-runtime}}"
          - name: artifact-contract-file
            value: "{{workflow.parameters.artifact-contract-file}}"
          - name: model-artifact-policy
            value: "{{workflow.parameters.model-artifact-policy}}"
          - name: model-artifact-reference
            value: "{{workflow.parameters.model-artifact-reference}}"
          - name: image-builder-category
            value: "{{workflow.parameters.image-builder-category}}"
          - name: image-builder-spec-file
            value: "{{workflow.parameters.image-builder-spec-file}}"
      - name: build-dependency-image
        depends: prepare-build-context.Succeeded
        template: build-dependency-image
        arguments:
          parameters:
          - name: cache-status
            value: "{{tasks.check-dependency-image.outputs.parameters.cache-status}}"
          - name: dependency-image-tag
            value: "{{tasks.check-dependency-image.outputs.parameters.dependency-image-tag}}"
          - name: dependency-image-reference
            value: "{{tasks.check-dependency-image.outputs.parameters.dependency-image-reference}}"
          - name: dependency-mutex-key
            value: "{{tasks.check-dependency-image.outputs.parameters.dependency-mutex-key}}"
          - name: force-rebuild
            value: "{{workflow.parameters.force-rebuild-dependencies}}"
          - name: buildkit-address
            value: "{{workflow.parameters.buildkit-address}}"
          - name: runtime-image
            value: "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
      - name: build-release-image
        depends: build-dependency-image.Succeeded
        template: build-release-image
        arguments:
          parameters:
          - name: buildkit-address
            value: "{{workflow.parameters.buildkit-address}}"
          - name: runtime-image
            value: "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
          - name: runtime-lineage
            value: "{{workflow.parameters.runtime-lineage}}"
          - name: image-reference
            value: "{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/{{workflow.parameters.runtime-lineage}}/{{workflow.parameters.workload-role}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:{{workflow.parameters.image-tag}}"
          - name: cache-reference
            value: "{{workflow.parameters.cache-registry-address}}/{{workflow.parameters.runtime-lineage}}/{{workflow.parameters.workload-role}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:buildcache"
          - name: dependency-image
            value: "{{tasks.build-dependency-image.outputs.parameters.dependency-image-reference}}"
          - name: workload-role
            value: "{{workflow.parameters.workload-role}}"
          - name: training-serving-pattern
            value: "{{workflow.parameters.training-serving-pattern}}"
          - name: inference-server-runtime
            value: "{{workflow.parameters.inference-server-runtime}}"
          - name: artifact-contract-file
            value: "{{workflow.parameters.artifact-contract-file}}"
          - name: model-artifact-policy
            value: "{{workflow.parameters.model-artifact-policy}}"
          - name: model-artifact-reference
            value: "{{workflow.parameters.model-artifact-reference}}"
          - name: image-builder-category
            value: "{{workflow.parameters.image-builder-category}}"
          - name: image-builder-spec-file
            value: "{{workflow.parameters.image-builder-spec-file}}"
      - name: parse-image-digest
        depends: build-release-image.Succeeded
        template: parse-image-digest
        arguments:
          parameters:
          - name: image-digest
            value: "{{tasks.build-release-image.outputs.parameters.image-digest}}"
      - name: generate-build-report
        depends: parse-image-digest.Succeeded
        template: generate-build-report
        arguments:
          parameters:
          - name: repository-name
            value: "{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}"
          - name: image-reference
            value: "{{tasks.build-release-image.outputs.parameters.image-reference}}"
          - name: image-digest
            value: "{{tasks.parse-image-digest.outputs.parameters.parsed-image-digest}}"
          - name: parent-image-digest
            value: "{{tasks.validate-runtime-image.outputs.parameters.parent-image-digest}}"
          - name: runtime-image
            value: "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
          - name: runtime-lineage
            value: "{{workflow.parameters.runtime-lineage}}"
          - name: workload-role
            value: "{{workflow.parameters.workload-role}}"
          - name: training-serving-pattern
            value: "{{workflow.parameters.training-serving-pattern}}"
          - name: inference-server-runtime
            value: "{{workflow.parameters.inference-server-runtime}}"
          - name: artifact-contract-file
            value: "{{workflow.parameters.artifact-contract-file}}"
          - name: model-artifact-policy
            value: "{{workflow.parameters.model-artifact-policy}}"
          - name: model-artifact-reference
            value: "{{workflow.parameters.model-artifact-reference}}"
          - name: image-builder-category
            value: "{{workflow.parameters.image-builder-category}}"
          - name: image-builder-spec-file
            value: "{{workflow.parameters.image-builder-spec-file}}"
          - name: lock-file-name
            value: "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
          - name: lock-hash
            value: "{{tasks.validate-lock.outputs.parameters.lock-hash}}"
          - name: wheel-count
            value: "{{tasks.download-wheels.outputs.parameters.wheel-count}}"
          - name: wheel-total-bytes
            value: "{{tasks.download-wheels.outputs.parameters.wheel-total-bytes}}"
          - name: wheel-download-seconds
            value: "{{tasks.download-wheels.outputs.parameters.download-seconds}}"
          - name: average-download-bytes-per-second
            value: "{{tasks.download-wheels.outputs.parameters.average-download-bytes-per-second}}"
          - name: build-seconds
            value: "{{tasks.build-release-image.outputs.parameters.build-seconds}}"
          - name: dependency-cache-status
            value: "{{tasks.check-dependency-image.outputs.parameters.cache-status}}"
          - name: dependency-cache-key
            value: "{{tasks.check-dependency-image.outputs.parameters.dependency-cache-key}}"
          - name: dependency-image-reference
            value: "{{tasks.build-dependency-image.outputs.parameters.dependency-image-reference}}"
          - name: dependency-image-result
            value: "{{tasks.build-dependency-image.outputs.parameters.dependency-image-result}}"
          - name: dependency-build-seconds
            value: "{{tasks.build-dependency-image.outputs.parameters.dependency-build-seconds}}"
      - name: notify-build-result
        depends: generate-build-report.Succeeded
        template: notify-build-result
        arguments:
          parameters:
          - name: notification-server-url
            value: "{{workflow.parameters.notification-server-url}}"
          - name: report-json
            value: "{{tasks.generate-build-report.outputs.parameters.report-json}}"
  - name: get-repository-name-from-git
    inputs:
      parameters:
      - name: git-address
    outputs:
      parameters:
      - name: repository-name
        valueFrom:
          path: "/tmp/repository-name.txt"
    script:
      image: harbor.CHANGE_ME.internal/platform/python-tools:3.11@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        python - <<'PY'
        import re
        import sys

        address = r'''{{inputs.parameters.git-address}}'''.strip()
        if not address or any(c in address for c in "\r\n\0"):
            sys.exit("git-address is empty or contains a forbidden character")
        match = re.search(r"(?:[:/])([^/:]+?)(?:\.git)?/?$", address)
        if not match:
            sys.exit("unable to extract repository name from git-address")
        name = re.sub(r"\.git$", "", match.group(1))
        if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
            sys.exit("repository name contains unsupported characters")
        with open("/tmp/repository-name.txt", "w", encoding="utf-8") as output:
            output.write(name)
        print(f"repository-name={name}")
        PY
  - name: clone-source
    inputs:
      parameters:
      - name: git-address
    script:
      image: harbor.CHANGE_ME.internal/platform/git-tools:2.45@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        rm -rf /workspace/generated/context/app
        mkdir -p /workspace/generated/context
        chmod 700 /root/.ssh
        export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts"
        git clone --depth 1 -- "{{inputs.parameters.git-address}}" /workspace/generated/context/app
      volumeMounts:
      - name: workspace
        mountPath: "/workspace"
      - name: bitbucket-ssh
        mountPath: "/root/.ssh"
        readOnly: true
  - name: validate-runtime-image
    inputs:
      parameters:
      - name: runtime-image
    outputs:
      parameters:
      - name: runtime-image
        valueFrom:
          path: "/tmp/runtime-image.txt"
      - name: parent-image-digest
        valueFrom:
          path: "/tmp/parent-image-digest.txt"
    script:
      image: harbor.CHANGE_ME.internal/platform/python-tools:3.11@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        python - <<'PY'
        import re
        import sys

        image = r'''{{inputs.parameters.runtime-image}}'''.strip()
        if "@" not in image:
            sys.exit("runtime-image must be pinned by digest")
        reference, digest = image.rsplit("@", 1)
        if not reference or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            sys.exit("runtime-image must end with @sha256:<64 lowercase hex characters>")
        open("/tmp/runtime-image.txt", "w", encoding="utf-8").write(image)
        open("/tmp/parent-image-digest.txt", "w", encoding="utf-8").write(digest)
        print("runtime image digest format is valid")
        PY
  - name: validate-lock
    outputs:
      parameters:
      - name: lock-file-name
        valueFrom:
          path: "/workspace/generated/lock-file-name.txt"
      - name: lock-hash
        valueFrom:
          path: "/workspace/generated/lock-hash.txt"
    script:
      image: harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        mkdir -p /workspace/generated
        if [ -f /workspace/generated/context/app/requirements.lock ]; then
          lock_file=requirements.lock
        elif [ -f /workspace/generated/context/app/requirements.txt ]; then
          lock_file=requirements.txt
          echo "WARNING: requirements.txt fallback is allowed for migration only; use requirements.lock in production" >&2
        else
          echo "neither requirements.lock nor requirements.txt exists" >&2
          exit 1
        fi
        python /opt/build-tools/scripts/validate_lock.py "/workspace/generated/context/app/$lock_file"
        printf '%s' "$lock_file" > /workspace/generated/lock-file-name.txt
        sha256sum "/workspace/generated/context/app/$lock_file" | awk '{print $1}' > /workspace/generated/lock-hash.txt
      volumeMounts:
      - name: workspace
        mountPath: "/workspace"
  - name: download-wheels
    synchronization:
      semaphore:
        configMapKeyRef:
          name: nexus-concurrency-limit
          key: wheel-downloads
    inputs:
      parameters:
      - name: nexus-pypi-url
      - name: lock-file-name
      - name: dependency-cache-status
    outputs:
      parameters:
      - name: wheel-count
        valueFrom:
          path: "/workspace/generated/wheel-count.txt"
      - name: wheel-total-bytes
        valueFrom:
          path: "/workspace/generated/wheel-total-bytes.txt"
      - name: download-seconds
        valueFrom:
          path: "/workspace/generated/download-seconds.txt"
      - name: average-download-bytes-per-second
        valueFrom:
          path: "/workspace/generated/average-download-bytes-per-second.txt"
    script:
      image: harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        wheelhouse=/workspace/generated/context/wheelhouse
        rm -rf "$wheelhouse"
        mkdir -p "$wheelhouse" /workspace/generated

        if [ '{{inputs.parameters.dependency-cache-status}}' = HIT ]; then
          printf '0' > /workspace/generated/wheel-count.txt
          printf '0' > /workspace/generated/wheel-total-bytes.txt
          printf '0' > /workspace/generated/download-seconds.txt
          printf '0' > /workspace/generated/average-download-bytes-per-second.txt
          echo 'dependency image cache HIT; Nexus download skipped'
          exit 0
        fi

        start="$(date +%s)"
        python -m pip download \
          --index-url "{{inputs.parameters.nexus-pypi-url}}" \
          --only-binary=:all: \
          --prefer-binary \
          --disable-pip-version-check \
          --timeout 30 \
          --retries 3 \
          --requirement "/workspace/generated/context/app/{{inputs.parameters.lock-file-name}}" \
          --dest "$wheelhouse"
        end="$(date +%s)"
        seconds="$((end - start))"
        count="$(find "$wheelhouse" -type f -name '*.whl' | wc -l | tr -d ' ')"
        [ "$count" -gt 0 ] || { echo "wheelhouse is empty" >&2; exit 1; }
        bytes="$(find "$wheelhouse" -type f -name '*.whl' -exec stat -c '%s' {} + | awk '{sum += $1} END {print sum + 0}')"
        average="$((bytes / (seconds > 0 ? seconds : 1)))"
        printf '%s' "$count" > /workspace/generated/wheel-count.txt
        printf '%s' "$bytes" > /workspace/generated/wheel-total-bytes.txt
        printf '%s' "$seconds" > /workspace/generated/download-seconds.txt
        printf '%s' "$average" > /workspace/generated/average-download-bytes-per-second.txt
        printf 'downloaded %s wheels anonymously from Nexus (%s bytes) in %s seconds\n' "$count" "$bytes" "$seconds"
      volumeMounts:
      - name: workspace
        mountPath: "/workspace"
  - name: prepare-build-context
    inputs:
      parameters:
      - name: repository-name
      - name: runtime-image
      - name: runtime-lineage
      - name: workload-role
      - name: training-serving-pattern
      - name: inference-server-runtime
      - name: artifact-contract-file
      - name: model-artifact-policy
      - name: model-artifact-reference
      - name: image-builder-category
      - name: image-builder-spec-file
      - name: parent-image-digest
      - name: lock-file-name
      - name: lock-hash
      - name: image-reference
      - name: cache-reference
      - name: dependency-cache-status
    script:
      image: harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        context=/workspace/generated/context
        test -d "$context/app"
        test -d "$context/wheelhouse"
        workload_role='{{inputs.parameters.workload-role}}'
        runtime_lineage='{{inputs.parameters.runtime-lineage}}'
        training_serving_pattern='{{inputs.parameters.training-serving-pattern}}'
        inference_server_runtime='{{inputs.parameters.inference-server-runtime}}'
        artifact_contract_file='{{inputs.parameters.artifact-contract-file}}'
        model_artifact_policy='{{inputs.parameters.model-artifact-policy}}'
        model_artifact_reference='{{inputs.parameters.model-artifact-reference}}'
        image_builder_category='{{inputs.parameters.image-builder-category}}'
        image_builder_spec_file='{{inputs.parameters.image-builder-spec-file}}'
        case "$workload_role" in
          train|job|serve|infer) ;;
          *) echo "workload-role must be one of train, job, serve, infer" >&2; exit 1 ;;
        esac
        printf '%s' "$runtime_lineage" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' || { echo 'runtime-lineage must use lowercase registry-safe characters' >&2; exit 1; }
        printf '%s' "$image_builder_category" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' || { echo 'image-builder-category must use lowercase registry-safe characters' >&2; exit 1; }
        printf '%s' "$image_builder_spec_file" | grep -Eq '^[A-Za-z0-9._-]+$' || { echo 'image-builder-spec-file must be a file name, not a path' >&2; exit 1; }
        case "$training_serving_pattern" in
          strict|optimized) ;;
          *) echo 'training-serving-pattern must be strict or optimized' >&2; exit 1 ;;
        esac
        case "$inference_server_runtime" in
          python-runtime|triton|tensorrt|vllm|onnxruntime|custom) ;;
          *) echo 'inference-server-runtime must be python-runtime, triton, tensorrt, vllm, onnxruntime, or custom' >&2; exit 1 ;;
        esac
        case "$model_artifact_policy" in
          external) ;;
          *) echo 'model-artifact-policy must be external in this template; model files are not embedded in images by default' >&2; exit 1 ;;
        esac
        if [ "$model_artifact_policy" = external ] && [ -z "$model_artifact_reference" ]; then
          printf '[Model] model-artifact-policy=external: model files are excluded from image and should be mounted or resolved by deployment runtime.\n'
        fi
        if [ "$training_serving_pattern" = optimized ]; then
          case "$workload_role" in serve|infer) ;; *) echo 'optimized pattern is only valid for serve or infer workloads' >&2; exit 1 ;; esac
          test -s "$context/app/$artifact_contract_file" || { echo "optimized inference requires artifact contract file: $artifact_contract_file" >&2; exit 1; }
        fi
        if [ '{{inputs.parameters.dependency-cache-status}}' = MISS ]; then
          find "$context/wheelhouse" -type f -name '*.whl' -print -quit | grep -q . || { echo 'wheelhouse is empty on cache MISS' >&2; exit 1; }
        fi
        rm -rf "$context/app/.git"
        cp "$context/app/{{inputs.parameters.lock-file-name}}" "$context/requirements.lock"

        # BuildKit 전송 대상에서 개발 산출물과 중복 Lock 파일을 제외합니다.
        cat > "$context/.dockerignore" <<'DOCKERIGNORE'
        **/.git
        **/.venv
        **/__pycache__
        **/*.pyc
        **/.pytest_cache
        **/.mypy_cache
        **/.ruff_cache
        **/dist
        **/build
        **/node_modules
        app/requirements.lock
        app/requirements.txt
        # 모델은 기본적으로 이미지와 Build Context에 넣지 않는다. 배포 Runtime에서 PVC/Object Storage/Model Registry로 주입한다.
        app/model
        app/models
        app/model-artifacts
        DOCKERIGNORE

        # Docker 레이어 구조를 WorkflowTemplate JSON의 script.source에서 직접 생성합니다.
        cat > /workspace/generated/context/Dockerfile <<'DOCKERFILE'
        # syntax=docker/dockerfile:1.7
        ARG RUNTIME_IMAGE
        ARG DEPENDENCY_IMAGE
        ARG WORKLOAD_ROLE
        ARG TRAINING_SERVING_PATTERN
        ARG INFERENCE_SERVER_RUNTIME
        ARG ARTIFACT_CONTRACT_FILE
        ARG MODEL_ARTIFACT_POLICY
        ARG MODEL_ARTIFACT_REFERENCE
        ARG IMAGE_BUILDER_CATEGORY
        ARG IMAGE_BUILDER_SPEC_FILE

        # Runtime Contract는 OS Base, Accelerator ABI, Language Runtime, ML Framework, ML Ops Common을 digest로 고정한 공통 계약이다.
        FROM ${RUNTIME_IMAGE} AS runtime-contract
        LABEL org.opencontainers.image.runtime-contract.layers="L0-source-base,L1-os-foundation,L2-accelerator-abi,L3-language-runtime,L4-ml-framework,L5-ml-ops-common" \
              org.opencontainers.image.layer.L0="source-base:digest-pin-required" \
              org.opencontainers.image.layer.L1="os-foundation" \
              org.opencontainers.image.layer.L2="accelerator-abi" \
              org.opencontainers.image.layer.L3="language-runtime" \
              org.opencontainers.image.layer.L4="ml-framework" \
              org.opencontainers.image.layer.L5="ml-ops-common"

        # Cache MISS에서만 실행해 Lock Hash 전용 Dependency Image를 생성
        FROM runtime-contract AS dependency-image
        ENV PIP_DISABLE_PIP_VERSION_CHECK=1
        COPY requirements.lock /build/requirements.lock
        COPY wheelhouse /build/wheelhouse
        RUN python -m pip install \
              --no-index \
              --find-links=/build/wheelhouse \
              --only-binary=:all: \
              --prefix=/opt/python-dependencies \
              -r /build/requirements.lock \
            && rm -rf /root/.cache/pip /build/wheelhouse

        # Cache HIT/MISS 모두 Harbor Digest로 고정된 Dependency Image 사용
        FROM ${DEPENDENCY_IMAGE} AS dependencies

        FROM runtime-contract AS role-head
        ARG WORKLOAD_ROLE
        ARG TRAINING_SERVING_PATTERN
        ARG INFERENCE_SERVER_RUNTIME
        ARG ARTIFACT_CONTRACT_FILE
        ARG MODEL_ARTIFACT_POLICY
        ARG MODEL_ARTIFACT_REFERENCE
        ARG IMAGE_BUILDER_CATEGORY
        ARG IMAGE_BUILDER_SPEC_FILE
        ENV AISTUDIO_WORKLOAD_ROLE=${WORKLOAD_ROLE} \
            AISTUDIO_TRAINING_SERVING_PATTERN=${TRAINING_SERVING_PATTERN} \
            AISTUDIO_INFERENCE_SERVER_RUNTIME=${INFERENCE_SERVER_RUNTIME} \
            AISTUDIO_ARTIFACT_CONTRACT_FILE=${ARTIFACT_CONTRACT_FILE} \
            AISTUDIO_MODEL_ARTIFACT_POLICY=${MODEL_ARTIFACT_POLICY} \
            AISTUDIO_MODEL_ARTIFACT_REFERENCE=${MODEL_ARTIFACT_REFERENCE} \
            AISTUDIO_IMAGE_BUILDER_CATEGORY=${IMAGE_BUILDER_CATEGORY} \
            AISTUDIO_IMAGE_BUILDER_SPEC_FILE=${IMAGE_BUILDER_SPEC_FILE} \
            PYTHONDONTWRITEBYTECODE=1 \
            PYTHONUNBUFFERED=1 \
            PIP_DISABLE_PIP_VERSION_CHECK=1
        LABEL org.opencontainers.image.runtime-contract.role=${WORKLOAD_ROLE} \
              org.opencontainers.image.training-serving.pattern=${TRAINING_SERVING_PATTERN} \
              org.opencontainers.image.inference.runtime=${INFERENCE_SERVER_RUNTIME} \
              org.opencontainers.image.artifact.contract=${ARTIFACT_CONTRACT_FILE} \
              org.opencontainers.image.model.artifact.policy=${MODEL_ARTIFACT_POLICY} \
              org.opencontainers.image.model.artifact.reference=${MODEL_ARTIFACT_REFERENCE} \
              org.opencontainers.image.builder.mode="declarative-spec" \
              org.opencontainers.image.builder.category=${IMAGE_BUILDER_CATEGORY} \
              org.opencontainers.image.builder.spec=${IMAGE_BUILDER_SPEC_FILE} \
              org.opencontainers.image.builder.security-policy="required" \
              org.opencontainers.image.builder.reproducibility-policy="required" \
              org.opencontainers.image.layer.L6="role-head:${WORKLOAD_ROLE}"
        WORKDIR /app
        RUN case "$AISTUDIO_WORKLOAD_ROLE" in train|job|serve|infer) ;; *) echo "invalid workload role" >&2; exit 1 ;; esac \
            && case "$AISTUDIO_TRAINING_SERVING_PATTERN" in strict|optimized) ;; *) echo "invalid training-serving pattern" >&2; exit 1 ;; esac \
            && if [ "$AISTUDIO_TRAINING_SERVING_PATTERN" = optimized ]; then case "$AISTUDIO_WORKLOAD_ROLE" in serve|infer) ;; *) echo "optimized pattern is only valid for serve or infer" >&2; exit 1 ;; esac; fi \
            && case "$AISTUDIO_MODEL_ARTIFACT_POLICY" in external) ;; *) echo "model artifact policy must be external" >&2; exit 1 ;; esac

        FROM role-head AS test
        COPY --from=dependencies /opt/python-dependencies/ /usr/local/
        COPY app /app
        RUN python -m compileall -q /app \
            && if [ -d /app/tests ]; then python -m pytest -q /app/tests; fi \
            && touch /test-passed

        FROM role-head AS project-app
        LABEL org.opencontainers.image.layer.L7="project-app"
        COPY app /project
        RUN rm -rf /project/tests /project/test /project/.git \
            /project/.pytest_cache /project/.mypy_cache /project/.ruff_cache \
            /project/model /project/models /project/model-artifacts

        FROM role-head AS model-artifact
        LABEL org.opencontainers.image.layer.L8="model-artifact-external" \
              org.opencontainers.image.model.artifact.default="external"
        RUN mkdir -p /model-artifacts \
            && printf '%s\n' 'Model files are intentionally excluded from the image. Mount or resolve them at deployment runtime.' > /model-artifacts/README.txt

        FROM role-head AS release
        LABEL org.opencontainers.image.layer.L7="project-app" \
              org.opencontainers.image.layer.L8="model-artifact-external"
        ENV MODEL_ARTIFACT_DIR=/model-artifacts
        COPY --from=test /test-passed /tmp/test-passed
        COPY --from=dependencies /opt/python-dependencies/ /usr/local/
        COPY --from=project-app /project /app
        COPY --from=model-artifact /model-artifacts /model-artifacts
        COPY image-builder.spec.json /image-builder/image-builder.spec.json
        RUN rm -f /tmp/test-passed
        USER 10001:10001
        CMD ["python", "-m", "app"]
        DOCKERFILE

        cat > "$context/$image_builder_spec_file" <<'JSON'
        {
          "schemaVersion": "image-builder/v1",
          "builderMode": "declarative-spec",
          "category": "{{inputs.parameters.image-builder-category}}",
          "runtimeLineage": "{{inputs.parameters.runtime-lineage}}",
          "imageBuilderMode": "declarative-spec",
          "imageBuilderCategory": "{{inputs.parameters.image-builder-category}}",
          "imageBuilderSpecFile": "{{inputs.parameters.image-builder-spec-file}}",
          "imageBuilderPrinciple": "Central declarative image category controls Dockerfile generation, layer policy, validation and report metadata.",
          "dockerfileStrategy": "multi-stage-target",
          "buildTargets": {"dependency":"dependency-image","test":"test","release":"release"},
          "targetPolicy": {"dependencyBuildTarget":"dependency-image","releaseBuildTarget":"release","releaseRequiresTestStage":true,"pushOnlyReleaseTarget":true},
          "workloadRole": "{{inputs.parameters.workload-role}}",
          "trainingServingPattern": "{{inputs.parameters.training-serving-pattern}}",
          "inferenceServerRuntime": "{{inputs.parameters.inference-server-runtime}}",
          "artifactContractFile": "{{inputs.parameters.artifact-contract-file}}",
          "modelArtifactPolicy": "{{inputs.parameters.model-artifact-policy}}",
          "modelArtifactReference": "{{inputs.parameters.model-artifact-reference}}",
          "modelImagePolicy": {"default":"external","embedModelFilesByDefault":false,"excludeModelDirectoriesFromBuildContext":true,"runtimeInjection":"PVC/ObjectStorage/ModelRegistry"},
          "securityReproducibilityPolicy": {"required":true,"runtimeDigestPinned":true,"dependencyDigestPinned":true,"lockHashRequired":true,"noLatestTags":true,"nonRootUserRequired":true,"modelExternalByDefault":true,"buildReportRequired":true,"reproducibilityKey":"runtimeDigest+lockHash+pythonAbi+targetPlatform+builderSpec"},
          "sourcePolicy": {
            "dockerfileManagedBy": "workflow-template",
            "manualDockerfilePerProject": false,
            "centralCategoryRequired": true
          },
          "layers": [
            {"level": "L0", "name": "source-base", "policy": "digest-pin-required"},
            {"level": "L1", "name": "os-foundation", "policy": "runtime-contract"},
            {"level": "L2", "name": "accelerator-abi", "policy": "runtime-contract"},
            {"level": "L3", "name": "language-runtime", "policy": "runtime-contract"},
            {"level": "L4", "name": "ml-framework", "policy": "runtime-contract"},
            {"level": "L5", "name": "ml-ops-common", "policy": "runtime-contract"},
            {"level": "L6", "name": "role-head", "policy": "thin-role-layer"},
            {"level": "L7", "name": "project-app", "policy": "project-code-layer"},
            {"level": "L8", "name": "model-artifact", "policy": "artifact-layer"}
          ],
          "validationRules": [
            "runtime-image-must-be-digest-pinned",
            "workload-role-must-be-train-job-serve-or-infer",
            "optimized-serving-requires-artifact-contract",
            "dependency-image-must-be-addressed-by-digest",
            "security-reproducibility-policy-required",
            "non-root-user-required",
            "build-report-required"
          ]
        }
        JSON
        if [ "$image_builder_spec_file" != "image-builder.spec.json" ]; then
          cp "$context/$image_builder_spec_file" "$context/image-builder.spec.json"
        fi

        printf '%s' 'runtime-contract,dependency-image,dependencies,role-head,test,project-app,model-artifact,release' > /workspace/generated/docker-layer-stages.txt
        cat > /workspace/generated/build-spec.json <<'JSON'
        {
          "repositoryName": "{{inputs.parameters.repository-name}}",
          "runtimeImage": "{{inputs.parameters.runtime-image}}",
          "runtimeLineage": "{{inputs.parameters.runtime-lineage}}",
          "imageBuilderMode": "declarative-spec",
          "imageBuilderCategory": "{{inputs.parameters.image-builder-category}}",
          "imageBuilderSpecFile": "{{inputs.parameters.image-builder-spec-file}}",
          "imageBuilderPrinciple": "Central declarative image category controls Dockerfile generation, layer policy, validation and report metadata.",
          "trainingServingPattern": "{{inputs.parameters.training-serving-pattern}}",
          "inferenceServerRuntime": "{{inputs.parameters.inference-server-runtime}}",
          "artifactContractFile": "{{inputs.parameters.artifact-contract-file}}",
          "servingPatternRules": {"strict":"Training and Serving share the same Runtime Contract for Python model execution.","optimized":"Serving may use an optimized inference runtime, but model artifacts must satisfy an explicit artifact contract and validation pipeline."},
          "declarativeImageBuilder": {"managedBy":"central-image-builder-spec","manualDockerfilePerProject":false,"category":"{{inputs.parameters.image-builder-category}}","specFile":"{{inputs.parameters.image-builder-spec-file}}"},
          "dockerfileStrategy": "multi-stage-target",
          "multiStageTargetStrategy": {"stages":["runtime-contract","dependency-image","dependencies","role-head","test","project-app","model-artifact","release"],"targets":{"dependency":"dependency-image","test":"test","release":"release"},"releaseTarget":"release","pushOnlyReleaseTarget":true,"releaseRequiresTestStage":true},
          "securityReproducibilityPolicy": {"required":true,"runtimeDigestPinned":true,"dependencyDigestPinned":true,"lockHashRequired":true,"noLatestTags":true,"nonRootUserRequired":true,"modelExternalByDefault":true,"buildReportRequired":true,"reproducibilityKey":"runtimeDigest+lockHash+pythonAbi+targetPlatform+builderSpec"},
          "securityReproducibilityChecks": ["runtime-image-digest-pinned","dependency-image-digest-pinned","lock-hash-recorded","image-digest-recorded","non-root-user","model-external","no-latest-tags","build-report-generated"],
          "imageNamingConvention": "{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/<runtime-lineage>/<workload-role>/<project>:<tag>",
          "parentImageDigest": "{{inputs.parameters.parent-image-digest}}",
          "lockFileName": "{{inputs.parameters.lock-file-name}}",
          "lockHash": "{{inputs.parameters.lock-hash}}",
          "imageReference": "{{inputs.parameters.image-reference}}",
          "cacheReference": "{{inputs.parameters.cache-reference}}",
          "dockerLayerStages": ["runtime-contract", "dependency-image", "dependencies", "role-head", "test", "project-app", "model-artifact", "release"],
          "runtimeContractLayers": ["os-base", "accelerator-abi", "language-runtime", "ml-framework", "ml-ops-common"],
          "runtimeContractCriteria": ["runtime-image-digest", "os-base-digest", "accelerator-abi", "language-runtime", "ml-framework", "ml-ops-common", "target-platform", "python-abi", "security-and-path-contract"],
          "recommendedImageLayers": [{"level":"L0","name":"source-base","description":"Ubuntu, Debian, UBI, NVIDIA CUDA 등 외부 원천 이미지","operation":"digest-pin-required"},{"level":"L1","name":"os-foundation","description":"OS 패키지, glibc, CA trust, timezone 등 운영 OS 기준"},{"level":"L2","name":"accelerator-abi","description":"CUDA/ROCm, cuDNN, NCCL, GPU driver 호환 ABI"},{"level":"L3","name":"language-runtime","description":"Python/uv/pip 및 Python ABI"},{"level":"L4","name":"ml-framework","description":"PyTorch, TensorFlow, vLLM, Triton 등 ML Framework"},{"level":"L5","name":"ml-ops-common","description":"logging, metrics, tracing, auth, cert, 공통 운영 유틸리티"},{"level":"L6","name":"role-head","description":"train/job/serve/infer 역할별 얇은 실행 Head"},{"level":"L7","name":"project-app","description":"프로젝트 코드와 애플리케이션 설정"},{"level":"L8","name":"model-artifact","description":"모델 파일은 이미지에 포함하지 않고 외부 Model Registry/PVC/Object Storage Reference로 관리"}],
          "workloadRole": "{{inputs.parameters.workload-role}}"
        }
        JSON
        test -s /workspace/generated/context/Dockerfile
        test -s /workspace/generated/context/image-builder.spec.json
        test -s /workspace/generated/build-spec.json
        printf 'Docker layers: L0/L1/L2/L3/L4/L5 runtime-contract -> dependency-image -> dependencies -> L6 role-head -> test -> L7 project-app -> L8 model-artifact -> release\n'
      volumeMounts:
      - name: workspace
        mountPath: "/workspace"
  - name: build-release-image
    inputs:
      parameters:
      - name: buildkit-address
      - name: runtime-image
      - name: runtime-lineage
      - name: image-reference
      - name: cache-reference
      - name: dependency-image
      - name: workload-role
      - name: training-serving-pattern
      - name: inference-server-runtime
      - name: artifact-contract-file
      - name: model-artifact-policy
      - name: model-artifact-reference
      - name: image-builder-category
      - name: image-builder-spec-file
    outputs:
      parameters:
      - name: image-reference
        valueFrom:
          path: "/workspace/generated/image-reference.txt"
      - name: image-digest
        valueFrom:
          path: "/workspace/generated/image-digest.txt"
      - name: build-seconds
        valueFrom:
          path: "/workspace/generated/build-seconds.txt"
      - name: push-seconds
        valueFrom:
          path: "/workspace/generated/push-seconds.txt"
    script:
      image: harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      env:
      - name: DOCKER_CONFIG
        value: "/root/.docker"
      source: |
        set -euo pipefail
        mkdir -p /workspace/generated
        start="$(date +%s)"
        printf '[BuildKit] release build and Harbor push started at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        buildctl --addr "{{inputs.parameters.buildkit-address}}" build \
          --progress=plain \
          --frontend dockerfile.v0 \
          --local context=/workspace/generated/context \
          --local dockerfile=/workspace/generated/context \
          --opt filename=Dockerfile \
          --opt target=release \
          --opt "build-arg:RUNTIME_IMAGE={{inputs.parameters.runtime-image}}" \
          --opt "build-arg:DEPENDENCY_IMAGE={{inputs.parameters.dependency-image}}" \
          --opt "build-arg:WORKLOAD_ROLE={{inputs.parameters.workload-role}}" \
          --opt "build-arg:TRAINING_SERVING_PATTERN={{inputs.parameters.training-serving-pattern}}" \
          --opt "build-arg:INFERENCE_SERVER_RUNTIME={{inputs.parameters.inference-server-runtime}}" \
          --opt "build-arg:ARTIFACT_CONTRACT_FILE={{inputs.parameters.artifact-contract-file}}" \
          --opt "build-arg:MODEL_ARTIFACT_POLICY={{inputs.parameters.model-artifact-policy}}" \
          --opt "build-arg:MODEL_ARTIFACT_REFERENCE={{inputs.parameters.model-artifact-reference}}" \
          --opt "build-arg:IMAGE_BUILDER_CATEGORY={{inputs.parameters.image-builder-category}}" \
          --opt "build-arg:IMAGE_BUILDER_SPEC_FILE={{inputs.parameters.image-builder-spec-file}}" \
          --import-cache "type=registry,ref={{inputs.parameters.cache-reference}}" \
          --export-cache "type=registry,ref={{inputs.parameters.cache-reference}},mode=min" \
          --output "type=image,name={{inputs.parameters.image-reference}},push=true" \
          --metadata-file /workspace/generated/build-metadata.json
        end="$(date +%s)"
        digest="$(jq -r '."containerimage.digest" // ."containerimage.descriptor".digest // empty' /workspace/generated/build-metadata.json)"
        printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo "BuildKit did not return a valid image digest" >&2; exit 1; }
        printf '%s' "{{inputs.parameters.image-reference}}" > /workspace/generated/image-reference.txt
        printf '%s' "$digest" > /workspace/generated/image-digest.txt
        printf '%s' "$((end - start))" > /workspace/generated/build-seconds.txt
        printf '%s' '0' > /workspace/generated/push-seconds.txt
        printf '[BuildKit] release build, cache export and Harbor push completed in %s seconds: %s@%s\n' \
          "$((end - start))" "{{inputs.parameters.image-reference}}" "$digest"
      volumeMounts:
      - name: workspace
        mountPath: "/workspace"
      - name: registry-auth
        mountPath: "/root/.docker"
        readOnly: true
  - name: parse-image-digest
    inputs:
      parameters:
      - name: image-digest
    outputs:
      parameters:
      - name: parsed-image-digest
        valueFrom:
          path: "/tmp/parsed-image-digest.txt"
    script:
      image: harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        digest="$(printf '%s' "{{inputs.parameters.image-digest}}" | grep -Eo 'sha256:[0-9a-f]{64}' | head -n 1 || true)"
        [ -n "$digest" ] || { echo "valid image digest not found" >&2; exit 1; }
        printf '%s' "$digest" > /tmp/parsed-image-digest.txt
  - name: generate-build-report
    inputs:
      parameters:
      - name: repository-name
      - name: image-reference
      - name: image-digest
      - name: parent-image-digest
      - name: runtime-image
      - name: runtime-lineage
      - name: workload-role
      - name: training-serving-pattern
      - name: inference-server-runtime
      - name: artifact-contract-file
      - name: model-artifact-policy
      - name: model-artifact-reference
      - name: image-builder-category
      - name: image-builder-spec-file
      - name: lock-file-name
      - name: lock-hash
      - name: wheel-count
      - name: wheel-total-bytes
      - name: wheel-download-seconds
      - name: average-download-bytes-per-second
      - name: build-seconds
      - name: dependency-cache-status
      - name: dependency-cache-key
      - name: dependency-image-reference
      - name: dependency-image-result
      - name: dependency-build-seconds
    outputs:
      parameters:
      - name: report-json
        valueFrom:
          path: "/workspace/output/build-report.json"
      artifacts:
      - name: build-report
        path: "/workspace/output/build-report.json"
        archive:
          none: {}
    script:
      image: harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        mkdir -p /workspace/output
        jq -n \
          --arg workflowName "{{workflow.name}}" \
          --arg workflowUid "{{workflow.uid}}" \
          --arg namespace "{{workflow.namespace}}" \
          --arg repositoryName "{{inputs.parameters.repository-name}}" \
          --arg imageReference "{{inputs.parameters.image-reference}}" \
          --arg imageDigest "{{inputs.parameters.image-digest}}" \
          --arg parentImageDigest "{{inputs.parameters.parent-image-digest}}" \
          --arg runtimeImage "{{inputs.parameters.runtime-image}}" \
          --arg runtimeLineage "{{inputs.parameters.runtime-lineage}}" \
          --arg workloadRole "{{inputs.parameters.workload-role}}" \
          --arg trainingServingPattern "{{inputs.parameters.training-serving-pattern}}" \
          --arg inferenceServerRuntime "{{inputs.parameters.inference-server-runtime}}" \
          --arg artifactContractFile "{{inputs.parameters.artifact-contract-file}}" \
          --arg modelArtifactPolicy "{{inputs.parameters.model-artifact-policy}}" \
          --arg modelArtifactReference "{{inputs.parameters.model-artifact-reference}}" \
          --arg imageBuilderMode "declarative-spec" \
          --arg imageBuilderCategory "{{inputs.parameters.image-builder-category}}" \
          --arg imageBuilderSpecFile "{{inputs.parameters.image-builder-spec-file}}" \
          --arg lockFileName "{{inputs.parameters.lock-file-name}}" \
          --arg lockHash "{{inputs.parameters.lock-hash}}" \
          --argjson wheelCount "{{inputs.parameters.wheel-count}}" \
          --argjson wheelTotalBytes "{{inputs.parameters.wheel-total-bytes}}" \
          --argjson wheelDownloadSeconds "{{inputs.parameters.wheel-download-seconds}}" \
          --argjson averageDownloadBytesPerSecond "{{inputs.parameters.average-download-bytes-per-second}}" \
          --arg dependencyCacheStatus "{{inputs.parameters.dependency-cache-status}}" \
          --arg dependencyCacheKey "{{inputs.parameters.dependency-cache-key}}" \
          --arg dependencyImageReference "{{inputs.parameters.dependency-image-reference}}" \
          --arg dependencyImageResult "{{inputs.parameters.dependency-image-result}}" \
          --argjson dependencyBuildSeconds "{{inputs.parameters.dependency-build-seconds}}" \
          --argjson buildSeconds "{{inputs.parameters.build-seconds}}" \
          --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{workflowName:$workflowName,workflowUid:$workflowUid,namespace:$namespace,repositoryName:$repositoryName,imageReference:$imageReference,imageDigest:$imageDigest,parentImageDigest:$parentImageDigest,runtimeImage:$runtimeImage,runtimeLineage:$runtimeLineage,imageNamingConvention:"<registry>/<project>/<runtime-lineage>/<workload-role>/<project-app>:<tag>",workloadRole:$workloadRole,trainingServingPattern:$trainingServingPattern,inferenceServerRuntime:$inferenceServerRuntime,artifactContractFile:$artifactContractFile,artifactContractRequired:($trainingServingPattern=="optimized"),modelArtifactPolicy:$modelArtifactPolicy,modelArtifactReference:$modelArtifactReference,modelFilesEmbedded:false,modelInjectionRequired:($modelArtifactPolicy=="external"),imageBuilderMode:$imageBuilderMode,imageBuilderCategory:$imageBuilderCategory,imageBuilderSpecFile:$imageBuilderSpecFile,builderSpecDriven:true,manualDockerfilePerProject:false,dockerfileStrategy:"multi-stage-target",buildTargets:{dependency:"dependency-image",test:"test",release:"release"},releaseTarget:"release",pushOnlyReleaseTarget:true,releaseRequiresTestStage:true,securityReproducibilityPolicy:{required:true,runtimeDigestPinned:true,dependencyDigestPinned:true,lockHashRequired:true,noLatestTags:true,nonRootUserRequired:true,modelExternalByDefault:true,buildReportRequired:true,reproducibilityKey:"runtimeDigest+lockHash+pythonAbi+targetPlatform+builderSpec"},securityReproducibilityChecks:["runtime-image-digest-pinned","dependency-image-digest-pinned","lock-hash-recorded","image-digest-recorded","non-root-user","model-external","no-latest-tags","build-report-generated"],runtimeContractCriteria:["runtime-image-digest","os-base-digest","accelerator-abi","language-runtime","ml-framework","ml-ops-common","target-platform","python-abi","security-and-path-contract"],recommendedImageLayers:[{"level":"L0","name":"source-base","description":"Ubuntu, Debian, UBI, NVIDIA CUDA 등 외부 원천 이미지","operation":"digest-pin-required"},{"level":"L1","name":"os-foundation","description":"OS 패키지, glibc, CA trust, timezone 등 운영 OS 기준"},{"level":"L2","name":"accelerator-abi","description":"CUDA/ROCm, cuDNN, NCCL, GPU driver 호환 ABI"},{"level":"L3","name":"language-runtime","description":"Python/uv/pip 및 Python ABI"},{"level":"L4","name":"ml-framework","description":"PyTorch, TensorFlow, vLLM, Triton 등 ML Framework"},{"level":"L5","name":"ml-ops-common","description":"logging, metrics, tracing, auth, cert, 공통 운영 유틸리티"},{"level":"L6","name":"role-head","description":"train/job/serve/infer 역할별 얇은 실행 Head"},{"level":"L7","name":"project-app","description":"프로젝트 코드와 애플리케이션 설정"},{"level":"L8","name":"model-artifact","description":"모델 파일은 이미지에 포함하지 않고 외부 Model Registry/PVC/Object Storage Reference로 관리"}],lockFileName:$lockFileName,lockHash:$lockHash,wheelCount:$wheelCount,wheelTotalBytes:$wheelTotalBytes,wheelDownloadSeconds:$wheelDownloadSeconds,averageDownloadBytesPerSecond:$averageDownloadBytesPerSecond,testIncludedInReleaseBuild:true,dependencyCacheStatus:$dependencyCacheStatus,dependencyCacheKey:$dependencyCacheKey,dependencyImageReference:$dependencyImageReference,dependencyImageResult:$dependencyImageResult,dependencyBuildSeconds:$dependencyBuildSeconds,buildSeconds:$buildSeconds,packageRepository:"nexus",wheelOnly:true,status:"SUCCEEDED",timestamp:$timestamp}' \
          > /workspace/output/build-report.json
        jq . /workspace/output/build-report.json
      volumeMounts:
      - name: workspace
        mountPath: "/workspace"
  - name: notify-build-result
    inputs:
      parameters:
      - name: notification-server-url
      - name: report-json
    script:
      image: harbor.CHANGE_ME.internal/platform/curl-jq:8.8@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        printf '%s\n' '{{inputs.parameters.report-json}}' | jq .
        url='{{inputs.parameters.notification-server-url}}'
        if [ -z "$url" ]; then
          echo "notification-server-url is empty; notification skipped"
          exit 0
        fi
        printf '%s' '{{inputs.parameters.report-json}}' > /tmp/build-report.json
        curl --silent --show-error --fail-with-body \
          --retry 3 --retry-all-errors \
          --header 'Content-Type: application/json' \
          --data-binary @/tmp/build-report.json \
          -- "$url"
  - name: check-dependency-image
    inputs:
      parameters:
      - name: cache-registry-address
      - name: lock-hash
      - name: runtime-image-digest
      - name: python-abi
      - name: target-platform
      - name: force-rebuild
    outputs:
      parameters:
      - name: cache-status
        valueFrom:
          path: "/tmp/dependency-cache-status.txt"
      - name: dependency-cache-key
        valueFrom:
          path: "/tmp/dependency-cache-key.txt"
      - name: dependency-mutex-key
        valueFrom:
          path: "/tmp/dependency-mutex-key.txt"
      - name: dependency-image-tag
        valueFrom:
          path: "/tmp/dependency-image-tag.txt"
      - name: dependency-image-reference
        valueFrom:
          path: "/tmp/dependency-image-reference.txt"
      - name: dependency-image-digest
        valueFrom:
          path: "/tmp/dependency-image-digest.txt"
    script:
      image: harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      env:
      - name: DOCKER_CONFIG
        value: "/root/.docker"
      source: |
        set -euo pipefail
        lock_hash='{{inputs.parameters.lock-hash}}'
        runtime_digest='{{inputs.parameters.runtime-image-digest}}'
        python_abi='{{inputs.parameters.python-abi}}'
        target_platform='{{inputs.parameters.target-platform}}'
        force_rebuild='{{inputs.parameters.force-rebuild}}'

        printf '%s' "$lock_hash" | grep -Eq '^[0-9a-f]{64}$' || { echo 'invalid lock hash' >&2; exit 1; }
        printf '%s' "$runtime_digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo 'invalid runtime digest' >&2; exit 1; }
        printf '%s' "$python_abi" | grep -Eq '^[a-zA-Z0-9._-]+$' || { echo 'invalid python ABI' >&2; exit 1; }
        printf '%s' "$target_platform" | grep -Eq '^[a-zA-Z0-9._-]+$' || { echo 'invalid target platform' >&2; exit 1; }
        [ "$force_rebuild" = false ] || [ "$force_rebuild" = true ] || { echo 'force-rebuild must be true or false' >&2; exit 1; }

        runtime_short="$(printf '%s' "${runtime_digest#sha256:}" | cut -c1-12)"
        cache_key="${lock_hash}-${runtime_short}-${python_abi}-${target_platform}"
        mutex_key="$(printf '%s' "$cache_key" | sha256sum | awk '{print substr($1,1,24)}')"
        image_tag='{{inputs.parameters.cache-registry-address}}/python-deps:'"$cache_key"
        status=MISS
        digest=''
        image_reference="$image_tag"

        if [ "$force_rebuild" = false ]; then
          if digest="$(crane digest "$image_tag" 2>/tmp/crane-error.txt)"; then
            printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo 'Harbor returned an invalid digest' >&2; exit 1; }
            status=HIT
            image_reference="${image_tag}@${digest}"
          elif grep -Eqi 'manifest unknown|name unknown|not found|404' /tmp/crane-error.txt; then
            status=MISS
          else
            echo 'Harbor dependency cache lookup failed:' >&2
            cat /tmp/crane-error.txt >&2
            exit 1
          fi
        fi

        printf '%s' "$status" > /tmp/dependency-cache-status.txt
        printf '%s' "$cache_key" > /tmp/dependency-cache-key.txt
        printf '%s' "$mutex_key" > /tmp/dependency-mutex-key.txt
        printf '%s' "$image_tag" > /tmp/dependency-image-tag.txt
        printf '%s' "$image_reference" > /tmp/dependency-image-reference.txt
        printf '%s' "$digest" > /tmp/dependency-image-digest.txt
        printf 'dependency image cache: %s (%s)\n' "$status" "$image_reference"
      volumeMounts:
      - name: registry-auth
        mountPath: "/root/.docker"
        readOnly: true
  - name: build-dependency-image
    synchronization:
      mutex:
        name: dependency-image-{{inputs.parameters.dependency-mutex-key}}
    inputs:
      parameters:
      - name: cache-status
      - name: dependency-image-tag
      - name: dependency-image-reference
      - name: dependency-mutex-key
      - name: force-rebuild
      - name: buildkit-address
      - name: runtime-image
    outputs:
      parameters:
      - name: dependency-image-reference
        valueFrom:
          path: "/workspace/generated/dependency-image-reference.txt"
      - name: dependency-image-digest
        valueFrom:
          path: "/workspace/generated/dependency-image-digest.txt"
      - name: dependency-image-result
        valueFrom:
          path: "/workspace/generated/dependency-image-result.txt"
      - name: dependency-build-seconds
        valueFrom:
          path: "/workspace/generated/dependency-build-seconds.txt"
    script:
      image: harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      env:
      - name: DOCKER_CONFIG
        value: "/root/.docker"
      source: |
        set -euo pipefail
        mkdir -p /workspace/generated
        image_tag='{{inputs.parameters.dependency-image-tag}}'
        input_reference='{{inputs.parameters.dependency-image-reference}}'
        force_rebuild='{{inputs.parameters.force-rebuild}}'
        digest=''
        result=REUSED
        seconds=0

        if [ '{{inputs.parameters.cache-status}}' = HIT ] && [ "$force_rebuild" = false ]; then
          digest="${input_reference##*@}"
          reference="$input_reference"
        else
          # Mutex 대기 중 다른 Workflow가 이미 생성했을 수 있으므로 다시 확인한다.
          if [ "$force_rebuild" = false ] && digest="$(crane digest "$image_tag" 2>/tmp/crane-error.txt)"; then
            result=REUSED_AFTER_WAIT
            reference="${image_tag}@${digest}"
          else
            if [ "$force_rebuild" = false ] && ! grep -Eqi 'manifest unknown|name unknown|not found|404' /tmp/crane-error.txt; then
              echo 'Harbor dependency cache recheck failed:' >&2
              cat /tmp/crane-error.txt >&2
              exit 1
            fi
            start="$(date +%s)"
            buildctl --addr '{{inputs.parameters.buildkit-address}}' build \
              --progress=plain \
              --frontend dockerfile.v0 \
              --local context=/workspace/generated/context \
              --local dockerfile=/workspace/generated/context \
              --opt filename=Dockerfile \
              --opt target=dependency-image \
              --opt 'build-arg:RUNTIME_IMAGE={{inputs.parameters.runtime-image}}' \
              --opt "build-arg:DEPENDENCY_IMAGE=${image_tag}" \
              --output "type=image,name=${image_tag},push=true" \
              --metadata-file /workspace/generated/dependency-build-metadata.json
            end="$(date +%s)"
            seconds="$((end - start))"
            digest="$(jq -r '."containerimage.digest" // ."containerimage.descriptor".digest // empty' /workspace/generated/dependency-build-metadata.json)"
            result=BUILT
            reference="${image_tag}@${digest}"
          fi
        fi

        printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo 'invalid dependency image digest' >&2; exit 1; }
        printf '%s' "$reference" > /workspace/generated/dependency-image-reference.txt
        printf '%s' "$digest" > /workspace/generated/dependency-image-digest.txt
        printf '%s' "$result" > /workspace/generated/dependency-image-result.txt
        printf '%s' "$seconds" > /workspace/generated/dependency-build-seconds.txt
        printf 'dependency image %s: %s\n' "$result" "$reference"
      volumeMounts:
      - name: workspace
        mountPath: "/workspace"
      - name: registry-auth
        mountPath: "/root/.docker"
        readOnly: true
```

## 2. 전체 Argo WorkflowTemplate JSON

```json
{
  "apiVersion": "argoproj.io/v1alpha1",
  "kind": "WorkflowTemplate",
  "metadata": {
    "name": "run-python-image-template-with-buildkit",
    "namespace": "argo",
    "labels": {
      "workflows.argoproj.io/creator": "system-serviceaccount-argo-argo-server"
    }
  },
  "spec": {
    "entrypoint": "main",
    "serviceAccountName": "argo-kserver",
    "arguments": {
      "parameters": [
        {
          "name": "bitbucket-address-user-code",
          "value": "git@bitbucket.CHANGE_ME.internal:project/sample-api.git"
        },
        {
          "name": "runtime-image",
          "value": "harbor.CHANGE_ME.internal/runtime/python311@sha256:0000000000000000000000000000000000000000000000000000000000000000"
        },
        {
          "name": "runtime-lineage",
          "value": "python311-cpu"
        },
        {
          "name": "nexus-pypi-url",
          "value": "https://nexus.CHANGE_ME.internal/simple"
        },
        {
          "name": "registry-address",
          "value": "harbor.CHANGE_ME.internal"
        },
        {
          "name": "registry-project",
          "value": "applications"
        },
        {
          "name": "image-tag",
          "value": "1.0.0"
        },
        {
          "name": "cache-registry-address",
          "value": "harbor.CHANGE_ME.internal/build-cache"
        },
        {
          "name": "buildkit-address",
          "value": "tcp://buildkitd.CHANGE_ME.internal:1234"
        },
        {
          "name": "notification-server-url",
          "value": ""
        },
        {
          "name": "python-abi",
          "value": "cp311"
        },
        {
          "name": "target-platform",
          "value": "linux-amd64"
        },
        {
          "name": "workload-role",
          "value": "serve"
        },
        {
          "name": "training-serving-pattern",
          "value": "strict"
        },
        {
          "name": "inference-server-runtime",
          "value": "python-runtime"
        },
        {
          "name": "artifact-contract-file",
          "value": "artifact-contract.json"
        },
        {
          "name": "model-artifact-policy",
          "value": "external"
        },
        {
          "name": "model-artifact-reference",
          "value": ""
        },
        {
          "name": "image-builder-category",
          "value": "ai-ml-python"
        },
        {
          "name": "image-builder-spec-file",
          "value": "image-builder.spec.json"
        },
        {
          "name": "force-rebuild-dependencies",
          "value": "false"
        }
      ]
    },
    "volumeClaimTemplates": [
      {
        "metadata": {
          "name": "workspace"
        },
        "spec": {
          "accessModes": [
            "ReadWriteMany"
          ],
          "storageClassName": "CHANGE_ME-rwx-storage",
          "resources": {
            "requests": {
              "storage": "20Gi"
            }
          }
        }
      }
    ],
    "volumes": [
      {
        "name": "registry-auth",
        "secret": {
          "secretName": "registry-auth"
        }
      },
      {
        "name": "bitbucket-ssh",
        "secret": {
          "secretName": "bitbucket-ssh",
          "defaultMode": 256
        }
      }
    ],
    "templates": [
      {
        "name": "main",
        "dag": {
          "tasks": [
            {
              "name": "get-repository-name-from-git",
              "template": "get-repository-name-from-git",
              "arguments": {
                "parameters": [
                  {
                    "name": "git-address",
                    "value": "{{workflow.parameters.bitbucket-address-user-code}}"
                  }
                ]
              }
            },
            {
              "name": "clone-source",
              "depends": "get-repository-name-from-git.Succeeded",
              "template": "clone-source",
              "arguments": {
                "parameters": [
                  {
                    "name": "git-address",
                    "value": "{{workflow.parameters.bitbucket-address-user-code}}"
                  }
                ]
              }
            },
            {
              "name": "validate-runtime-image",
              "template": "validate-runtime-image",
              "arguments": {
                "parameters": [
                  {
                    "name": "runtime-image",
                    "value": "{{workflow.parameters.runtime-image}}"
                  }
                ]
              }
            },
            {
              "name": "validate-lock",
              "depends": "clone-source.Succeeded",
              "template": "validate-lock"
            },
            {
              "name": "check-dependency-image",
              "depends": "validate-lock.Succeeded && validate-runtime-image.Succeeded",
              "template": "check-dependency-image",
              "arguments": {
                "parameters": [
                  {
                    "name": "cache-registry-address",
                    "value": "{{workflow.parameters.cache-registry-address}}"
                  },
                  {
                    "name": "lock-hash",
                    "value": "{{tasks.validate-lock.outputs.parameters.lock-hash}}"
                  },
                  {
                    "name": "runtime-image-digest",
                    "value": "{{tasks.validate-runtime-image.outputs.parameters.parent-image-digest}}"
                  },
                  {
                    "name": "python-abi",
                    "value": "{{workflow.parameters.python-abi}}"
                  },
                  {
                    "name": "target-platform",
                    "value": "{{workflow.parameters.target-platform}}"
                  },
                  {
                    "name": "force-rebuild",
                    "value": "{{workflow.parameters.force-rebuild-dependencies}}"
                  }
                ]
              }
            },
            {
              "name": "download-wheels",
              "depends": "check-dependency-image.Succeeded",
              "template": "download-wheels",
              "arguments": {
                "parameters": [
                  {
                    "name": "nexus-pypi-url",
                    "value": "{{workflow.parameters.nexus-pypi-url}}"
                  },
                  {
                    "name": "lock-file-name",
                    "value": "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
                  },
                  {
                    "name": "dependency-cache-status",
                    "value": "{{tasks.check-dependency-image.outputs.parameters.cache-status}}"
                  }
                ]
              }
            },
            {
              "name": "prepare-build-context",
              "depends": "validate-runtime-image.Succeeded && download-wheels.Succeeded",
              "template": "prepare-build-context",
              "arguments": {
                "parameters": [
                  {
                    "name": "repository-name",
                    "value": "{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}"
                  },
                  {
                    "name": "runtime-image",
                    "value": "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
                  },
                  {
                    "name": "runtime-lineage",
                    "value": "{{workflow.parameters.runtime-lineage}}"
                  },
                  {
                    "name": "parent-image-digest",
                    "value": "{{tasks.validate-runtime-image.outputs.parameters.parent-image-digest}}"
                  },
                  {
                    "name": "lock-file-name",
                    "value": "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
                  },
                  {
                    "name": "lock-hash",
                    "value": "{{tasks.validate-lock.outputs.parameters.lock-hash}}"
                  },
                  {
                    "name": "image-reference",
                    "value": "{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/{{workflow.parameters.runtime-lineage}}/{{workflow.parameters.workload-role}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:{{workflow.parameters.image-tag}}"
                  },
                  {
                    "name": "cache-reference",
                    "value": "{{workflow.parameters.cache-registry-address}}/{{workflow.parameters.runtime-lineage}}/{{workflow.parameters.workload-role}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:buildcache"
                  },
                  {
                    "name": "dependency-cache-status",
                    "value": "{{tasks.check-dependency-image.outputs.parameters.cache-status}}"
                  },
                  {
                    "name": "workload-role",
                    "value": "{{workflow.parameters.workload-role}}"
                  },
                  {
                    "name": "training-serving-pattern",
                    "value": "{{workflow.parameters.training-serving-pattern}}"
                  },
                  {
                    "name": "inference-server-runtime",
                    "value": "{{workflow.parameters.inference-server-runtime}}"
                  },
                  {
                    "name": "artifact-contract-file",
                    "value": "{{workflow.parameters.artifact-contract-file}}"
                  },
                  {
                    "name": "model-artifact-policy",
                    "value": "{{workflow.parameters.model-artifact-policy}}"
                  },
                  {
                    "name": "model-artifact-reference",
                    "value": "{{workflow.parameters.model-artifact-reference}}"
                  },
                  {
                    "name": "image-builder-category",
                    "value": "{{workflow.parameters.image-builder-category}}"
                  },
                  {
                    "name": "image-builder-spec-file",
                    "value": "{{workflow.parameters.image-builder-spec-file}}"
                  }
                ]
              }
            },
            {
              "name": "build-dependency-image",
              "depends": "prepare-build-context.Succeeded",
              "template": "build-dependency-image",
              "arguments": {
                "parameters": [
                  {
                    "name": "cache-status",
                    "value": "{{tasks.check-dependency-image.outputs.parameters.cache-status}}"
                  },
                  {
                    "name": "dependency-image-tag",
                    "value": "{{tasks.check-dependency-image.outputs.parameters.dependency-image-tag}}"
                  },
                  {
                    "name": "dependency-image-reference",
                    "value": "{{tasks.check-dependency-image.outputs.parameters.dependency-image-reference}}"
                  },
                  {
                    "name": "dependency-mutex-key",
                    "value": "{{tasks.check-dependency-image.outputs.parameters.dependency-mutex-key}}"
                  },
                  {
                    "name": "force-rebuild",
                    "value": "{{workflow.parameters.force-rebuild-dependencies}}"
                  },
                  {
                    "name": "buildkit-address",
                    "value": "{{workflow.parameters.buildkit-address}}"
                  },
                  {
                    "name": "runtime-image",
                    "value": "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
                  }
                ]
              }
            },
            {
              "name": "build-release-image",
              "depends": "build-dependency-image.Succeeded",
              "template": "build-release-image",
              "arguments": {
                "parameters": [
                  {
                    "name": "buildkit-address",
                    "value": "{{workflow.parameters.buildkit-address}}"
                  },
                  {
                    "name": "runtime-image",
                    "value": "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
                  },
                  {
                    "name": "runtime-lineage",
                    "value": "{{workflow.parameters.runtime-lineage}}"
                  },
                  {
                    "name": "image-reference",
                    "value": "{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/{{workflow.parameters.runtime-lineage}}/{{workflow.parameters.workload-role}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:{{workflow.parameters.image-tag}}"
                  },
                  {
                    "name": "cache-reference",
                    "value": "{{workflow.parameters.cache-registry-address}}/{{workflow.parameters.runtime-lineage}}/{{workflow.parameters.workload-role}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:buildcache"
                  },
                  {
                    "name": "dependency-image",
                    "value": "{{tasks.build-dependency-image.outputs.parameters.dependency-image-reference}}"
                  },
                  {
                    "name": "workload-role",
                    "value": "{{workflow.parameters.workload-role}}"
                  },
                  {
                    "name": "training-serving-pattern",
                    "value": "{{workflow.parameters.training-serving-pattern}}"
                  },
                  {
                    "name": "inference-server-runtime",
                    "value": "{{workflow.parameters.inference-server-runtime}}"
                  },
                  {
                    "name": "artifact-contract-file",
                    "value": "{{workflow.parameters.artifact-contract-file}}"
                  },
                  {
                    "name": "model-artifact-policy",
                    "value": "{{workflow.parameters.model-artifact-policy}}"
                  },
                  {
                    "name": "model-artifact-reference",
                    "value": "{{workflow.parameters.model-artifact-reference}}"
                  },
                  {
                    "name": "image-builder-category",
                    "value": "{{workflow.parameters.image-builder-category}}"
                  },
                  {
                    "name": "image-builder-spec-file",
                    "value": "{{workflow.parameters.image-builder-spec-file}}"
                  }
                ]
              }
            },
            {
              "name": "parse-image-digest",
              "depends": "build-release-image.Succeeded",
              "template": "parse-image-digest",
              "arguments": {
                "parameters": [
                  {
                    "name": "image-digest",
                    "value": "{{tasks.build-release-image.outputs.parameters.image-digest}}"
                  }
                ]
              }
            },
            {
              "name": "generate-build-report",
              "depends": "parse-image-digest.Succeeded",
              "template": "generate-build-report",
              "arguments": {
                "parameters": [
                  {
                    "name": "repository-name",
                    "value": "{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}"
                  },
                  {
                    "name": "image-reference",
                    "value": "{{tasks.build-release-image.outputs.parameters.image-reference}}"
                  },
                  {
                    "name": "image-digest",
                    "value": "{{tasks.parse-image-digest.outputs.parameters.parsed-image-digest}}"
                  },
                  {
                    "name": "parent-image-digest",
                    "value": "{{tasks.validate-runtime-image.outputs.parameters.parent-image-digest}}"
                  },
                  {
                    "name": "runtime-image",
                    "value": "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
                  },
                  {
                    "name": "runtime-lineage",
                    "value": "{{workflow.parameters.runtime-lineage}}"
                  },
                  {
                    "name": "workload-role",
                    "value": "{{workflow.parameters.workload-role}}"
                  },
                  {
                    "name": "training-serving-pattern",
                    "value": "{{workflow.parameters.training-serving-pattern}}"
                  },
                  {
                    "name": "inference-server-runtime",
                    "value": "{{workflow.parameters.inference-server-runtime}}"
                  },
                  {
                    "name": "artifact-contract-file",
                    "value": "{{workflow.parameters.artifact-contract-file}}"
                  },
                  {
                    "name": "model-artifact-policy",
                    "value": "{{workflow.parameters.model-artifact-policy}}"
                  },
                  {
                    "name": "model-artifact-reference",
                    "value": "{{workflow.parameters.model-artifact-reference}}"
                  },
                  {
                    "name": "image-builder-category",
                    "value": "{{workflow.parameters.image-builder-category}}"
                  },
                  {
                    "name": "image-builder-spec-file",
                    "value": "{{workflow.parameters.image-builder-spec-file}}"
                  },
                  {
                    "name": "lock-file-name",
                    "value": "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
                  },
                  {
                    "name": "lock-hash",
                    "value": "{{tasks.validate-lock.outputs.parameters.lock-hash}}"
                  },
                  {
                    "name": "wheel-count",
                    "value": "{{tasks.download-wheels.outputs.parameters.wheel-count}}"
                  },
                  {
                    "name": "wheel-total-bytes",
                    "value": "{{tasks.download-wheels.outputs.parameters.wheel-total-bytes}}"
                  },
                  {
                    "name": "wheel-download-seconds",
                    "value": "{{tasks.download-wheels.outputs.parameters.download-seconds}}"
                  },
                  {
                    "name": "average-download-bytes-per-second",
                    "value": "{{tasks.download-wheels.outputs.parameters.average-download-bytes-per-second}}"
                  },
                  {
                    "name": "build-seconds",
                    "value": "{{tasks.build-release-image.outputs.parameters.build-seconds}}"
                  },
                  {
                    "name": "dependency-cache-status",
                    "value": "{{tasks.check-dependency-image.outputs.parameters.cache-status}}"
                  },
                  {
                    "name": "dependency-cache-key",
                    "value": "{{tasks.check-dependency-image.outputs.parameters.dependency-cache-key}}"
                  },
                  {
                    "name": "dependency-image-reference",
                    "value": "{{tasks.build-dependency-image.outputs.parameters.dependency-image-reference}}"
                  },
                  {
                    "name": "dependency-image-result",
                    "value": "{{tasks.build-dependency-image.outputs.parameters.dependency-image-result}}"
                  },
                  {
                    "name": "dependency-build-seconds",
                    "value": "{{tasks.build-dependency-image.outputs.parameters.dependency-build-seconds}}"
                  }
                ]
              }
            },
            {
              "name": "notify-build-result",
              "depends": "generate-build-report.Succeeded",
              "template": "notify-build-result",
              "arguments": {
                "parameters": [
                  {
                    "name": "notification-server-url",
                    "value": "{{workflow.parameters.notification-server-url}}"
                  },
                  {
                    "name": "report-json",
                    "value": "{{tasks.generate-build-report.outputs.parameters.report-json}}"
                  }
                ]
              }
            }
          ]
        }
      },
      {
        "name": "get-repository-name-from-git",
        "inputs": {
          "parameters": [
            {
              "name": "git-address"
            }
          ]
        },
        "outputs": {
          "parameters": [
            {
              "name": "repository-name",
              "valueFrom": {
                "path": "/tmp/repository-name.txt"
              }
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/python-tools:3.11@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\npython - <<'PY'\nimport re\nimport sys\n\naddress = r'''{{inputs.parameters.git-address}}'''.strip()\nif not address or any(c in address for c in \"\\r\\n\\0\"):\n    sys.exit(\"git-address is empty or contains a forbidden character\")\nmatch = re.search(r\"(?:[:/])([^/:]+?)(?:\\.git)?/?$\", address)\nif not match:\n    sys.exit(\"unable to extract repository name from git-address\")\nname = re.sub(r\"\\.git$\", \"\", match.group(1))\nif not re.fullmatch(r\"[A-Za-z0-9._-]+\", name):\n    sys.exit(\"repository name contains unsupported characters\")\nwith open(\"/tmp/repository-name.txt\", \"w\", encoding=\"utf-8\") as output:\n    output.write(name)\nprint(f\"repository-name={name}\")\nPY\n"
        }
      },
      {
        "name": "clone-source",
        "inputs": {
          "parameters": [
            {
              "name": "git-address"
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/git-tools:2.45@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\nrm -rf /workspace/generated/context/app\nmkdir -p /workspace/generated/context\nchmod 700 /root/.ssh\nexport GIT_SSH_COMMAND=\"ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts\"\ngit clone --depth 1 -- \"{{inputs.parameters.git-address}}\" /workspace/generated/context/app\n",
          "volumeMounts": [
            {
              "name": "workspace",
              "mountPath": "/workspace"
            },
            {
              "name": "bitbucket-ssh",
              "mountPath": "/root/.ssh",
              "readOnly": true
            }
          ]
        }
      },
      {
        "name": "validate-runtime-image",
        "inputs": {
          "parameters": [
            {
              "name": "runtime-image"
            }
          ]
        },
        "outputs": {
          "parameters": [
            {
              "name": "runtime-image",
              "valueFrom": {
                "path": "/tmp/runtime-image.txt"
              }
            },
            {
              "name": "parent-image-digest",
              "valueFrom": {
                "path": "/tmp/parent-image-digest.txt"
              }
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/python-tools:3.11@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\npython - <<'PY'\nimport re\nimport sys\n\nimage = r'''{{inputs.parameters.runtime-image}}'''.strip()\nif \"@\" not in image:\n    sys.exit(\"runtime-image must be pinned by digest\")\nreference, digest = image.rsplit(\"@\", 1)\nif not reference or not re.fullmatch(r\"sha256:[0-9a-f]{64}\", digest):\n    sys.exit(\"runtime-image must end with @sha256:<64 lowercase hex characters>\")\nopen(\"/tmp/runtime-image.txt\", \"w\", encoding=\"utf-8\").write(image)\nopen(\"/tmp/parent-image-digest.txt\", \"w\", encoding=\"utf-8\").write(digest)\nprint(\"runtime image digest format is valid\")\nPY\n"
        }
      },
      {
        "name": "validate-lock",
        "outputs": {
          "parameters": [
            {
              "name": "lock-file-name",
              "valueFrom": {
                "path": "/workspace/generated/lock-file-name.txt"
              }
            },
            {
              "name": "lock-hash",
              "valueFrom": {
                "path": "/workspace/generated/lock-hash.txt"
              }
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\nmkdir -p /workspace/generated\nif [ -f /workspace/generated/context/app/requirements.lock ]; then\n  lock_file=requirements.lock\nelif [ -f /workspace/generated/context/app/requirements.txt ]; then\n  lock_file=requirements.txt\n  echo \"WARNING: requirements.txt fallback is allowed for migration only; use requirements.lock in production\" >&2\nelse\n  echo \"neither requirements.lock nor requirements.txt exists\" >&2\n  exit 1\nfi\npython /opt/build-tools/scripts/validate_lock.py \"/workspace/generated/context/app/$lock_file\"\nprintf '%s' \"$lock_file\" > /workspace/generated/lock-file-name.txt\nsha256sum \"/workspace/generated/context/app/$lock_file\" | awk '{print $1}' > /workspace/generated/lock-hash.txt\n",
          "volumeMounts": [
            {
              "name": "workspace",
              "mountPath": "/workspace"
            }
          ]
        }
      },
      {
        "name": "download-wheels",
        "synchronization": {
          "semaphore": {
            "configMapKeyRef": {
              "name": "nexus-concurrency-limit",
              "key": "wheel-downloads"
            }
          }
        },
        "inputs": {
          "parameters": [
            {
              "name": "nexus-pypi-url"
            },
            {
              "name": "lock-file-name"
            },
            {
              "name": "dependency-cache-status"
            }
          ]
        },
        "outputs": {
          "parameters": [
            {
              "name": "wheel-count",
              "valueFrom": {
                "path": "/workspace/generated/wheel-count.txt"
              }
            },
            {
              "name": "wheel-total-bytes",
              "valueFrom": {
                "path": "/workspace/generated/wheel-total-bytes.txt"
              }
            },
            {
              "name": "download-seconds",
              "valueFrom": {
                "path": "/workspace/generated/download-seconds.txt"
              }
            },
            {
              "name": "average-download-bytes-per-second",
              "valueFrom": {
                "path": "/workspace/generated/average-download-bytes-per-second.txt"
              }
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\nwheelhouse=/workspace/generated/context/wheelhouse\nrm -rf \"$wheelhouse\"\nmkdir -p \"$wheelhouse\" /workspace/generated\n\nif [ '{{inputs.parameters.dependency-cache-status}}' = HIT ]; then\n  printf '0' > /workspace/generated/wheel-count.txt\n  printf '0' > /workspace/generated/wheel-total-bytes.txt\n  printf '0' > /workspace/generated/download-seconds.txt\n  printf '0' > /workspace/generated/average-download-bytes-per-second.txt\n  echo 'dependency image cache HIT; Nexus download skipped'\n  exit 0\nfi\n\nstart=\"$(date +%s)\"\npython -m pip download \\\n  --index-url \"{{inputs.parameters.nexus-pypi-url}}\" \\\n  --only-binary=:all: \\\n  --prefer-binary \\\n  --disable-pip-version-check \\\n  --timeout 30 \\\n  --retries 3 \\\n  --requirement \"/workspace/generated/context/app/{{inputs.parameters.lock-file-name}}\" \\\n  --dest \"$wheelhouse\"\nend=\"$(date +%s)\"\nseconds=\"$((end - start))\"\ncount=\"$(find \"$wheelhouse\" -type f -name '*.whl' | wc -l | tr -d ' ')\"\n[ \"$count\" -gt 0 ] || { echo \"wheelhouse is empty\" >&2; exit 1; }\nbytes=\"$(find \"$wheelhouse\" -type f -name '*.whl' -exec stat -c '%s' {} + | awk '{sum += $1} END {print sum + 0}')\"\naverage=\"$((bytes / (seconds > 0 ? seconds : 1)))\"\nprintf '%s' \"$count\" > /workspace/generated/wheel-count.txt\nprintf '%s' \"$bytes\" > /workspace/generated/wheel-total-bytes.txt\nprintf '%s' \"$seconds\" > /workspace/generated/download-seconds.txt\nprintf '%s' \"$average\" > /workspace/generated/average-download-bytes-per-second.txt\nprintf 'downloaded %s wheels anonymously from Nexus (%s bytes) in %s seconds\\n' \"$count\" \"$bytes\" \"$seconds\"\n",
          "volumeMounts": [
            {
              "name": "workspace",
              "mountPath": "/workspace"
            }
          ]
        }
      },
      {
        "name": "prepare-build-context",
        "inputs": {
          "parameters": [
            {
              "name": "repository-name"
            },
            {
              "name": "runtime-image"
            },
            {
              "name": "runtime-lineage"
            },
            {
              "name": "workload-role"
            },
            {
              "name": "training-serving-pattern"
            },
            {
              "name": "inference-server-runtime"
            },
            {
              "name": "artifact-contract-file"
            },
            {
              "name": "model-artifact-policy"
            },
            {
              "name": "model-artifact-reference"
            },
            {
              "name": "image-builder-category"
            },
            {
              "name": "image-builder-spec-file"
            },
            {
              "name": "parent-image-digest"
            },
            {
              "name": "lock-file-name"
            },
            {
              "name": "lock-hash"
            },
            {
              "name": "image-reference"
            },
            {
              "name": "cache-reference"
            },
            {
              "name": "dependency-cache-status"
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\ncontext=/workspace/generated/context\ntest -d \"$context/app\"\ntest -d \"$context/wheelhouse\"\nworkload_role='{{inputs.parameters.workload-role}}'\nruntime_lineage='{{inputs.parameters.runtime-lineage}}'\ntraining_serving_pattern='{{inputs.parameters.training-serving-pattern}}'\ninference_server_runtime='{{inputs.parameters.inference-server-runtime}}'\nartifact_contract_file='{{inputs.parameters.artifact-contract-file}}'\nmodel_artifact_policy='{{inputs.parameters.model-artifact-policy}}'\nmodel_artifact_reference='{{inputs.parameters.model-artifact-reference}}'\nimage_builder_category='{{inputs.parameters.image-builder-category}}'\nimage_builder_spec_file='{{inputs.parameters.image-builder-spec-file}}'\ncase \"$workload_role\" in\n  train|job|serve|infer) ;;\n  *) echo \"workload-role must be one of train, job, serve, infer\" >&2; exit 1 ;;\nesac\nprintf '%s' \"$runtime_lineage\" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' || { echo 'runtime-lineage must use lowercase registry-safe characters' >&2; exit 1; }\nprintf '%s' \"$image_builder_category\" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' || { echo 'image-builder-category must use lowercase registry-safe characters' >&2; exit 1; }\nprintf '%s' \"$image_builder_spec_file\" | grep -Eq '^[A-Za-z0-9._-]+$' || { echo 'image-builder-spec-file must be a file name, not a path' >&2; exit 1; }\ncase \"$training_serving_pattern\" in\n  strict|optimized) ;;\n  *) echo 'training-serving-pattern must be strict or optimized' >&2; exit 1 ;;\nesac\ncase \"$inference_server_runtime\" in\n  python-runtime|triton|tensorrt|vllm|onnxruntime|custom) ;;\n  *) echo 'inference-server-runtime must be python-runtime, triton, tensorrt, vllm, onnxruntime, or custom' >&2; exit 1 ;;\nesac\ncase \"$model_artifact_policy\" in\n  external) ;;\n  *) echo 'model-artifact-policy must be external in this template; model files are not embedded in images by default' >&2; exit 1 ;;\nesac\nif [ \"$model_artifact_policy\" = external ] && [ -z \"$model_artifact_reference\" ]; then\n  printf '[Model] model-artifact-policy=external: model files are excluded from image and should be mounted or resolved by deployment runtime.\\n'\nfi\nif [ \"$training_serving_pattern\" = optimized ]; then\n  case \"$workload_role\" in serve|infer) ;; *) echo 'optimized pattern is only valid for serve or infer workloads' >&2; exit 1 ;; esac\n  test -s \"$context/app/$artifact_contract_file\" || { echo \"optimized inference requires artifact contract file: $artifact_contract_file\" >&2; exit 1; }\nfi\nif [ '{{inputs.parameters.dependency-cache-status}}' = MISS ]; then\n  find \"$context/wheelhouse\" -type f -name '*.whl' -print -quit | grep -q . || { echo 'wheelhouse is empty on cache MISS' >&2; exit 1; }\nfi\nrm -rf \"$context/app/.git\"\ncp \"$context/app/{{inputs.parameters.lock-file-name}}\" \"$context/requirements.lock\"\n\n# BuildKit 전송 대상에서 개발 산출물과 중복 Lock 파일을 제외합니다.\ncat > \"$context/.dockerignore\" <<'DOCKERIGNORE'\n**/.git\n**/.venv\n**/__pycache__\n**/*.pyc\n**/.pytest_cache\n**/.mypy_cache\n**/.ruff_cache\n**/dist\n**/build\n**/node_modules\napp/requirements.lock\napp/requirements.txt\n# 모델은 기본적으로 이미지와 Build Context에 넣지 않는다. 배포 Runtime에서 PVC/Object Storage/Model Registry로 주입한다.\napp/model\napp/models\napp/model-artifacts\nDOCKERIGNORE\n\n# Docker 레이어 구조를 WorkflowTemplate JSON의 script.source에서 직접 생성합니다.\ncat > /workspace/generated/context/Dockerfile <<'DOCKERFILE'\n# syntax=docker/dockerfile:1.7\nARG RUNTIME_IMAGE\nARG DEPENDENCY_IMAGE\nARG WORKLOAD_ROLE\nARG TRAINING_SERVING_PATTERN\nARG INFERENCE_SERVER_RUNTIME\nARG ARTIFACT_CONTRACT_FILE\nARG MODEL_ARTIFACT_POLICY\nARG MODEL_ARTIFACT_REFERENCE\nARG IMAGE_BUILDER_CATEGORY\nARG IMAGE_BUILDER_SPEC_FILE\n\n# Runtime Contract는 OS Base, Accelerator ABI, Language Runtime, ML Framework, ML Ops Common을 digest로 고정한 공통 계약이다.\nFROM ${RUNTIME_IMAGE} AS runtime-contract\nLABEL org.opencontainers.image.runtime-contract.layers=\"L0-source-base,L1-os-foundation,L2-accelerator-abi,L3-language-runtime,L4-ml-framework,L5-ml-ops-common\" \\\n      org.opencontainers.image.layer.L0=\"source-base:digest-pin-required\" \\\n      org.opencontainers.image.layer.L1=\"os-foundation\" \\\n      org.opencontainers.image.layer.L2=\"accelerator-abi\" \\\n      org.opencontainers.image.layer.L3=\"language-runtime\" \\\n      org.opencontainers.image.layer.L4=\"ml-framework\" \\\n      org.opencontainers.image.layer.L5=\"ml-ops-common\"\n\n# Cache MISS에서만 실행해 Lock Hash 전용 Dependency Image를 생성\nFROM runtime-contract AS dependency-image\nENV PIP_DISABLE_PIP_VERSION_CHECK=1\nCOPY requirements.lock /build/requirements.lock\nCOPY wheelhouse /build/wheelhouse\nRUN python -m pip install \\\n      --no-index \\\n      --find-links=/build/wheelhouse \\\n      --only-binary=:all: \\\n      --prefix=/opt/python-dependencies \\\n      -r /build/requirements.lock \\\n    && rm -rf /root/.cache/pip /build/wheelhouse\n\n# Cache HIT/MISS 모두 Harbor Digest로 고정된 Dependency Image 사용\nFROM ${DEPENDENCY_IMAGE} AS dependencies\n\nFROM runtime-contract AS role-head\nARG WORKLOAD_ROLE\nARG TRAINING_SERVING_PATTERN\nARG INFERENCE_SERVER_RUNTIME\nARG ARTIFACT_CONTRACT_FILE\nARG MODEL_ARTIFACT_POLICY\nARG MODEL_ARTIFACT_REFERENCE\nARG IMAGE_BUILDER_CATEGORY\nARG IMAGE_BUILDER_SPEC_FILE\nENV AISTUDIO_WORKLOAD_ROLE=${WORKLOAD_ROLE} \\\n    AISTUDIO_TRAINING_SERVING_PATTERN=${TRAINING_SERVING_PATTERN} \\\n    AISTUDIO_INFERENCE_SERVER_RUNTIME=${INFERENCE_SERVER_RUNTIME} \\\n    AISTUDIO_ARTIFACT_CONTRACT_FILE=${ARTIFACT_CONTRACT_FILE} \\\n    AISTUDIO_MODEL_ARTIFACT_POLICY=${MODEL_ARTIFACT_POLICY} \\\n    AISTUDIO_MODEL_ARTIFACT_REFERENCE=${MODEL_ARTIFACT_REFERENCE} \\\n    AISTUDIO_IMAGE_BUILDER_CATEGORY=${IMAGE_BUILDER_CATEGORY} \\\n    AISTUDIO_IMAGE_BUILDER_SPEC_FILE=${IMAGE_BUILDER_SPEC_FILE} \\\n    PYTHONDONTWRITEBYTECODE=1 \\\n    PYTHONUNBUFFERED=1 \\\n    PIP_DISABLE_PIP_VERSION_CHECK=1\nLABEL org.opencontainers.image.runtime-contract.role=${WORKLOAD_ROLE} \\\n      org.opencontainers.image.training-serving.pattern=${TRAINING_SERVING_PATTERN} \\\n      org.opencontainers.image.inference.runtime=${INFERENCE_SERVER_RUNTIME} \\\n      org.opencontainers.image.artifact.contract=${ARTIFACT_CONTRACT_FILE} \\\n      org.opencontainers.image.model.artifact.policy=${MODEL_ARTIFACT_POLICY} \\\n      org.opencontainers.image.model.artifact.reference=${MODEL_ARTIFACT_REFERENCE} \\\n      org.opencontainers.image.builder.mode=\"declarative-spec\" \\\n      org.opencontainers.image.builder.category=${IMAGE_BUILDER_CATEGORY} \\\n      org.opencontainers.image.builder.spec=${IMAGE_BUILDER_SPEC_FILE} \\\n      org.opencontainers.image.builder.security-policy=\"required\" \\\n      org.opencontainers.image.builder.reproducibility-policy=\"required\" \\\n      org.opencontainers.image.layer.L6=\"role-head:${WORKLOAD_ROLE}\"\nWORKDIR /app\nRUN case \"$AISTUDIO_WORKLOAD_ROLE\" in train|job|serve|infer) ;; *) echo \"invalid workload role\" >&2; exit 1 ;; esac \\\n    && case \"$AISTUDIO_TRAINING_SERVING_PATTERN\" in strict|optimized) ;; *) echo \"invalid training-serving pattern\" >&2; exit 1 ;; esac \\\n    && if [ \"$AISTUDIO_TRAINING_SERVING_PATTERN\" = optimized ]; then case \"$AISTUDIO_WORKLOAD_ROLE\" in serve|infer) ;; *) echo \"optimized pattern is only valid for serve or infer\" >&2; exit 1 ;; esac; fi \\\n    && case \"$AISTUDIO_MODEL_ARTIFACT_POLICY\" in external) ;; *) echo \"model artifact policy must be external\" >&2; exit 1 ;; esac\n\nFROM role-head AS test\nCOPY --from=dependencies /opt/python-dependencies/ /usr/local/\nCOPY app /app\nRUN python -m compileall -q /app \\\n    && if [ -d /app/tests ]; then python -m pytest -q /app/tests; fi \\\n    && touch /test-passed\n\nFROM role-head AS project-app\nLABEL org.opencontainers.image.layer.L7=\"project-app\"\nCOPY app /project\nRUN rm -rf /project/tests /project/test /project/.git \\\n    /project/.pytest_cache /project/.mypy_cache /project/.ruff_cache \\\n    /project/model /project/models /project/model-artifacts\n\nFROM role-head AS model-artifact\nLABEL org.opencontainers.image.layer.L8=\"model-artifact-external\" \\\n      org.opencontainers.image.model.artifact.default=\"external\"\nRUN mkdir -p /model-artifacts \\\n    && printf '%s\\n' 'Model files are intentionally excluded from the image. Mount or resolve them at deployment runtime.' > /model-artifacts/README.txt\n\nFROM role-head AS release\nLABEL org.opencontainers.image.layer.L7=\"project-app\" \\\n      org.opencontainers.image.layer.L8=\"model-artifact-external\"\nENV MODEL_ARTIFACT_DIR=/model-artifacts\nCOPY --from=test /test-passed /tmp/test-passed\nCOPY --from=dependencies /opt/python-dependencies/ /usr/local/\nCOPY --from=project-app /project /app\nCOPY --from=model-artifact /model-artifacts /model-artifacts\nCOPY image-builder.spec.json /image-builder/image-builder.spec.json\nRUN rm -f /tmp/test-passed\nUSER 10001:10001\nCMD [\"python\", \"-m\", \"app\"]\nDOCKERFILE\n\ncat > \"$context/$image_builder_spec_file\" <<'JSON'\n{\n  \"schemaVersion\": \"image-builder/v1\",\n  \"builderMode\": \"declarative-spec\",\n  \"category\": \"{{inputs.parameters.image-builder-category}}\",\n  \"runtimeLineage\": \"{{inputs.parameters.runtime-lineage}}\",\n  \"imageBuilderMode\": \"declarative-spec\",\n  \"imageBuilderCategory\": \"{{inputs.parameters.image-builder-category}}\",\n  \"imageBuilderSpecFile\": \"{{inputs.parameters.image-builder-spec-file}}\",\n  \"imageBuilderPrinciple\": \"Central declarative image category controls Dockerfile generation, layer policy, validation and report metadata.\",\n  \"dockerfileStrategy\": \"multi-stage-target\",\n  \"buildTargets\": {\"dependency\":\"dependency-image\",\"test\":\"test\",\"release\":\"release\"},\n  \"targetPolicy\": {\"dependencyBuildTarget\":\"dependency-image\",\"releaseBuildTarget\":\"release\",\"releaseRequiresTestStage\":true,\"pushOnlyReleaseTarget\":true},\n  \"workloadRole\": \"{{inputs.parameters.workload-role}}\",\n  \"trainingServingPattern\": \"{{inputs.parameters.training-serving-pattern}}\",\n  \"inferenceServerRuntime\": \"{{inputs.parameters.inference-server-runtime}}\",\n  \"artifactContractFile\": \"{{inputs.parameters.artifact-contract-file}}\",\n  \"modelArtifactPolicy\": \"{{inputs.parameters.model-artifact-policy}}\",\n  \"modelArtifactReference\": \"{{inputs.parameters.model-artifact-reference}}\",\n  \"modelImagePolicy\": {\"default\":\"external\",\"embedModelFilesByDefault\":false,\"excludeModelDirectoriesFromBuildContext\":true,\"runtimeInjection\":\"PVC/ObjectStorage/ModelRegistry\"},\n  \"securityReproducibilityPolicy\": {\"required\":true,\"runtimeDigestPinned\":true,\"dependencyDigestPinned\":true,\"lockHashRequired\":true,\"noLatestTags\":true,\"nonRootUserRequired\":true,\"modelExternalByDefault\":true,\"buildReportRequired\":true,\"reproducibilityKey\":\"runtimeDigest+lockHash+pythonAbi+targetPlatform+builderSpec\"},\n  \"sourcePolicy\": {\n    \"dockerfileManagedBy\": \"workflow-template\",\n    \"manualDockerfilePerProject\": false,\n    \"centralCategoryRequired\": true\n  },\n  \"layers\": [\n    {\"level\": \"L0\", \"name\": \"source-base\", \"policy\": \"digest-pin-required\"},\n    {\"level\": \"L1\", \"name\": \"os-foundation\", \"policy\": \"runtime-contract\"},\n    {\"level\": \"L2\", \"name\": \"accelerator-abi\", \"policy\": \"runtime-contract\"},\n    {\"level\": \"L3\", \"name\": \"language-runtime\", \"policy\": \"runtime-contract\"},\n    {\"level\": \"L4\", \"name\": \"ml-framework\", \"policy\": \"runtime-contract\"},\n    {\"level\": \"L5\", \"name\": \"ml-ops-common\", \"policy\": \"runtime-contract\"},\n    {\"level\": \"L6\", \"name\": \"role-head\", \"policy\": \"thin-role-layer\"},\n    {\"level\": \"L7\", \"name\": \"project-app\", \"policy\": \"project-code-layer\"},\n    {\"level\": \"L8\", \"name\": \"model-artifact\", \"policy\": \"artifact-layer\"}\n  ],\n  \"validationRules\": [\n    \"runtime-image-must-be-digest-pinned\",\n    \"workload-role-must-be-train-job-serve-or-infer\",\n    \"optimized-serving-requires-artifact-contract\",\n    \"dependency-image-must-be-addressed-by-digest\",\n    \"security-reproducibility-policy-required\",\n    \"non-root-user-required\",\n    \"build-report-required\"\n  ]\n}\nJSON\nif [ \"$image_builder_spec_file\" != \"image-builder.spec.json\" ]; then\n  cp \"$context/$image_builder_spec_file\" \"$context/image-builder.spec.json\"\nfi\n\nprintf '%s' 'runtime-contract,dependency-image,dependencies,role-head,test,project-app,model-artifact,release' > /workspace/generated/docker-layer-stages.txt\ncat > /workspace/generated/build-spec.json <<'JSON'\n{\n  \"repositoryName\": \"{{inputs.parameters.repository-name}}\",\n  \"runtimeImage\": \"{{inputs.parameters.runtime-image}}\",\n  \"runtimeLineage\": \"{{inputs.parameters.runtime-lineage}}\",\n  \"imageBuilderMode\": \"declarative-spec\",\n  \"imageBuilderCategory\": \"{{inputs.parameters.image-builder-category}}\",\n  \"imageBuilderSpecFile\": \"{{inputs.parameters.image-builder-spec-file}}\",\n  \"imageBuilderPrinciple\": \"Central declarative image category controls Dockerfile generation, layer policy, validation and report metadata.\",\n  \"trainingServingPattern\": \"{{inputs.parameters.training-serving-pattern}}\",\n  \"inferenceServerRuntime\": \"{{inputs.parameters.inference-server-runtime}}\",\n  \"artifactContractFile\": \"{{inputs.parameters.artifact-contract-file}}\",\n  \"servingPatternRules\": {\"strict\":\"Training and Serving share the same Runtime Contract for Python model execution.\",\"optimized\":\"Serving may use an optimized inference runtime, but model artifacts must satisfy an explicit artifact contract and validation pipeline.\"},\n  \"declarativeImageBuilder\": {\"managedBy\":\"central-image-builder-spec\",\"manualDockerfilePerProject\":false,\"category\":\"{{inputs.parameters.image-builder-category}}\",\"specFile\":\"{{inputs.parameters.image-builder-spec-file}}\"},\n  \"dockerfileStrategy\": \"multi-stage-target\",\n  \"multiStageTargetStrategy\": {\"stages\":[\"runtime-contract\",\"dependency-image\",\"dependencies\",\"role-head\",\"test\",\"project-app\",\"model-artifact\",\"release\"],\"targets\":{\"dependency\":\"dependency-image\",\"test\":\"test\",\"release\":\"release\"},\"releaseTarget\":\"release\",\"pushOnlyReleaseTarget\":true,\"releaseRequiresTestStage\":true},\n  \"securityReproducibilityPolicy\": {\"required\":true,\"runtimeDigestPinned\":true,\"dependencyDigestPinned\":true,\"lockHashRequired\":true,\"noLatestTags\":true,\"nonRootUserRequired\":true,\"modelExternalByDefault\":true,\"buildReportRequired\":true,\"reproducibilityKey\":\"runtimeDigest+lockHash+pythonAbi+targetPlatform+builderSpec\"},\n  \"securityReproducibilityChecks\": [\"runtime-image-digest-pinned\",\"dependency-image-digest-pinned\",\"lock-hash-recorded\",\"image-digest-recorded\",\"non-root-user\",\"model-external\",\"no-latest-tags\",\"build-report-generated\"],\n  \"imageNamingConvention\": \"{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/<runtime-lineage>/<workload-role>/<project>:<tag>\",\n  \"parentImageDigest\": \"{{inputs.parameters.parent-image-digest}}\",\n  \"lockFileName\": \"{{inputs.parameters.lock-file-name}}\",\n  \"lockHash\": \"{{inputs.parameters.lock-hash}}\",\n  \"imageReference\": \"{{inputs.parameters.image-reference}}\",\n  \"cacheReference\": \"{{inputs.parameters.cache-reference}}\",\n  \"dockerLayerStages\": [\"runtime-contract\", \"dependency-image\", \"dependencies\", \"role-head\", \"test\", \"project-app\", \"model-artifact\", \"release\"],\n  \"runtimeContractLayers\": [\"os-base\", \"accelerator-abi\", \"language-runtime\", \"ml-framework\", \"ml-ops-common\"],\n  \"runtimeContractCriteria\": [\"runtime-image-digest\", \"os-base-digest\", \"accelerator-abi\", \"language-runtime\", \"ml-framework\", \"ml-ops-common\", \"target-platform\", \"python-abi\", \"security-and-path-contract\"],\n  \"recommendedImageLayers\": [{\"level\":\"L0\",\"name\":\"source-base\",\"description\":\"Ubuntu, Debian, UBI, NVIDIA CUDA 등 외부 원천 이미지\",\"operation\":\"digest-pin-required\"},{\"level\":\"L1\",\"name\":\"os-foundation\",\"description\":\"OS 패키지, glibc, CA trust, timezone 등 운영 OS 기준\"},{\"level\":\"L2\",\"name\":\"accelerator-abi\",\"description\":\"CUDA/ROCm, cuDNN, NCCL, GPU driver 호환 ABI\"},{\"level\":\"L3\",\"name\":\"language-runtime\",\"description\":\"Python/uv/pip 및 Python ABI\"},{\"level\":\"L4\",\"name\":\"ml-framework\",\"description\":\"PyTorch, TensorFlow, vLLM, Triton 등 ML Framework\"},{\"level\":\"L5\",\"name\":\"ml-ops-common\",\"description\":\"logging, metrics, tracing, auth, cert, 공통 운영 유틸리티\"},{\"level\":\"L6\",\"name\":\"role-head\",\"description\":\"train/job/serve/infer 역할별 얇은 실행 Head\"},{\"level\":\"L7\",\"name\":\"project-app\",\"description\":\"프로젝트 코드와 애플리케이션 설정\"},{\"level\":\"L8\",\"name\":\"model-artifact\",\"description\":\"모델 파일은 이미지에 포함하지 않고 외부 Model Registry/PVC/Object Storage Reference로 관리\"}],\n  \"workloadRole\": \"{{inputs.parameters.workload-role}}\"\n}\nJSON\ntest -s /workspace/generated/context/Dockerfile\ntest -s /workspace/generated/context/image-builder.spec.json\ntest -s /workspace/generated/build-spec.json\nprintf 'Docker layers: L0/L1/L2/L3/L4/L5 runtime-contract -> dependency-image -> dependencies -> L6 role-head -> test -> L7 project-app -> L8 model-artifact -> release\\n'\n",
          "volumeMounts": [
            {
              "name": "workspace",
              "mountPath": "/workspace"
            }
          ]
        }
      },
      {
        "name": "build-release-image",
        "inputs": {
          "parameters": [
            {
              "name": "buildkit-address"
            },
            {
              "name": "runtime-image"
            },
            {
              "name": "runtime-lineage"
            },
            {
              "name": "image-reference"
            },
            {
              "name": "cache-reference"
            },
            {
              "name": "dependency-image"
            },
            {
              "name": "workload-role"
            },
            {
              "name": "training-serving-pattern"
            },
            {
              "name": "inference-server-runtime"
            },
            {
              "name": "artifact-contract-file"
            },
            {
              "name": "model-artifact-policy"
            },
            {
              "name": "model-artifact-reference"
            },
            {
              "name": "image-builder-category"
            },
            {
              "name": "image-builder-spec-file"
            }
          ]
        },
        "outputs": {
          "parameters": [
            {
              "name": "image-reference",
              "valueFrom": {
                "path": "/workspace/generated/image-reference.txt"
              }
            },
            {
              "name": "image-digest",
              "valueFrom": {
                "path": "/workspace/generated/image-digest.txt"
              }
            },
            {
              "name": "build-seconds",
              "valueFrom": {
                "path": "/workspace/generated/build-seconds.txt"
              }
            },
            {
              "name": "push-seconds",
              "valueFrom": {
                "path": "/workspace/generated/push-seconds.txt"
              }
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "env": [
            {
              "name": "DOCKER_CONFIG",
              "value": "/root/.docker"
            }
          ],
          "source": "set -euo pipefail\nmkdir -p /workspace/generated\nstart=\"$(date +%s)\"\nprintf '[BuildKit] release build and Harbor push started at %s\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"\nbuildctl --addr \"{{inputs.parameters.buildkit-address}}\" build \\\n  --progress=plain \\\n  --frontend dockerfile.v0 \\\n  --local context=/workspace/generated/context \\\n  --local dockerfile=/workspace/generated/context \\\n  --opt filename=Dockerfile \\\n  --opt target=release \\\n  --opt \"build-arg:RUNTIME_IMAGE={{inputs.parameters.runtime-image}}\" \\\n  --opt \"build-arg:DEPENDENCY_IMAGE={{inputs.parameters.dependency-image}}\" \\\n  --opt \"build-arg:WORKLOAD_ROLE={{inputs.parameters.workload-role}}\" \\\n  --opt \"build-arg:TRAINING_SERVING_PATTERN={{inputs.parameters.training-serving-pattern}}\" \\\n  --opt \"build-arg:INFERENCE_SERVER_RUNTIME={{inputs.parameters.inference-server-runtime}}\" \\\n  --opt \"build-arg:ARTIFACT_CONTRACT_FILE={{inputs.parameters.artifact-contract-file}}\" \\\n  --opt \"build-arg:MODEL_ARTIFACT_POLICY={{inputs.parameters.model-artifact-policy}}\" \\\n  --opt \"build-arg:MODEL_ARTIFACT_REFERENCE={{inputs.parameters.model-artifact-reference}}\" \\\n  --opt \"build-arg:IMAGE_BUILDER_CATEGORY={{inputs.parameters.image-builder-category}}\" \\\n  --opt \"build-arg:IMAGE_BUILDER_SPEC_FILE={{inputs.parameters.image-builder-spec-file}}\" \\\n  --import-cache \"type=registry,ref={{inputs.parameters.cache-reference}}\" \\\n  --export-cache \"type=registry,ref={{inputs.parameters.cache-reference}},mode=min\" \\\n  --output \"type=image,name={{inputs.parameters.image-reference}},push=true\" \\\n  --metadata-file /workspace/generated/build-metadata.json\nend=\"$(date +%s)\"\ndigest=\"$(jq -r '.\"containerimage.digest\" // .\"containerimage.descriptor\".digest // empty' /workspace/generated/build-metadata.json)\"\nprintf '%s' \"$digest\" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo \"BuildKit did not return a valid image digest\" >&2; exit 1; }\nprintf '%s' \"{{inputs.parameters.image-reference}}\" > /workspace/generated/image-reference.txt\nprintf '%s' \"$digest\" > /workspace/generated/image-digest.txt\nprintf '%s' \"$((end - start))\" > /workspace/generated/build-seconds.txt\nprintf '%s' '0' > /workspace/generated/push-seconds.txt\nprintf '[BuildKit] release build, cache export and Harbor push completed in %s seconds: %s@%s\\n' \\\n  \"$((end - start))\" \"{{inputs.parameters.image-reference}}\" \"$digest\"\n",
          "volumeMounts": [
            {
              "name": "workspace",
              "mountPath": "/workspace"
            },
            {
              "name": "registry-auth",
              "mountPath": "/root/.docker",
              "readOnly": true
            }
          ]
        }
      },
      {
        "name": "parse-image-digest",
        "inputs": {
          "parameters": [
            {
              "name": "image-digest"
            }
          ]
        },
        "outputs": {
          "parameters": [
            {
              "name": "parsed-image-digest",
              "valueFrom": {
                "path": "/tmp/parsed-image-digest.txt"
              }
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\ndigest=\"$(printf '%s' \"{{inputs.parameters.image-digest}}\" | grep -Eo 'sha256:[0-9a-f]{64}' | head -n 1 || true)\"\n[ -n \"$digest\" ] || { echo \"valid image digest not found\" >&2; exit 1; }\nprintf '%s' \"$digest\" > /tmp/parsed-image-digest.txt\n"
        }
      },
      {
        "name": "generate-build-report",
        "inputs": {
          "parameters": [
            {
              "name": "repository-name"
            },
            {
              "name": "image-reference"
            },
            {
              "name": "image-digest"
            },
            {
              "name": "parent-image-digest"
            },
            {
              "name": "runtime-image"
            },
            {
              "name": "runtime-lineage"
            },
            {
              "name": "workload-role"
            },
            {
              "name": "training-serving-pattern"
            },
            {
              "name": "inference-server-runtime"
            },
            {
              "name": "artifact-contract-file"
            },
            {
              "name": "model-artifact-policy"
            },
            {
              "name": "model-artifact-reference"
            },
            {
              "name": "image-builder-category"
            },
            {
              "name": "image-builder-spec-file"
            },
            {
              "name": "lock-file-name"
            },
            {
              "name": "lock-hash"
            },
            {
              "name": "wheel-count"
            },
            {
              "name": "wheel-total-bytes"
            },
            {
              "name": "wheel-download-seconds"
            },
            {
              "name": "average-download-bytes-per-second"
            },
            {
              "name": "build-seconds"
            },
            {
              "name": "dependency-cache-status"
            },
            {
              "name": "dependency-cache-key"
            },
            {
              "name": "dependency-image-reference"
            },
            {
              "name": "dependency-image-result"
            },
            {
              "name": "dependency-build-seconds"
            }
          ]
        },
        "outputs": {
          "parameters": [
            {
              "name": "report-json",
              "valueFrom": {
                "path": "/workspace/output/build-report.json"
              }
            }
          ],
          "artifacts": [
            {
              "name": "build-report",
              "path": "/workspace/output/build-report.json",
              "archive": {
                "none": {
                }
              }
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\nmkdir -p /workspace/output\njq -n \\\n  --arg workflowName \"{{workflow.name}}\" \\\n  --arg workflowUid \"{{workflow.uid}}\" \\\n  --arg namespace \"{{workflow.namespace}}\" \\\n  --arg repositoryName \"{{inputs.parameters.repository-name}}\" \\\n  --arg imageReference \"{{inputs.parameters.image-reference}}\" \\\n  --arg imageDigest \"{{inputs.parameters.image-digest}}\" \\\n  --arg parentImageDigest \"{{inputs.parameters.parent-image-digest}}\" \\\n  --arg runtimeImage \"{{inputs.parameters.runtime-image}}\" \\\n  --arg runtimeLineage \"{{inputs.parameters.runtime-lineage}}\" \\\n  --arg workloadRole \"{{inputs.parameters.workload-role}}\" \\\n  --arg trainingServingPattern \"{{inputs.parameters.training-serving-pattern}}\" \\\n  --arg inferenceServerRuntime \"{{inputs.parameters.inference-server-runtime}}\" \\\n  --arg artifactContractFile \"{{inputs.parameters.artifact-contract-file}}\" \\\n  --arg modelArtifactPolicy \"{{inputs.parameters.model-artifact-policy}}\" \\\n  --arg modelArtifactReference \"{{inputs.parameters.model-artifact-reference}}\" \\\n  --arg imageBuilderMode \"declarative-spec\" \\\n  --arg imageBuilderCategory \"{{inputs.parameters.image-builder-category}}\" \\\n  --arg imageBuilderSpecFile \"{{inputs.parameters.image-builder-spec-file}}\" \\\n  --arg lockFileName \"{{inputs.parameters.lock-file-name}}\" \\\n  --arg lockHash \"{{inputs.parameters.lock-hash}}\" \\\n  --argjson wheelCount \"{{inputs.parameters.wheel-count}}\" \\\n  --argjson wheelTotalBytes \"{{inputs.parameters.wheel-total-bytes}}\" \\\n  --argjson wheelDownloadSeconds \"{{inputs.parameters.wheel-download-seconds}}\" \\\n  --argjson averageDownloadBytesPerSecond \"{{inputs.parameters.average-download-bytes-per-second}}\" \\\n  --arg dependencyCacheStatus \"{{inputs.parameters.dependency-cache-status}}\" \\\n  --arg dependencyCacheKey \"{{inputs.parameters.dependency-cache-key}}\" \\\n  --arg dependencyImageReference \"{{inputs.parameters.dependency-image-reference}}\" \\\n  --arg dependencyImageResult \"{{inputs.parameters.dependency-image-result}}\" \\\n  --argjson dependencyBuildSeconds \"{{inputs.parameters.dependency-build-seconds}}\" \\\n  --argjson buildSeconds \"{{inputs.parameters.build-seconds}}\" \\\n  --arg timestamp \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \\\n  '{workflowName:$workflowName,workflowUid:$workflowUid,namespace:$namespace,repositoryName:$repositoryName,imageReference:$imageReference,imageDigest:$imageDigest,parentImageDigest:$parentImageDigest,runtimeImage:$runtimeImage,runtimeLineage:$runtimeLineage,imageNamingConvention:\"<registry>/<project>/<runtime-lineage>/<workload-role>/<project-app>:<tag>\",workloadRole:$workloadRole,trainingServingPattern:$trainingServingPattern,inferenceServerRuntime:$inferenceServerRuntime,artifactContractFile:$artifactContractFile,artifactContractRequired:($trainingServingPattern==\"optimized\"),modelArtifactPolicy:$modelArtifactPolicy,modelArtifactReference:$modelArtifactReference,modelFilesEmbedded:false,modelInjectionRequired:($modelArtifactPolicy==\"external\"),imageBuilderMode:$imageBuilderMode,imageBuilderCategory:$imageBuilderCategory,imageBuilderSpecFile:$imageBuilderSpecFile,builderSpecDriven:true,manualDockerfilePerProject:false,dockerfileStrategy:\"multi-stage-target\",buildTargets:{dependency:\"dependency-image\",test:\"test\",release:\"release\"},releaseTarget:\"release\",pushOnlyReleaseTarget:true,releaseRequiresTestStage:true,securityReproducibilityPolicy:{required:true,runtimeDigestPinned:true,dependencyDigestPinned:true,lockHashRequired:true,noLatestTags:true,nonRootUserRequired:true,modelExternalByDefault:true,buildReportRequired:true,reproducibilityKey:\"runtimeDigest+lockHash+pythonAbi+targetPlatform+builderSpec\"},securityReproducibilityChecks:[\"runtime-image-digest-pinned\",\"dependency-image-digest-pinned\",\"lock-hash-recorded\",\"image-digest-recorded\",\"non-root-user\",\"model-external\",\"no-latest-tags\",\"build-report-generated\"],runtimeContractCriteria:[\"runtime-image-digest\",\"os-base-digest\",\"accelerator-abi\",\"language-runtime\",\"ml-framework\",\"ml-ops-common\",\"target-platform\",\"python-abi\",\"security-and-path-contract\"],recommendedImageLayers:[{\"level\":\"L0\",\"name\":\"source-base\",\"description\":\"Ubuntu, Debian, UBI, NVIDIA CUDA 등 외부 원천 이미지\",\"operation\":\"digest-pin-required\"},{\"level\":\"L1\",\"name\":\"os-foundation\",\"description\":\"OS 패키지, glibc, CA trust, timezone 등 운영 OS 기준\"},{\"level\":\"L2\",\"name\":\"accelerator-abi\",\"description\":\"CUDA/ROCm, cuDNN, NCCL, GPU driver 호환 ABI\"},{\"level\":\"L3\",\"name\":\"language-runtime\",\"description\":\"Python/uv/pip 및 Python ABI\"},{\"level\":\"L4\",\"name\":\"ml-framework\",\"description\":\"PyTorch, TensorFlow, vLLM, Triton 등 ML Framework\"},{\"level\":\"L5\",\"name\":\"ml-ops-common\",\"description\":\"logging, metrics, tracing, auth, cert, 공통 운영 유틸리티\"},{\"level\":\"L6\",\"name\":\"role-head\",\"description\":\"train/job/serve/infer 역할별 얇은 실행 Head\"},{\"level\":\"L7\",\"name\":\"project-app\",\"description\":\"프로젝트 코드와 애플리케이션 설정\"},{\"level\":\"L8\",\"name\":\"model-artifact\",\"description\":\"모델 파일은 이미지에 포함하지 않고 외부 Model Registry/PVC/Object Storage Reference로 관리\"}],lockFileName:$lockFileName,lockHash:$lockHash,wheelCount:$wheelCount,wheelTotalBytes:$wheelTotalBytes,wheelDownloadSeconds:$wheelDownloadSeconds,averageDownloadBytesPerSecond:$averageDownloadBytesPerSecond,testIncludedInReleaseBuild:true,dependencyCacheStatus:$dependencyCacheStatus,dependencyCacheKey:$dependencyCacheKey,dependencyImageReference:$dependencyImageReference,dependencyImageResult:$dependencyImageResult,dependencyBuildSeconds:$dependencyBuildSeconds,buildSeconds:$buildSeconds,packageRepository:\"nexus\",wheelOnly:true,status:\"SUCCEEDED\",timestamp:$timestamp}' \\\n  > /workspace/output/build-report.json\njq . /workspace/output/build-report.json\n",
          "volumeMounts": [
            {
              "name": "workspace",
              "mountPath": "/workspace"
            }
          ]
        }
      },
      {
        "name": "notify-build-result",
        "inputs": {
          "parameters": [
            {
              "name": "notification-server-url"
            },
            {
              "name": "report-json"
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/curl-jq:8.8@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\nprintf '%s\\n' '{{inputs.parameters.report-json}}' | jq .\nurl='{{inputs.parameters.notification-server-url}}'\nif [ -z \"$url\" ]; then\n  echo \"notification-server-url is empty; notification skipped\"\n  exit 0\nfi\nprintf '%s' '{{inputs.parameters.report-json}}' > /tmp/build-report.json\ncurl --silent --show-error --fail-with-body \\\n  --retry 3 --retry-all-errors \\\n  --header 'Content-Type: application/json' \\\n  --data-binary @/tmp/build-report.json \\\n  -- \"$url\"\n"
        }
      },
      {
        "name": "check-dependency-image",
        "inputs": {
          "parameters": [
            {
              "name": "cache-registry-address"
            },
            {
              "name": "lock-hash"
            },
            {
              "name": "runtime-image-digest"
            },
            {
              "name": "python-abi"
            },
            {
              "name": "target-platform"
            },
            {
              "name": "force-rebuild"
            }
          ]
        },
        "outputs": {
          "parameters": [
            {
              "name": "cache-status",
              "valueFrom": {
                "path": "/tmp/dependency-cache-status.txt"
              }
            },
            {
              "name": "dependency-cache-key",
              "valueFrom": {
                "path": "/tmp/dependency-cache-key.txt"
              }
            },
            {
              "name": "dependency-mutex-key",
              "valueFrom": {
                "path": "/tmp/dependency-mutex-key.txt"
              }
            },
            {
              "name": "dependency-image-tag",
              "valueFrom": {
                "path": "/tmp/dependency-image-tag.txt"
              }
            },
            {
              "name": "dependency-image-reference",
              "valueFrom": {
                "path": "/tmp/dependency-image-reference.txt"
              }
            },
            {
              "name": "dependency-image-digest",
              "valueFrom": {
                "path": "/tmp/dependency-image-digest.txt"
              }
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "env": [
            {
              "name": "DOCKER_CONFIG",
              "value": "/root/.docker"
            }
          ],
          "source": "set -euo pipefail\nlock_hash='{{inputs.parameters.lock-hash}}'\nruntime_digest='{{inputs.parameters.runtime-image-digest}}'\npython_abi='{{inputs.parameters.python-abi}}'\ntarget_platform='{{inputs.parameters.target-platform}}'\nforce_rebuild='{{inputs.parameters.force-rebuild}}'\n\nprintf '%s' \"$lock_hash\" | grep -Eq '^[0-9a-f]{64}$' || { echo 'invalid lock hash' >&2; exit 1; }\nprintf '%s' \"$runtime_digest\" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo 'invalid runtime digest' >&2; exit 1; }\nprintf '%s' \"$python_abi\" | grep -Eq '^[a-zA-Z0-9._-]+$' || { echo 'invalid python ABI' >&2; exit 1; }\nprintf '%s' \"$target_platform\" | grep -Eq '^[a-zA-Z0-9._-]+$' || { echo 'invalid target platform' >&2; exit 1; }\n[ \"$force_rebuild\" = false ] || [ \"$force_rebuild\" = true ] || { echo 'force-rebuild must be true or false' >&2; exit 1; }\n\nruntime_short=\"$(printf '%s' \"${runtime_digest#sha256:}\" | cut -c1-12)\"\ncache_key=\"${lock_hash}-${runtime_short}-${python_abi}-${target_platform}\"\nmutex_key=\"$(printf '%s' \"$cache_key\" | sha256sum | awk '{print substr($1,1,24)}')\"\nimage_tag='{{inputs.parameters.cache-registry-address}}/python-deps:'\"$cache_key\"\nstatus=MISS\ndigest=''\nimage_reference=\"$image_tag\"\n\nif [ \"$force_rebuild\" = false ]; then\n  if digest=\"$(crane digest \"$image_tag\" 2>/tmp/crane-error.txt)\"; then\n    printf '%s' \"$digest\" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo 'Harbor returned an invalid digest' >&2; exit 1; }\n    status=HIT\n    image_reference=\"${image_tag}@${digest}\"\n  elif grep -Eqi 'manifest unknown|name unknown|not found|404' /tmp/crane-error.txt; then\n    status=MISS\n  else\n    echo 'Harbor dependency cache lookup failed:' >&2\n    cat /tmp/crane-error.txt >&2\n    exit 1\n  fi\nfi\n\nprintf '%s' \"$status\" > /tmp/dependency-cache-status.txt\nprintf '%s' \"$cache_key\" > /tmp/dependency-cache-key.txt\nprintf '%s' \"$mutex_key\" > /tmp/dependency-mutex-key.txt\nprintf '%s' \"$image_tag\" > /tmp/dependency-image-tag.txt\nprintf '%s' \"$image_reference\" > /tmp/dependency-image-reference.txt\nprintf '%s' \"$digest\" > /tmp/dependency-image-digest.txt\nprintf 'dependency image cache: %s (%s)\\n' \"$status\" \"$image_reference\"\n",
          "volumeMounts": [
            {
              "name": "registry-auth",
              "mountPath": "/root/.docker",
              "readOnly": true
            }
          ]
        }
      },
      {
        "name": "build-dependency-image",
        "synchronization": {
          "mutex": {
            "name": "dependency-image-{{inputs.parameters.dependency-mutex-key}}"
          }
        },
        "inputs": {
          "parameters": [
            {
              "name": "cache-status"
            },
            {
              "name": "dependency-image-tag"
            },
            {
              "name": "dependency-image-reference"
            },
            {
              "name": "dependency-mutex-key"
            },
            {
              "name": "force-rebuild"
            },
            {
              "name": "buildkit-address"
            },
            {
              "name": "runtime-image"
            }
          ]
        },
        "outputs": {
          "parameters": [
            {
              "name": "dependency-image-reference",
              "valueFrom": {
                "path": "/workspace/generated/dependency-image-reference.txt"
              }
            },
            {
              "name": "dependency-image-digest",
              "valueFrom": {
                "path": "/workspace/generated/dependency-image-digest.txt"
              }
            },
            {
              "name": "dependency-image-result",
              "valueFrom": {
                "path": "/workspace/generated/dependency-image-result.txt"
              }
            },
            {
              "name": "dependency-build-seconds",
              "valueFrom": {
                "path": "/workspace/generated/dependency-build-seconds.txt"
              }
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "env": [
            {
              "name": "DOCKER_CONFIG",
              "value": "/root/.docker"
            }
          ],
          "source": "set -euo pipefail\nmkdir -p /workspace/generated\nimage_tag='{{inputs.parameters.dependency-image-tag}}'\ninput_reference='{{inputs.parameters.dependency-image-reference}}'\nforce_rebuild='{{inputs.parameters.force-rebuild}}'\ndigest=''\nresult=REUSED\nseconds=0\n\nif [ '{{inputs.parameters.cache-status}}' = HIT ] && [ \"$force_rebuild\" = false ]; then\n  digest=\"${input_reference##*@}\"\n  reference=\"$input_reference\"\nelse\n  # Mutex 대기 중 다른 Workflow가 이미 생성했을 수 있으므로 다시 확인한다.\n  if [ \"$force_rebuild\" = false ] && digest=\"$(crane digest \"$image_tag\" 2>/tmp/crane-error.txt)\"; then\n    result=REUSED_AFTER_WAIT\n    reference=\"${image_tag}@${digest}\"\n  else\n    if [ \"$force_rebuild\" = false ] && ! grep -Eqi 'manifest unknown|name unknown|not found|404' /tmp/crane-error.txt; then\n      echo 'Harbor dependency cache recheck failed:' >&2\n      cat /tmp/crane-error.txt >&2\n      exit 1\n    fi\n    start=\"$(date +%s)\"\n    buildctl --addr '{{inputs.parameters.buildkit-address}}' build \\\n      --progress=plain \\\n      --frontend dockerfile.v0 \\\n      --local context=/workspace/generated/context \\\n      --local dockerfile=/workspace/generated/context \\\n      --opt filename=Dockerfile \\\n      --opt target=dependency-image \\\n      --opt 'build-arg:RUNTIME_IMAGE={{inputs.parameters.runtime-image}}' \\\n      --opt \"build-arg:DEPENDENCY_IMAGE=${image_tag}\" \\\n      --output \"type=image,name=${image_tag},push=true\" \\\n      --metadata-file /workspace/generated/dependency-build-metadata.json\n    end=\"$(date +%s)\"\n    seconds=\"$((end - start))\"\n    digest=\"$(jq -r '.\"containerimage.digest\" // .\"containerimage.descriptor\".digest // empty' /workspace/generated/dependency-build-metadata.json)\"\n    result=BUILT\n    reference=\"${image_tag}@${digest}\"\n  fi\nfi\n\nprintf '%s' \"$digest\" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo 'invalid dependency image digest' >&2; exit 1; }\nprintf '%s' \"$reference\" > /workspace/generated/dependency-image-reference.txt\nprintf '%s' \"$digest\" > /workspace/generated/dependency-image-digest.txt\nprintf '%s' \"$result\" > /workspace/generated/dependency-image-result.txt\nprintf '%s' \"$seconds\" > /workspace/generated/dependency-build-seconds.txt\nprintf 'dependency image %s: %s\\n' \"$result\" \"$reference\"\n",
          "volumeMounts": [
            {
              "name": "workspace",
              "mountPath": "/workspace"
            },
            {
              "name": "registry-auth",
              "mountPath": "/root/.docker",
              "readOnly": true
            }
          ]
        }
      }
    ]
  }
}
```

## 3. Secret 예시 YAML (Harbor·Bitbucket)

```yaml
---
apiVersion: v1
kind: List
items:
- apiVersion: v1
  kind: Secret
  metadata:
    name: registry-auth
    namespace: argo
  type: Opaque
  stringData:
    config.json: '{"auths":{"harbor.CHANGE_ME.internal":{"username":"CHANGE_ME","password":"CHANGE_ME"}}}'
- apiVersion: v1
  kind: Secret
  metadata:
    name: bitbucket-ssh
    namespace: argo
  type: Opaque
  stringData:
    id_rsa: 'CHANGE_ME

'
    known_hosts: 'bitbucket.CHANGE_ME.internal ssh-ed25519 CHANGE_ME

'
```

## 4. Secret 예시 JSON (Harbor·Bitbucket)

```json
{
  "apiVersion": "v1",
  "kind": "List",
  "items": [
    {
      "apiVersion": "v1",
      "kind": "Secret",
      "metadata": {
        "name": "registry-auth",
        "namespace": "argo"
      },
      "type": "Opaque",
      "stringData": {
        "config.json": "{\"auths\":{\"harbor.CHANGE_ME.internal\":{\"username\":\"CHANGE_ME\",\"password\":\"CHANGE_ME\"}}}"
      }
    },
    {
      "apiVersion": "v1",
      "kind": "Secret",
      "metadata": {
        "name": "bitbucket-ssh",
        "namespace": "argo"
      },
      "type": "Opaque",
      "stringData": {
        "id_rsa": "CHANGE_ME\n",
        "known_hosts": "bitbucket.CHANGE_ME.internal ssh-ed25519 CHANGE_ME\n"
      }
    }
  ]
}
```

## 5. Nexus 동시성 제한 ConfigMap YAML

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nexus-concurrency-limit
  namespace: argo
data:
  wheel-downloads: "4" # CHANGE_ME
```

## 6. Nexus 동시성 제한 ConfigMap JSON

```json
{
  "apiVersion": "v1",
  "kind": "ConfigMap",
  "metadata": {
    "name": "nexus-concurrency-limit",
    "namespace": "argo"
  },
  "data": {
    "wheel-downloads": "4"
  }
}
```

## 7. 운영 및 검증 설명

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
