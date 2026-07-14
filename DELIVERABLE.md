# 폐쇄망 Python Build Argo WorkflowTemplate 전체 산출물

Nexus PyPI는 인증 없이 익명으로 Wheel을 다운로드한다. Harbor Push와 Bitbucket Clone에만 Secret을 사용한다.

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
      - name: report-nexus-connectivity
        template: report-nexus-connectivity
        arguments:
          parameters:
          - name: nexus-pypi-url
            value: "{{workflow.parameters.nexus-pypi-url}}"
          - name: phase
            value: before-download
      - name: validate-lock
        depends: clone-source.Succeeded
        template: validate-lock
      - name: download-wheels
        depends: validate-lock.Succeeded && report-nexus-connectivity.Succeeded
        template: download-wheels
        arguments:
          parameters:
          - name: nexus-pypi-url
            value: "{{workflow.parameters.nexus-pypi-url}}"
          - name: lock-file-name
            value: "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
      - name: verify-wheelhouse
        depends: download-wheels.Succeeded
        template: verify-wheelhouse
        arguments:
          parameters:
          - name: lock-file-name
            value: "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
      - name: report-nexus-after-download
        depends: download-wheels.Succeeded
        template: report-nexus-connectivity
        arguments:
          parameters:
          - name: nexus-pypi-url
            value: "{{workflow.parameters.nexus-pypi-url}}"
          - name: phase
            value: after-download
      - name: prepare-build-context
        depends: validate-runtime-image.Succeeded && verify-wheelhouse.Succeeded
        template: prepare-build-context
        arguments:
          parameters:
          - name: repository-name
            value: "{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}"
          - name: runtime-image
            value: "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
          - name: parent-image-digest
            value: "{{tasks.validate-runtime-image.outputs.parameters.parent-image-digest}}"
          - name: lock-file-name
            value: "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
          - name: lock-hash
            value: "{{tasks.validate-lock.outputs.parameters.lock-hash}}"
          - name: image-reference
            value: "{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:{{workflow.parameters.image-tag}}"
          - name: cache-reference
            value: "{{workflow.parameters.cache-registry-address}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:buildcache"
      - name: build-release-image
        depends: prepare-build-context.Succeeded
        template: build-release-image
        arguments:
          parameters:
          - name: buildkit-address
            value: "{{workflow.parameters.buildkit-address}}"
          - name: runtime-image
            value: "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
          - name: image-reference
            value: "{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:{{workflow.parameters.image-tag}}"
          - name: cache-reference
            value: "{{workflow.parameters.cache-registry-address}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:buildcache"
      - name: parse-image-digest
        depends: build-release-image.Succeeded
        template: parse-image-digest
        arguments:
          parameters:
          - name: image-digest
            value: "{{tasks.build-release-image.outputs.parameters.image-digest}}"
      - name: generate-build-report
        depends: parse-image-digest.Succeeded && report-nexus-after-download.Succeeded
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
          - name: nexus-before-download-total-seconds
            value: "{{tasks.report-nexus-connectivity.outputs.parameters.total-seconds}}"
          - name: nexus-after-download-total-seconds
            value: "{{tasks.report-nexus-after-download.outputs.parameters.total-seconds}}"
          - name: build-seconds
            value: "{{tasks.build-release-image.outputs.parameters.build-seconds}}"
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
        rm -rf /workspace/source
        mkdir -p /workspace/source
        chmod 700 /root/.ssh
        export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts"
        git clone --depth 1 -- "{{inputs.parameters.git-address}}" /workspace/source
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
  - name: report-nexus-connectivity
    inputs:
      parameters:
      - name: nexus-pypi-url
      - name: phase
    outputs:
      parameters:
      - name: report-json
        valueFrom:
          path: "/tmp/nexus-performance.json"
      - name: total-seconds
        valueFrom:
          path: "/tmp/total-seconds.txt"
      - name: http-code
        valueFrom:
          path: "/tmp/http-code.txt"
      artifacts:
      - name: nexus-performance-report
        path: "/tmp/nexus-performance.json"
        archive:
          none: {}
    script:
      image: harbor.CHANGE_ME.internal/platform/curl-jq:8.8@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        format='{"dnsSeconds":%{time_namelookup},"tcpConnectSeconds":%{time_connect},"tlsConnectSeconds":%{time_appconnect},"firstByteSeconds":%{time_starttransfer},"totalSeconds":%{time_total},"downloadBytes":%{size_download},"downloadSpeedBytesPerSecond":%{speed_download},"httpCode":%{http_code},"remoteIp":"%{remote_ip}","remotePort":%{remote_port},"redirectCount":%{num_redirects}}'
        metrics="$(curl --silent --show-error --location --fail-with-body --output /dev/null --write-out "$format" -- "{{inputs.parameters.nexus-pypi-url}}")"
        jq -n \
          --argjson metrics "$metrics" \
          --arg phase "{{inputs.parameters.phase}}" \
          --arg authentication "ANONYMOUS" \
          --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg workflowName "{{workflow.name}}" \
          --arg workflowUid "{{workflow.uid}}" \
          --arg namespace "{{workflow.namespace}}" \
          '$metrics + {phase:$phase,authentication:$authentication,timestamp:$timestamp,workflowName:$workflowName,workflowUid:$workflowUid,namespace:$namespace}' \
          > /tmp/nexus-performance.json
        jq -r '.totalSeconds' /tmp/nexus-performance.json > /tmp/total-seconds.txt
        jq -r '.httpCode' /tmp/nexus-performance.json > /tmp/http-code.txt
        jq '{phase,authentication,totalSeconds,httpCode}' /tmp/nexus-performance.json
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
        if [ -f /workspace/source/requirements.lock ]; then
          lock_file=requirements.lock
        elif [ -f /workspace/source/requirements.txt ]; then
          lock_file=requirements.txt
          echo "WARNING: requirements.txt fallback is allowed for migration only; use requirements.lock in production" >&2
        else
          echo "neither requirements.lock nor requirements.txt exists" >&2
          exit 1
        fi
        python /opt/build-tools/scripts/validate_lock.py "/workspace/source/$lock_file"
        printf '%s' "$lock_file" > /workspace/generated/lock-file-name.txt
        sha256sum "/workspace/source/$lock_file" | awk '{print $1}' > /workspace/generated/lock-hash.txt
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
        rm -rf /workspace/wheelhouse
        mkdir -p /workspace/wheelhouse /workspace/generated
        start="$(date +%s)"
        python -m pip download \
          --index-url "{{inputs.parameters.nexus-pypi-url}}" \
          --only-binary=:all: \
          --prefer-binary \
          --disable-pip-version-check \
          --timeout 30 \
          --retries 3 \
          --requirement "/workspace/source/{{inputs.parameters.lock-file-name}}" \
          --dest /workspace/wheelhouse
        end="$(date +%s)"
        seconds="$((end - start))"
        count="$(find /workspace/wheelhouse -type f -name '*.whl' | wc -l | tr -d ' ')"
        [ "$count" -gt 0 ] || { echo "wheelhouse is empty" >&2; exit 1; }
        bytes="$(find /workspace/wheelhouse -type f -name '*.whl' -exec stat -c '%s' {} + | awk '{sum += $1} END {print sum + 0}')"
        average="$((bytes / (seconds > 0 ? seconds : 1)))"
        printf '%s' "$count" > /workspace/generated/wheel-count.txt
        printf '%s' "$bytes" > /workspace/generated/wheel-total-bytes.txt
        printf '%s' "$seconds" > /workspace/generated/download-seconds.txt
        printf '%s' "$average" > /workspace/generated/average-download-bytes-per-second.txt
        printf 'downloaded %s wheels anonymously from Nexus (%s bytes) in %s seconds\n' "$count" "$bytes" "$seconds"
      volumeMounts:
      - name: workspace
        mountPath: "/workspace"
  - name: verify-wheelhouse
    inputs:
      parameters:
      - name: lock-file-name
    script:
      image: harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        rm -rf /tmp/python-verify
        python -m pip install \
          --no-index \
          --find-links=/workspace/wheelhouse \
          --only-binary=:all: \
          --disable-pip-version-check \
          --target=/tmp/python-verify \
          --requirement "/workspace/source/{{inputs.parameters.lock-file-name}}"
      volumeMounts:
      - name: workspace
        mountPath: "/workspace"
  - name: prepare-build-context
    inputs:
      parameters:
      - name: repository-name
      - name: runtime-image
      - name: parent-image-digest
      - name: lock-file-name
      - name: lock-hash
      - name: image-reference
      - name: cache-reference
    script:
      image: harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
      command:
      - sh
      source: |
        set -euo pipefail
        rm -rf /workspace/generated/context
        mkdir -p /workspace/generated/context/app /workspace/generated/context/wheelhouse
        cp -a /workspace/source/. /workspace/generated/context/app/
        rm -rf /workspace/generated/context/app/.git
        cp -a /workspace/wheelhouse/. /workspace/generated/context/wheelhouse/
        cp "/workspace/source/{{inputs.parameters.lock-file-name}}" /workspace/generated/context/requirements.lock

        # Docker 레이어 구조를 WorkflowTemplate JSON의 script.source에서 직접 생성합니다.
        cat > /workspace/generated/context/Dockerfile <<'DOCKERFILE'
        # syntax=docker/dockerfile:1.7
        ARG RUNTIME_IMAGE

        # Layer 1: 변경 빈도가 낮은 공통 Runtime Base
        FROM ${RUNTIME_IMAGE} AS base
        ENV PYTHONDONTWRITEBYTECODE=1 \
            PYTHONUNBUFFERED=1 \
            PIP_DISABLE_PIP_VERSION_CHECK=1
        WORKDIR /app

        # Layer 2: Lock/Wheelhouse를 소스보다 먼저 복사해 의존성 캐시 유지
        FROM base AS dependencies
        COPY requirements.lock /build/requirements.lock
        COPY wheelhouse /build/wheelhouse
        RUN python -m pip install \
              --no-index \
              --find-links=/build/wheelhouse \
              --only-binary=:all: \
              --prefix=/opt/python-dependencies \
              -r /build/requirements.lock \
            && rm -rf /root/.cache/pip /build/wheelhouse

        # Layer 3: 테스트 전용 계층이며 최종 Release 이미지에는 포함하지 않음
        FROM base AS test
        COPY --from=dependencies /opt/python-dependencies/ /usr/local/
        COPY app /app
        RUN python -m compileall -q /app \
            && if [ -d /app/tests ]; then python -m pytest -q /app/tests; fi \
            && touch /test-passed

        # Layer 4: 자주 변경되는 애플리케이션 소스를 의존성 다음에 배치
        FROM base AS source-clean
        COPY app /clean-app
        RUN rm -rf /clean-app/tests /clean-app/test /clean-app/.git \
            /clean-app/.pytest_cache /clean-app/.mypy_cache /clean-app/.ruff_cache

        # Layer 5: 실행 의존성과 정리된 소스만 포함한 최종 이미지
        FROM base AS release
        # Test Stage 성공 표식을 복사하여 Release 빌드가 Test 실행을 강제로 의존
        COPY --from=test /test-passed /tmp/test-passed
        COPY --from=dependencies /opt/python-dependencies/ /usr/local/
        COPY --from=source-clean /clean-app /app
        RUN rm -f /tmp/test-passed
        USER 10001:10001
        CMD ["python", "-m", "app"]
        DOCKERFILE

        printf '%s' 'base,dependencies,test,source-clean,release' > /workspace/generated/docker-layer-stages.txt
        cat > /workspace/generated/build-spec.json <<'JSON'
        {
          "repositoryName": "{{inputs.parameters.repository-name}}",
          "runtimeImage": "{{inputs.parameters.runtime-image}}",
          "parentImageDigest": "{{inputs.parameters.parent-image-digest}}",
          "lockFileName": "{{inputs.parameters.lock-file-name}}",
          "lockHash": "{{inputs.parameters.lock-hash}}",
          "imageReference": "{{inputs.parameters.image-reference}}",
          "cacheReference": "{{inputs.parameters.cache-reference}}",
          "dockerLayerStages": ["base", "dependencies", "test", "source-clean", "release"]
        }
        JSON
        test -s /workspace/generated/context/Dockerfile
        test -s /workspace/generated/build-spec.json
        printf 'Docker layers: base -> dependencies -> test -> source-clean -> release\n'
      volumeMounts:
      - name: workspace
        mountPath: "/workspace"
  - name: build-release-image
    inputs:
      parameters:
      - name: buildkit-address
      - name: runtime-image
      - name: image-reference
      - name: cache-reference
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
      - name: lock-file-name
      - name: lock-hash
      - name: wheel-count
      - name: wheel-total-bytes
      - name: wheel-download-seconds
      - name: average-download-bytes-per-second
      - name: nexus-before-download-total-seconds
      - name: nexus-after-download-total-seconds
      - name: build-seconds
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
          --arg lockFileName "{{inputs.parameters.lock-file-name}}" \
          --arg lockHash "{{inputs.parameters.lock-hash}}" \
          --argjson wheelCount "{{inputs.parameters.wheel-count}}" \
          --argjson wheelTotalBytes "{{inputs.parameters.wheel-total-bytes}}" \
          --argjson wheelDownloadSeconds "{{inputs.parameters.wheel-download-seconds}}" \
          --argjson averageDownloadBytesPerSecond "{{inputs.parameters.average-download-bytes-per-second}}" \
          --argjson nexusBeforeDownloadTotalSeconds "{{inputs.parameters.nexus-before-download-total-seconds}}" \
          --argjson nexusAfterDownloadTotalSeconds "{{inputs.parameters.nexus-after-download-total-seconds}}" \
          --argjson buildSeconds "{{inputs.parameters.build-seconds}}" \
          --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{workflowName:$workflowName,workflowUid:$workflowUid,namespace:$namespace,repositoryName:$repositoryName,imageReference:$imageReference,imageDigest:$imageDigest,parentImageDigest:$parentImageDigest,runtimeImage:$runtimeImage,lockFileName:$lockFileName,lockHash:$lockHash,wheelCount:$wheelCount,wheelTotalBytes:$wheelTotalBytes,wheelDownloadSeconds:$wheelDownloadSeconds,averageDownloadBytesPerSecond:$averageDownloadBytesPerSecond,nexusBeforeDownloadTotalSeconds:$nexusBeforeDownloadTotalSeconds,nexusAfterDownloadTotalSeconds:$nexusAfterDownloadTotalSeconds,testIncludedInReleaseBuild:true,buildSeconds:$buildSeconds,packageRepository:"nexus",wheelOnly:true,status:"SUCCEEDED",timestamp:$timestamp}' \
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
              "name": "report-nexus-connectivity",
              "template": "report-nexus-connectivity",
              "arguments": {
                "parameters": [
                  {
                    "name": "nexus-pypi-url",
                    "value": "{{workflow.parameters.nexus-pypi-url}}"
                  },
                  {
                    "name": "phase",
                    "value": "before-download"
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
              "name": "download-wheels",
              "depends": "validate-lock.Succeeded && report-nexus-connectivity.Succeeded",
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
                  }
                ]
              }
            },
            {
              "name": "verify-wheelhouse",
              "depends": "download-wheels.Succeeded",
              "template": "verify-wheelhouse",
              "arguments": {
                "parameters": [
                  {
                    "name": "lock-file-name",
                    "value": "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
                  }
                ]
              }
            },
            {
              "name": "report-nexus-after-download",
              "depends": "download-wheels.Succeeded",
              "template": "report-nexus-connectivity",
              "arguments": {
                "parameters": [
                  {
                    "name": "nexus-pypi-url",
                    "value": "{{workflow.parameters.nexus-pypi-url}}"
                  },
                  {
                    "name": "phase",
                    "value": "after-download"
                  }
                ]
              }
            },
            {
              "name": "prepare-build-context",
              "depends": "validate-runtime-image.Succeeded && verify-wheelhouse.Succeeded",
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
                    "value": "{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:{{workflow.parameters.image-tag}}"
                  },
                  {
                    "name": "cache-reference",
                    "value": "{{workflow.parameters.cache-registry-address}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:buildcache"
                  }
                ]
              }
            },
            {
              "name": "build-release-image",
              "depends": "prepare-build-context.Succeeded",
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
                    "name": "image-reference",
                    "value": "{{workflow.parameters.registry-address}}/{{workflow.parameters.registry-project}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:{{workflow.parameters.image-tag}}"
                  },
                  {
                    "name": "cache-reference",
                    "value": "{{workflow.parameters.cache-registry-address}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:buildcache"
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
              "depends": "parse-image-digest.Succeeded && report-nexus-after-download.Succeeded",
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
                    "name": "nexus-before-download-total-seconds",
                    "value": "{{tasks.report-nexus-connectivity.outputs.parameters.total-seconds}}"
                  },
                  {
                    "name": "nexus-after-download-total-seconds",
                    "value": "{{tasks.report-nexus-after-download.outputs.parameters.total-seconds}}"
                  },
                  {
                    "name": "build-seconds",
                    "value": "{{tasks.build-release-image.outputs.parameters.build-seconds}}"
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
          "source": "set -euo pipefail\nrm -rf /workspace/source\nmkdir -p /workspace/source\nchmod 700 /root/.ssh\nexport GIT_SSH_COMMAND=\"ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts\"\ngit clone --depth 1 -- \"{{inputs.parameters.git-address}}\" /workspace/source\n",
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
        "name": "report-nexus-connectivity",
        "inputs": {
          "parameters": [
            {
              "name": "nexus-pypi-url"
            },
            {
              "name": "phase"
            }
          ]
        },
        "outputs": {
          "parameters": [
            {
              "name": "report-json",
              "valueFrom": {
                "path": "/tmp/nexus-performance.json"
              }
            },
            {
              "name": "total-seconds",
              "valueFrom": {
                "path": "/tmp/total-seconds.txt"
              }
            },
            {
              "name": "http-code",
              "valueFrom": {
                "path": "/tmp/http-code.txt"
              }
            }
          ],
          "artifacts": [
            {
              "name": "nexus-performance-report",
              "path": "/tmp/nexus-performance.json",
              "archive": {
                "none": {
                }
              }
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/curl-jq:8.8@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\nformat='{\"dnsSeconds\":%{time_namelookup},\"tcpConnectSeconds\":%{time_connect},\"tlsConnectSeconds\":%{time_appconnect},\"firstByteSeconds\":%{time_starttransfer},\"totalSeconds\":%{time_total},\"downloadBytes\":%{size_download},\"downloadSpeedBytesPerSecond\":%{speed_download},\"httpCode\":%{http_code},\"remoteIp\":\"%{remote_ip}\",\"remotePort\":%{remote_port},\"redirectCount\":%{num_redirects}}'\nmetrics=\"$(curl --silent --show-error --location --fail-with-body --output /dev/null --write-out \"$format\" -- \"{{inputs.parameters.nexus-pypi-url}}\")\"\njq -n \\\n  --argjson metrics \"$metrics\" \\\n  --arg phase \"{{inputs.parameters.phase}}\" \\\n  --arg authentication \"ANONYMOUS\" \\\n  --arg timestamp \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \\\n  --arg workflowName \"{{workflow.name}}\" \\\n  --arg workflowUid \"{{workflow.uid}}\" \\\n  --arg namespace \"{{workflow.namespace}}\" \\\n  '$metrics + {phase:$phase,authentication:$authentication,timestamp:$timestamp,workflowName:$workflowName,workflowUid:$workflowUid,namespace:$namespace}' \\\n  > /tmp/nexus-performance.json\njq -r '.totalSeconds' /tmp/nexus-performance.json > /tmp/total-seconds.txt\njq -r '.httpCode' /tmp/nexus-performance.json > /tmp/http-code.txt\njq '{phase,authentication,totalSeconds,httpCode}' /tmp/nexus-performance.json\n"
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
          "source": "set -euo pipefail\nmkdir -p /workspace/generated\nif [ -f /workspace/source/requirements.lock ]; then\n  lock_file=requirements.lock\nelif [ -f /workspace/source/requirements.txt ]; then\n  lock_file=requirements.txt\n  echo \"WARNING: requirements.txt fallback is allowed for migration only; use requirements.lock in production\" >&2\nelse\n  echo \"neither requirements.lock nor requirements.txt exists\" >&2\n  exit 1\nfi\npython /opt/build-tools/scripts/validate_lock.py \"/workspace/source/$lock_file\"\nprintf '%s' \"$lock_file\" > /workspace/generated/lock-file-name.txt\nsha256sum \"/workspace/source/$lock_file\" | awk '{print $1}' > /workspace/generated/lock-hash.txt\n",
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
          "source": "set -euo pipefail\nrm -rf /workspace/wheelhouse\nmkdir -p /workspace/wheelhouse /workspace/generated\nstart=\"$(date +%s)\"\npython -m pip download \\\n  --index-url \"{{inputs.parameters.nexus-pypi-url}}\" \\\n  --only-binary=:all: \\\n  --prefer-binary \\\n  --disable-pip-version-check \\\n  --timeout 30 \\\n  --retries 3 \\\n  --requirement \"/workspace/source/{{inputs.parameters.lock-file-name}}\" \\\n  --dest /workspace/wheelhouse\nend=\"$(date +%s)\"\nseconds=\"$((end - start))\"\ncount=\"$(find /workspace/wheelhouse -type f -name '*.whl' | wc -l | tr -d ' ')\"\n[ \"$count\" -gt 0 ] || { echo \"wheelhouse is empty\" >&2; exit 1; }\nbytes=\"$(find /workspace/wheelhouse -type f -name '*.whl' -exec stat -c '%s' {} + | awk '{sum += $1} END {print sum + 0}')\"\naverage=\"$((bytes / (seconds > 0 ? seconds : 1)))\"\nprintf '%s' \"$count\" > /workspace/generated/wheel-count.txt\nprintf '%s' \"$bytes\" > /workspace/generated/wheel-total-bytes.txt\nprintf '%s' \"$seconds\" > /workspace/generated/download-seconds.txt\nprintf '%s' \"$average\" > /workspace/generated/average-download-bytes-per-second.txt\nprintf 'downloaded %s wheels anonymously from Nexus (%s bytes) in %s seconds\\n' \"$count\" \"$bytes\" \"$seconds\"\n",
          "volumeMounts": [
            {
              "name": "workspace",
              "mountPath": "/workspace"
            }
          ]
        }
      },
      {
        "name": "verify-wheelhouse",
        "inputs": {
          "parameters": [
            {
              "name": "lock-file-name"
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\nrm -rf /tmp/python-verify\npython -m pip install \\\n  --no-index \\\n  --find-links=/workspace/wheelhouse \\\n  --only-binary=:all: \\\n  --disable-pip-version-check \\\n  --target=/tmp/python-verify \\\n  --requirement \"/workspace/source/{{inputs.parameters.lock-file-name}}\"\n",
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
            }
          ]
        },
        "script": {
          "image": "harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "command": [
            "sh"
          ],
          "source": "set -euo pipefail\nrm -rf /workspace/generated/context\nmkdir -p /workspace/generated/context/app /workspace/generated/context/wheelhouse\ncp -a /workspace/source/. /workspace/generated/context/app/\nrm -rf /workspace/generated/context/app/.git\ncp -a /workspace/wheelhouse/. /workspace/generated/context/wheelhouse/\ncp \"/workspace/source/{{inputs.parameters.lock-file-name}}\" /workspace/generated/context/requirements.lock\n\n# Docker 레이어 구조를 WorkflowTemplate JSON의 script.source에서 직접 생성합니다.\ncat > /workspace/generated/context/Dockerfile <<'DOCKERFILE'\n# syntax=docker/dockerfile:1.7\nARG RUNTIME_IMAGE\n\n# Layer 1: 변경 빈도가 낮은 공통 Runtime Base\nFROM ${RUNTIME_IMAGE} AS base\nENV PYTHONDONTWRITEBYTECODE=1 \\\n    PYTHONUNBUFFERED=1 \\\n    PIP_DISABLE_PIP_VERSION_CHECK=1\nWORKDIR /app\n\n# Layer 2: Lock/Wheelhouse를 소스보다 먼저 복사해 의존성 캐시 유지\nFROM base AS dependencies\nCOPY requirements.lock /build/requirements.lock\nCOPY wheelhouse /build/wheelhouse\nRUN python -m pip install \\\n      --no-index \\\n      --find-links=/build/wheelhouse \\\n      --only-binary=:all: \\\n      --prefix=/opt/python-dependencies \\\n      -r /build/requirements.lock \\\n    && rm -rf /root/.cache/pip /build/wheelhouse\n\n# Layer 3: 테스트 전용 계층이며 최종 Release 이미지에는 포함하지 않음\nFROM base AS test\nCOPY --from=dependencies /opt/python-dependencies/ /usr/local/\nCOPY app /app\nRUN python -m compileall -q /app \\\n    && if [ -d /app/tests ]; then python -m pytest -q /app/tests; fi \\\n    && touch /test-passed\n\n# Layer 4: 자주 변경되는 애플리케이션 소스를 의존성 다음에 배치\nFROM base AS source-clean\nCOPY app /clean-app\nRUN rm -rf /clean-app/tests /clean-app/test /clean-app/.git \\\n    /clean-app/.pytest_cache /clean-app/.mypy_cache /clean-app/.ruff_cache\n\n# Layer 5: 실행 의존성과 정리된 소스만 포함한 최종 이미지\nFROM base AS release\n# Test Stage 성공 표식을 복사하여 Release 빌드가 Test 실행을 강제로 의존\nCOPY --from=test /test-passed /tmp/test-passed\nCOPY --from=dependencies /opt/python-dependencies/ /usr/local/\nCOPY --from=source-clean /clean-app /app\nRUN rm -f /tmp/test-passed\nUSER 10001:10001\nCMD [\"python\", \"-m\", \"app\"]\nDOCKERFILE\n\nprintf '%s' 'base,dependencies,test,source-clean,release' > /workspace/generated/docker-layer-stages.txt\ncat > /workspace/generated/build-spec.json <<'JSON'\n{\n  \"repositoryName\": \"{{inputs.parameters.repository-name}}\",\n  \"runtimeImage\": \"{{inputs.parameters.runtime-image}}\",\n  \"parentImageDigest\": \"{{inputs.parameters.parent-image-digest}}\",\n  \"lockFileName\": \"{{inputs.parameters.lock-file-name}}\",\n  \"lockHash\": \"{{inputs.parameters.lock-hash}}\",\n  \"imageReference\": \"{{inputs.parameters.image-reference}}\",\n  \"cacheReference\": \"{{inputs.parameters.cache-reference}}\",\n  \"dockerLayerStages\": [\"base\", \"dependencies\", \"test\", \"source-clean\", \"release\"]\n}\nJSON\ntest -s /workspace/generated/context/Dockerfile\ntest -s /workspace/generated/build-spec.json\nprintf 'Docker layers: base -> dependencies -> test -> source-clean -> release\\n'\n",
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
              "name": "image-reference"
            },
            {
              "name": "cache-reference"
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
          "source": "set -euo pipefail\nmkdir -p /workspace/generated\nstart=\"$(date +%s)\"\nprintf '[BuildKit] release build and Harbor push started at %s\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"\nbuildctl --addr \"{{inputs.parameters.buildkit-address}}\" build \\\n  --progress=plain \\\n  --frontend dockerfile.v0 \\\n  --local context=/workspace/generated/context \\\n  --local dockerfile=/workspace/generated/context \\\n  --opt filename=Dockerfile \\\n  --opt target=release \\\n  --opt \"build-arg:RUNTIME_IMAGE={{inputs.parameters.runtime-image}}\" \\\n  --import-cache \"type=registry,ref={{inputs.parameters.cache-reference}}\" \\\n  --export-cache \"type=registry,ref={{inputs.parameters.cache-reference}},mode=min\" \\\n  --output \"type=image,name={{inputs.parameters.image-reference}},push=true\" \\\n  --metadata-file /workspace/generated/build-metadata.json\nend=\"$(date +%s)\"\ndigest=\"$(jq -r '.\"containerimage.digest\" // .\"containerimage.descriptor\".digest // empty' /workspace/generated/build-metadata.json)\"\nprintf '%s' \"$digest\" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo \"BuildKit did not return a valid image digest\" >&2; exit 1; }\nprintf '%s' \"{{inputs.parameters.image-reference}}\" > /workspace/generated/image-reference.txt\nprintf '%s' \"$digest\" > /workspace/generated/image-digest.txt\nprintf '%s' \"$((end - start))\" > /workspace/generated/build-seconds.txt\nprintf '%s' '0' > /workspace/generated/push-seconds.txt\nprintf '[BuildKit] release build, cache export and Harbor push completed in %s seconds: %s@%s\\n' \\\n  \"$((end - start))\" \"{{inputs.parameters.image-reference}}\" \"$digest\"\n",
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
              "name": "nexus-before-download-total-seconds"
            },
            {
              "name": "nexus-after-download-total-seconds"
            },
            {
              "name": "build-seconds"
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
          "source": "set -euo pipefail\nmkdir -p /workspace/output\njq -n \\\n  --arg workflowName \"{{workflow.name}}\" \\\n  --arg workflowUid \"{{workflow.uid}}\" \\\n  --arg namespace \"{{workflow.namespace}}\" \\\n  --arg repositoryName \"{{inputs.parameters.repository-name}}\" \\\n  --arg imageReference \"{{inputs.parameters.image-reference}}\" \\\n  --arg imageDigest \"{{inputs.parameters.image-digest}}\" \\\n  --arg parentImageDigest \"{{inputs.parameters.parent-image-digest}}\" \\\n  --arg runtimeImage \"{{inputs.parameters.runtime-image}}\" \\\n  --arg lockFileName \"{{inputs.parameters.lock-file-name}}\" \\\n  --arg lockHash \"{{inputs.parameters.lock-hash}}\" \\\n  --argjson wheelCount \"{{inputs.parameters.wheel-count}}\" \\\n  --argjson wheelTotalBytes \"{{inputs.parameters.wheel-total-bytes}}\" \\\n  --argjson wheelDownloadSeconds \"{{inputs.parameters.wheel-download-seconds}}\" \\\n  --argjson averageDownloadBytesPerSecond \"{{inputs.parameters.average-download-bytes-per-second}}\" \\\n  --argjson nexusBeforeDownloadTotalSeconds \"{{inputs.parameters.nexus-before-download-total-seconds}}\" \\\n  --argjson nexusAfterDownloadTotalSeconds \"{{inputs.parameters.nexus-after-download-total-seconds}}\" \\\n  --argjson buildSeconds \"{{inputs.parameters.build-seconds}}\" \\\n  --arg timestamp \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \\\n  '{workflowName:$workflowName,workflowUid:$workflowUid,namespace:$namespace,repositoryName:$repositoryName,imageReference:$imageReference,imageDigest:$imageDigest,parentImageDigest:$parentImageDigest,runtimeImage:$runtimeImage,lockFileName:$lockFileName,lockHash:$lockHash,wheelCount:$wheelCount,wheelTotalBytes:$wheelTotalBytes,wheelDownloadSeconds:$wheelDownloadSeconds,averageDownloadBytesPerSecond:$averageDownloadBytesPerSecond,nexusBeforeDownloadTotalSeconds:$nexusBeforeDownloadTotalSeconds,nexusAfterDownloadTotalSeconds:$nexusAfterDownloadTotalSeconds,testIncludedInReleaseBuild:true,buildSeconds:$buildSeconds,packageRepository:\"nexus\",wheelOnly:true,status:\"SUCCEEDED\",timestamp:$timestamp}' \\\n  > /workspace/output/build-report.json\njq . /workspace/output/build-report.json\n",
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

## 9. BuildKit Registry Cache 설명

PVC와 Registry Cache의 수명과 목적을 분리했다.

- `workspace` PVC: 현재 Workflow의 `/workspace/source`, `/workspace/wheelhouse`, `/workspace/generated`, `/workspace/output`을 Pod 사이에서 공유한다. Workflow가 삭제되면 PVC도 Workflow 소유권에 따라 정리되는 전용 작업 공간이다.
- Harbor Registry Cache: 단일 Release Build에서 Registry Cache를 Import하고 `--export-cache type=registry,ref=...,mode=min`으로 최종 이미지에 필요한 레이어만 갱신한다. Release Stage가 Test Stage의 성공 표식을 의존하므로 별도의 Test BuildKit 호출 없이 테스트가 강제된다.
- Harbor Application Repository: `harbor.CHANGE_ME.internal/applications/<repository>:<tag>`에 `release` Target만 Push한다. 배포와 기록에는 BuildKit metadata에서 얻은 Digest를 함께 사용한다.

Cache Repository에는 애플리케이션 배포 보존 정책과 다른 정리 정책을 적용해야 한다. 여러 빌드가 같은 `:buildcache` Tag를 동시에 갱신할 수 있으므로, 충돌이 문제라면 브랜치/플랫폼별 Cache Tag를 추가한다.

## 10. 주요 Task 실행 흐름

```text
get-repository-name-from-git ─→ clone-source ─→ validate-lock
                                               │
validate-runtime-image                         │
                                               ├─→ download-wheels ─┬→ verify-wheelhouse ─┐
report-nexus-connectivity ──────────────────────┘                    └→ report-nexus-after-download
                                                                                              │
validate-runtime-image ───────────────────────────────────────────────────────────────────────┤
                                                                                              ↓
prepare-build-context → build-release-image(test 포함) → parse-image-digest
    → generate-build-report → notify-build-result
```

`get-repository-name-from-git`, `validate-runtime-image`, `report-nexus-connectivity`는 동시에 시작한다. `verify-wheelhouse`와 `report-nexus-after-download`도 Wheel 다운로드 직후 병렬로 실행한다. Nexus Wheel 다운로드 Task는 `nexus-concurrency-limit/wheel-downloads` 세마포어를 사용한다.

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
  "nexusBeforeDownloadTotalSeconds": 0.421,
  "nexusAfterDownloadTotalSeconds": 1.812,
  "buildSeconds": 74,
  "packageRepository": "nexus",
  "wheelOnly": true,
  "status": "SUCCEEDED",
  "timestamp": "2026-07-13T09:00:00Z"
}
```

## 12. 운영 환경에서 변경할 값 목록

| 위치 | 변경 값 |
|---|---|
| Workflow Parameter | Bitbucket URL, Runtime Image와 실제 SHA-256, Nexus URL, Harbor 주소/프로젝트, 이미지 Tag, Cache 주소, BuildKit 주소, 알림 URL |
| Workflow Script Image | `python-tools`, `git-tools`, `curl-jq`, `python-build-tools`, `buildkit-client-tools`의 내부 Harbor 주소와 실제 SHA-256 |
| PVC | `CHANGE_ME-rwx-storage`, 용량, 필요 시 Access Mode |
| `registry-auth` | 실제 Harbor Host 및 자격 증명 |
| `bitbucket-ssh` | Private Key와 검증된 `known_hosts` Host Key |
| Nexus 다운로드 인증 | 익명 다운로드 사용, 별도 Secret 불필요 |
| ConfigMap | Nexus가 허용하는 동시 Wheel 다운로드 수 |
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
- `buildSeconds`는 Test Stage·Release Stage·Cache Export·Harbor Push를 포함한 단일 BuildKit 호출의 전체 시간이며 `push-seconds`는 호환성을 위해 `0`이다. 정확한 Push 시간 분리가 필요하면 Registry 이벤트/Telemetry를 결합해야 한다.
- 원격 BuildKit이 TLS/mTLS를 요구하면 BuildKit 인증용 Secret Volume과 `buildctl --tlscacert/--tlscert/--tlskey`를 추가해야 한다. 현재 요구사항에 그 Secret이 정의되지 않아 주소 및 사내 CA 신뢰가 Client Image에 준비됐다는 전제다.
- `ReadWriteMany` StorageClass가 클러스터에 실제로 있어야 한다. NFS 계열 Storage에서는 소유권/성능/파일 잠금 정책도 확인한다.
- Secret 예시는 배포 구조를 보여주기 위한 자리표시자다. 실제 값은 Git에 저장하지 말고 External Secrets/Sealed Secrets/Vault 같은 운영 Secret 관리 경로로 주입한다.
- Bitbucket `known_hosts`는 `ssh-keyscan` 결과를 무검증으로 사용하지 말고 관리자가 별도 채널로 확인한 Host Key를 고정한다.
- NetworkPolicy로 Bitbucket, Nexus, Harbor, BuildKit, 알림 서버와 DNS 이외의 Egress를 차단해야 “외부 PyPI 접근 금지”를 인프라 계층에서도 강제할 수 있다.
- `requirements.lock`은 플랫폼/CPU/Python ABI에 맞는 Wheel만 포함해야 한다. `requirements.txt` fallback은 마이그레이션 경고를 내지만 운영에서는 정책 Admission으로 금지하는 편이 안전하다.
- Test Target은 `tests/`가 존재하면 `pytest`를 실행한다. `pytest`가 Lock에 포함되지 않는 조직은 전용 Test Lock 또는 테스트 실행 명령을 Build Tools Template에 반영해야 한다.
- 현재 로컬 환경에는 연결된 Kubernetes API와 Argo CRD Schema가 없어 서버 측 Dry Run은 수행하지 못했다. 실제 배포 전 대상 클러스터에서 `kubectl apply --server-side --dry-run=server`와 Argo 버전 호환성 검증이 필요하다.
