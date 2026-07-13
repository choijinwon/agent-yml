# 폐쇄망 Python Build Argo WorkflowTemplate 전체 산출물

## 1. 전체 Argo WorkflowTemplate YAML

```yaml
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
        value: git@bitbucket.CHANGE_ME.internal:project/sample-api.git # CHANGE_ME
      - name: runtime-image
        value: harbor.CHANGE_ME.internal/runtime/python311@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
      - name: zeus-pypi-url
        value: https://zeus.CHANGE_ME.internal/simple # CHANGE_ME
      - name: registry-address
        value: harbor.CHANGE_ME.internal # CHANGE_ME
      - name: registry-project
        value: applications # CHANGE_ME
      - name: image-tag
        value: 1.0.0 # CHANGE_ME
      - name: cache-registry-address
        value: harbor.CHANGE_ME.internal/build-cache # CHANGE_ME
      - name: buildkit-address
        value: tcp://buildkitd.CHANGE_ME.internal:1234 # CHANGE_ME
      - name: notification-server-url
        value: "" # CHANGE_ME; empty disables notification
  volumeClaimTemplates:
    - metadata:
        name: workspace
      spec:
        accessModes:
          - ReadWriteMany
        storageClassName: CHANGE_ME-rwx-storage # CHANGE_ME
        resources:
          requests:
            storage: 20Gi # CHANGE_ME
  volumes:
    - name: registry-auth
      secret:
        secretName: registry-auth
    - name: bitbucket-ssh
      secret:
        secretName: bitbucket-ssh
        defaultMode: 256
    - name: zeus-pypi-auth
      secret:
        secretName: zeus-pypi-auth
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
          - name: report-zeus-connectivity
            template: report-zeus-connectivity
            arguments:
              parameters:
                - name: zeus-pypi-url
                  value: "{{workflow.parameters.zeus-pypi-url}}"
                - name: phase
                  value: before-download
          - name: validate-lock
            depends: clone-source.Succeeded
            template: validate-lock
          - name: download-wheels
            depends: validate-lock.Succeeded && report-zeus-connectivity.Succeeded
            template: download-wheels
            arguments:
              parameters:
                - name: zeus-pypi-url
                  value: "{{workflow.parameters.zeus-pypi-url}}"
                - name: lock-file-name
                  value: "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
          - name: verify-wheelhouse
            depends: download-wheels.Succeeded
            template: verify-wheelhouse
            arguments:
              parameters:
                - name: lock-file-name
                  value: "{{tasks.validate-lock.outputs.parameters.lock-file-name}}"
          - name: report-zeus-after-download
            depends: download-wheels.Succeeded
            template: report-zeus-connectivity
            arguments:
              parameters:
                - name: zeus-pypi-url
                  value: "{{workflow.parameters.zeus-pypi-url}}"
                - name: phase
                  value: after-download
          - name: prepare-build-context
            depends: validate-runtime-image.Succeeded && verify-wheelhouse.Succeeded && report-zeus-after-download.Succeeded
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
          - name: build-test-target
            depends: prepare-build-context.Succeeded
            template: build-test-target
            arguments:
              parameters:
                - name: buildkit-address
                  value: "{{workflow.parameters.buildkit-address}}"
                - name: runtime-image
                  value: "{{tasks.validate-runtime-image.outputs.parameters.runtime-image}}"
                - name: cache-reference
                  value: "{{workflow.parameters.cache-registry-address}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:buildcache"
          - name: build-release-image
            depends: build-test-target.Succeeded
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
                - name: zeus-before-download-total-seconds
                  value: "{{tasks.report-zeus-connectivity.outputs.parameters.total-seconds}}"
                - name: zeus-after-download-total-seconds
                  value: "{{tasks.report-zeus-after-download.outputs.parameters.total-seconds}}"
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
              path: /tmp/repository-name.txt
      script:
        image: harbor.CHANGE_ME.internal/platform/python-tools:3.11@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
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
        image: harbor.CHANGE_ME.internal/platform/git-tools:2.45@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
        source: |
          set -euo pipefail
          rm -rf /workspace/source
          mkdir -p /workspace/source
          chmod 700 /root/.ssh
          export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts"
          git clone --depth 1 -- "{{inputs.parameters.git-address}}" /workspace/source
        volumeMounts:
          - name: workspace
            mountPath: /workspace
          - name: bitbucket-ssh
            mountPath: /root/.ssh
            readOnly: true

    - name: validate-runtime-image
      inputs:
        parameters:
          - name: runtime-image
      outputs:
        parameters:
          - name: runtime-image
            valueFrom:
              path: /tmp/runtime-image.txt
          - name: parent-image-digest
            valueFrom:
              path: /tmp/parent-image-digest.txt
      script:
        image: harbor.CHANGE_ME.internal/platform/python-tools:3.11@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
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

    - name: report-zeus-connectivity
      inputs:
        parameters:
          - name: zeus-pypi-url
          - name: phase
      outputs:
        parameters:
          - name: report-json
            valueFrom:
              path: /tmp/zeus-performance.json
          - name: total-seconds
            valueFrom:
              path: /tmp/total-seconds.txt
          - name: http-code
            valueFrom:
              path: /tmp/http-code.txt
        artifacts:
          - name: zeus-performance-report
            path: /tmp/zeus-performance.json
            archive:
              none: {}
      script:
        image: harbor.CHANGE_ME.internal/platform/curl-jq:8.8@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
        env:
          - name: ZEUS_USERNAME
            valueFrom:
              secretKeyRef:
                name: zeus-pypi-auth
                key: username
          - name: ZEUS_PASSWORD
            valueFrom:
              secretKeyRef:
                name: zeus-pypi-auth
                key: password
        source: |
          set -euo pipefail
          umask 077
          python - <<'PY'
          import os
          from urllib.parse import urlsplit

          host = urlsplit(r'''{{inputs.parameters.zeus-pypi-url}}''').hostname
          if not host:
              raise SystemExit("zeus-pypi-url has no hostname")
          with open("/tmp/zeus.netrc", "w", encoding="utf-8") as netrc:
              netrc.write(f"machine {host}\nlogin {os.environ['ZEUS_USERNAME']}\npassword {os.environ['ZEUS_PASSWORD']}\n")
          PY
          chmod 600 /tmp/zeus.netrc
          format='{"dnsSeconds":%{time_namelookup},"tcpConnectSeconds":%{time_connect},"tlsConnectSeconds":%{time_appconnect},"firstByteSeconds":%{time_starttransfer},"totalSeconds":%{time_total},"downloadBytes":%{size_download},"downloadSpeedBytesPerSecond":%{speed_download},"httpCode":%{http_code},"remoteIp":"%{remote_ip}","remotePort":%{remote_port},"redirectCount":%{num_redirects}}'
          metrics="$(curl --silent --show-error --location --fail-with-body --output /dev/null --netrc-file /tmp/zeus.netrc --write-out "$format" -- "{{inputs.parameters.zeus-pypi-url}}")"
          rm -f /tmp/zeus.netrc
          jq -n \
            --argjson metrics "$metrics" \
            --arg phase "{{inputs.parameters.phase}}" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg workflowName "{{workflow.name}}" \
            --arg workflowUid "{{workflow.uid}}" \
            --arg namespace "{{workflow.namespace}}" \
            '$metrics + {phase:$phase,timestamp:$timestamp,workflowName:$workflowName,workflowUid:$workflowUid,namespace:$namespace}' \
            > /tmp/zeus-performance.json
          jq -r '.totalSeconds' /tmp/zeus-performance.json > /tmp/total-seconds.txt
          jq -r '.httpCode' /tmp/zeus-performance.json > /tmp/http-code.txt
          jq '{phase,totalSeconds,httpCode}' /tmp/zeus-performance.json

    - name: validate-lock
      outputs:
        parameters:
          - name: lock-file-name
            valueFrom:
              path: /workspace/generated/lock-file-name.txt
          - name: lock-hash
            valueFrom:
              path: /workspace/generated/lock-hash.txt
      script:
        image: harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
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
            mountPath: /workspace

    - name: download-wheels
      synchronization:
        semaphore:
          configMapKeyRef:
            name: zeus-concurrency-limit
            key: wheel-downloads
      inputs:
        parameters:
          - name: zeus-pypi-url
          - name: lock-file-name
      outputs:
        parameters:
          - name: wheel-count
            valueFrom:
              path: /workspace/generated/wheel-count.txt
          - name: wheel-total-bytes
            valueFrom:
              path: /workspace/generated/wheel-total-bytes.txt
          - name: download-seconds
            valueFrom:
              path: /workspace/generated/download-seconds.txt
          - name: average-download-bytes-per-second
            valueFrom:
              path: /workspace/generated/average-download-bytes-per-second.txt
      script:
        image: harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
        env:
          - name: ZEUS_USERNAME
            valueFrom:
              secretKeyRef:
                name: zeus-pypi-auth
                key: username
          - name: ZEUS_PASSWORD
            valueFrom:
              secretKeyRef:
                name: zeus-pypi-auth
                key: password
        source: |
          set -euo pipefail
          rm -rf /workspace/wheelhouse
          mkdir -p /workspace/wheelhouse /workspace/generated
          start="$(date +%s)"
          PIP_INDEX_URL="$(python - <<'PY'
          import os
          from urllib.parse import quote, urlsplit, urlunsplit
          url = r'''{{inputs.parameters.zeus-pypi-url}}'''
          parts = urlsplit(url)
          user = quote(os.environ['ZEUS_USERNAME'], safe='')
          password = quote(os.environ['ZEUS_PASSWORD'], safe='')
          print(urlunsplit((parts.scheme, f'{user}:{password}@{parts.netloc}', parts.path, parts.query, parts.fragment)))
          PY
          )"
          python -m pip download \
            --index-url "$PIP_INDEX_URL" \
            --only-binary=:all: \
            --prefer-binary \
            --disable-pip-version-check \
            --timeout 30 \
            --retries 3 \
            --requirement "/workspace/source/{{inputs.parameters.lock-file-name}}" \
            --dest /workspace/wheelhouse
          unset PIP_INDEX_URL
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
          printf 'downloaded %s wheels (%s bytes) in %s seconds\n' "$count" "$bytes" "$seconds"
        volumeMounts:
          - name: workspace
            mountPath: /workspace

    - name: verify-wheelhouse
      inputs:
        parameters:
          - name: lock-file-name
      script:
        image: harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
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
            mountPath: /workspace

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
        image: harbor.CHANGE_ME.internal/platform/python-build-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
        source: |
          set -euo pipefail
          rm -rf /workspace/generated/context
          mkdir -p /workspace/generated/context/app /workspace/generated/context/wheelhouse
          cp -a /workspace/source/. /workspace/generated/context/app/
          cp -a /workspace/wheelhouse/. /workspace/generated/context/wheelhouse/
          cp "/workspace/source/{{inputs.parameters.lock-file-name}}" /workspace/generated/context/requirements.lock
          cat > /workspace/generated/build-spec.json <<'JSON'
          {
            "repositoryName": "{{inputs.parameters.repository-name}}",
            "runtimeImage": "{{inputs.parameters.runtime-image}}",
            "parentImageDigest": "{{inputs.parameters.parent-image-digest}}",
            "lockFileName": "{{inputs.parameters.lock-file-name}}",
            "lockHash": "{{inputs.parameters.lock-hash}}",
            "imageReference": "{{inputs.parameters.image-reference}}",
            "cacheReference": "{{inputs.parameters.cache-reference}}"
          }
          JSON
          python /opt/build-tools/scripts/validate_build_spec.py \
            --schema /opt/build-tools/schemas/build-spec.schema.json \
            /workspace/generated/build-spec.json
          python /opt/build-tools/scripts/render_dockerfile.py \
            --template /opt/build-tools/templates/Dockerfile.template \
            --output /workspace/generated/context/Dockerfile
          cp /opt/build-tools/templates/docker-bake.hcl /workspace/generated/context/docker-bake.hcl
          test -s /workspace/generated/context/Dockerfile
          test -s /workspace/generated/context/docker-bake.hcl
        volumeMounts:
          - name: workspace
            mountPath: /workspace

    - name: build-test-target
      inputs:
        parameters:
          - name: buildkit-address
          - name: runtime-image
          - name: cache-reference
      script:
        image: harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
        env:
          - name: DOCKER_CONFIG
            value: /root/.docker
        source: |
          set -euo pipefail
          buildctl --addr "{{inputs.parameters.buildkit-address}}" build \
            --frontend dockerfile.v0 \
            --local context=/workspace/generated/context \
            --local dockerfile=/workspace/generated/context \
            --opt filename=Dockerfile \
            --opt target=test \
            --opt "build-arg:RUNTIME_IMAGE={{inputs.parameters.runtime-image}}" \
            --import-cache "type=registry,ref={{inputs.parameters.cache-reference}}" \
            --export-cache "type=registry,ref={{inputs.parameters.cache-reference}},mode=max" \
            --output type=cacheonly
        volumeMounts:
          - name: workspace
            mountPath: /workspace
          - name: registry-auth
            mountPath: /root/.docker
            readOnly: true

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
              path: /workspace/generated/image-reference.txt
          - name: image-digest
            valueFrom:
              path: /workspace/generated/image-digest.txt
          - name: build-seconds
            valueFrom:
              path: /workspace/generated/build-seconds.txt
          - name: push-seconds
            valueFrom:
              path: /workspace/generated/push-seconds.txt
      script:
        image: harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
        env:
          - name: DOCKER_CONFIG
            value: /root/.docker
        source: |
          set -euo pipefail
          mkdir -p /workspace/generated
          start="$(date +%s)"
          buildctl --addr "{{inputs.parameters.buildkit-address}}" build \
            --frontend dockerfile.v0 \
            --local context=/workspace/generated/context \
            --local dockerfile=/workspace/generated/context \
            --opt filename=Dockerfile \
            --opt target=release \
            --opt "build-arg:RUNTIME_IMAGE={{inputs.parameters.runtime-image}}" \
            --import-cache "type=registry,ref={{inputs.parameters.cache-reference}}" \
            --export-cache "type=registry,ref={{inputs.parameters.cache-reference}},mode=max" \
            --output "type=image,name={{inputs.parameters.image-reference}},push=true" \
            --metadata-file /workspace/generated/build-metadata.json
          end="$(date +%s)"
          digest="$(jq -r '."containerimage.digest" // ."containerimage.descriptor".digest // empty' /workspace/generated/build-metadata.json)"
          printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo "BuildKit did not return a valid image digest" >&2; exit 1; }
          printf '%s' "{{inputs.parameters.image-reference}}" > /workspace/generated/image-reference.txt
          printf '%s' "$digest" > /workspace/generated/image-digest.txt
          printf '%s' "$((end - start))" > /workspace/generated/build-seconds.txt
          printf '%s' '0' > /workspace/generated/push-seconds.txt
          printf 'pushed %s@%s\n' "{{inputs.parameters.image-reference}}" "$digest"
        volumeMounts:
          - name: workspace
            mountPath: /workspace
          - name: registry-auth
            mountPath: /root/.docker
            readOnly: true

    - name: parse-image-digest
      inputs:
        parameters:
          - name: image-digest
      outputs:
        parameters:
          - name: parsed-image-digest
            valueFrom:
              path: /tmp/parsed-image-digest.txt
      script:
        image: harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
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
          - name: zeus-before-download-total-seconds
          - name: zeus-after-download-total-seconds
          - name: build-seconds
      outputs:
        parameters:
          - name: report-json
            valueFrom:
              path: /workspace/output/build-report.json
        artifacts:
          - name: build-report
            path: /workspace/output/build-report.json
            archive:
              none: {}
      script:
        image: harbor.CHANGE_ME.internal/platform/buildkit-client-tools:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
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
            --argjson zeusBeforeDownloadTotalSeconds "{{inputs.parameters.zeus-before-download-total-seconds}}" \
            --argjson zeusAfterDownloadTotalSeconds "{{inputs.parameters.zeus-after-download-total-seconds}}" \
            --argjson buildSeconds "{{inputs.parameters.build-seconds}}" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{workflowName:$workflowName,workflowUid:$workflowUid,namespace:$namespace,repositoryName:$repositoryName,imageReference:$imageReference,imageDigest:$imageDigest,parentImageDigest:$parentImageDigest,runtimeImage:$runtimeImage,lockFileName:$lockFileName,lockHash:$lockHash,wheelCount:$wheelCount,wheelTotalBytes:$wheelTotalBytes,wheelDownloadSeconds:$wheelDownloadSeconds,averageDownloadBytesPerSecond:$averageDownloadBytesPerSecond,zeusBeforeDownloadTotalSeconds:$zeusBeforeDownloadTotalSeconds,zeusAfterDownloadTotalSeconds:$zeusAfterDownloadTotalSeconds,buildSeconds:$buildSeconds,packageRepository:"zeus",wheelOnly:true,status:"SUCCEEDED",timestamp:$timestamp}' \
            > /workspace/output/build-report.json
          jq . /workspace/output/build-report.json
        volumeMounts:
          - name: workspace
            mountPath: /workspace

    - name: notify-build-result
      inputs:
        parameters:
          - name: notification-server-url
          - name: report-json
      script:
        image: harbor.CHANGE_ME.internal/platform/curl-jq:8.8@sha256:0000000000000000000000000000000000000000000000000000000000000000 # CHANGE_ME
        command: [sh]
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

## 2. YAML과 동일한 전체 JSON

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
          "name": "zeus-pypi-url",
          "value": "https://zeus.CHANGE_ME.internal/simple"
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
      },
      {
        "name": "zeus-pypi-auth",
        "secret": {
          "secretName": "zeus-pypi-auth"
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
              "name": "report-zeus-connectivity",
              "template": "report-zeus-connectivity",
              "arguments": {
                "parameters": [
                  {
                    "name": "zeus-pypi-url",
                    "value": "{{workflow.parameters.zeus-pypi-url}}"
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
              "depends": "validate-lock.Succeeded && report-zeus-connectivity.Succeeded",
              "template": "download-wheels",
              "arguments": {
                "parameters": [
                  {
                    "name": "zeus-pypi-url",
                    "value": "{{workflow.parameters.zeus-pypi-url}}"
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
              "name": "report-zeus-after-download",
              "depends": "download-wheels.Succeeded",
              "template": "report-zeus-connectivity",
              "arguments": {
                "parameters": [
                  {
                    "name": "zeus-pypi-url",
                    "value": "{{workflow.parameters.zeus-pypi-url}}"
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
              "depends": "validate-runtime-image.Succeeded && verify-wheelhouse.Succeeded && report-zeus-after-download.Succeeded",
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
              "name": "build-test-target",
              "depends": "prepare-build-context.Succeeded",
              "template": "build-test-target",
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
                    "name": "cache-reference",
                    "value": "{{workflow.parameters.cache-registry-address}}/{{tasks.get-repository-name-from-git.outputs.parameters.repository-name}}:buildcache"
                  }
                ]
              }
            },
            {
              "name": "build-release-image",
              "depends": "build-test-target.Succeeded",
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
                    "name": "zeus-before-download-total-seconds",
                    "value": "{{tasks.report-zeus-connectivity.outputs.parameters.total-seconds}}"
                  },
                  {
                    "name": "zeus-after-download-total-seconds",
                    "value": "{{tasks.report-zeus-after-download.outputs.parameters.total-seconds}}"
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
        "name": "report-zeus-connectivity",
        "inputs": {
          "parameters": [
            {
              "name": "zeus-pypi-url"
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
                "path": "/tmp/zeus-performance.json"
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
              "name": "zeus-performance-report",
              "path": "/tmp/zeus-performance.json",
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
          "env": [
            {
              "name": "ZEUS_USERNAME",
              "valueFrom": {
                "secretKeyRef": {
                  "name": "zeus-pypi-auth",
                  "key": "username"
                }
              }
            },
            {
              "name": "ZEUS_PASSWORD",
              "valueFrom": {
                "secretKeyRef": {
                  "name": "zeus-pypi-auth",
                  "key": "password"
                }
              }
            }
          ],
          "source": "set -euo pipefail\numask 077\npython - <<'PY'\nimport os\nfrom urllib.parse import urlsplit\n\nhost = urlsplit(r'''{{inputs.parameters.zeus-pypi-url}}''').hostname\nif not host:\n    raise SystemExit(\"zeus-pypi-url has no hostname\")\nwith open(\"/tmp/zeus.netrc\", \"w\", encoding=\"utf-8\") as netrc:\n    netrc.write(f\"machine {host}\\nlogin {os.environ['ZEUS_USERNAME']}\\npassword {os.environ['ZEUS_PASSWORD']}\\n\")\nPY\nchmod 600 /tmp/zeus.netrc\nformat='{\"dnsSeconds\":%{time_namelookup},\"tcpConnectSeconds\":%{time_connect},\"tlsConnectSeconds\":%{time_appconnect},\"firstByteSeconds\":%{time_starttransfer},\"totalSeconds\":%{time_total},\"downloadBytes\":%{size_download},\"downloadSpeedBytesPerSecond\":%{speed_download},\"httpCode\":%{http_code},\"remoteIp\":\"%{remote_ip}\",\"remotePort\":%{remote_port},\"redirectCount\":%{num_redirects}}'\nmetrics=\"$(curl --silent --show-error --location --fail-with-body --output /dev/null --netrc-file /tmp/zeus.netrc --write-out \"$format\" -- \"{{inputs.parameters.zeus-pypi-url}}\")\"\nrm -f /tmp/zeus.netrc\njq -n \\\n  --argjson metrics \"$metrics\" \\\n  --arg phase \"{{inputs.parameters.phase}}\" \\\n  --arg timestamp \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \\\n  --arg workflowName \"{{workflow.name}}\" \\\n  --arg workflowUid \"{{workflow.uid}}\" \\\n  --arg namespace \"{{workflow.namespace}}\" \\\n  '$metrics + {phase:$phase,timestamp:$timestamp,workflowName:$workflowName,workflowUid:$workflowUid,namespace:$namespace}' \\\n  > /tmp/zeus-performance.json\njq -r '.totalSeconds' /tmp/zeus-performance.json > /tmp/total-seconds.txt\njq -r '.httpCode' /tmp/zeus-performance.json > /tmp/http-code.txt\njq '{phase,totalSeconds,httpCode}' /tmp/zeus-performance.json\n"
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
              "name": "zeus-concurrency-limit",
              "key": "wheel-downloads"
            }
          }
        },
        "inputs": {
          "parameters": [
            {
              "name": "zeus-pypi-url"
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
          "env": [
            {
              "name": "ZEUS_USERNAME",
              "valueFrom": {
                "secretKeyRef": {
                  "name": "zeus-pypi-auth",
                  "key": "username"
                }
              }
            },
            {
              "name": "ZEUS_PASSWORD",
              "valueFrom": {
                "secretKeyRef": {
                  "name": "zeus-pypi-auth",
                  "key": "password"
                }
              }
            }
          ],
          "source": "set -euo pipefail\nrm -rf /workspace/wheelhouse\nmkdir -p /workspace/wheelhouse /workspace/generated\nstart=\"$(date +%s)\"\nPIP_INDEX_URL=\"$(python - <<'PY'\nimport os\nfrom urllib.parse import quote, urlsplit, urlunsplit\nurl = r'''{{inputs.parameters.zeus-pypi-url}}'''\nparts = urlsplit(url)\nuser = quote(os.environ['ZEUS_USERNAME'], safe='')\npassword = quote(os.environ['ZEUS_PASSWORD'], safe='')\nprint(urlunsplit((parts.scheme, f'{user}:{password}@{parts.netloc}', parts.path, parts.query, parts.fragment)))\nPY\n)\"\npython -m pip download \\\n  --index-url \"$PIP_INDEX_URL\" \\\n  --only-binary=:all: \\\n  --prefer-binary \\\n  --disable-pip-version-check \\\n  --timeout 30 \\\n  --retries 3 \\\n  --requirement \"/workspace/source/{{inputs.parameters.lock-file-name}}\" \\\n  --dest /workspace/wheelhouse\nunset PIP_INDEX_URL\nend=\"$(date +%s)\"\nseconds=\"$((end - start))\"\ncount=\"$(find /workspace/wheelhouse -type f -name '*.whl' | wc -l | tr -d ' ')\"\n[ \"$count\" -gt 0 ] || { echo \"wheelhouse is empty\" >&2; exit 1; }\nbytes=\"$(find /workspace/wheelhouse -type f -name '*.whl' -exec stat -c '%s' {} + | awk '{sum += $1} END {print sum + 0}')\"\naverage=\"$((bytes / (seconds > 0 ? seconds : 1)))\"\nprintf '%s' \"$count\" > /workspace/generated/wheel-count.txt\nprintf '%s' \"$bytes\" > /workspace/generated/wheel-total-bytes.txt\nprintf '%s' \"$seconds\" > /workspace/generated/download-seconds.txt\nprintf '%s' \"$average\" > /workspace/generated/average-download-bytes-per-second.txt\nprintf 'downloaded %s wheels (%s bytes) in %s seconds\\n' \"$count\" \"$bytes\" \"$seconds\"\n",
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
          "source": "set -euo pipefail\nrm -rf /workspace/generated/context\nmkdir -p /workspace/generated/context/app /workspace/generated/context/wheelhouse\ncp -a /workspace/source/. /workspace/generated/context/app/\ncp -a /workspace/wheelhouse/. /workspace/generated/context/wheelhouse/\ncp \"/workspace/source/{{inputs.parameters.lock-file-name}}\" /workspace/generated/context/requirements.lock\ncat > /workspace/generated/build-spec.json <<'JSON'\n{\n  \"repositoryName\": \"{{inputs.parameters.repository-name}}\",\n  \"runtimeImage\": \"{{inputs.parameters.runtime-image}}\",\n  \"parentImageDigest\": \"{{inputs.parameters.parent-image-digest}}\",\n  \"lockFileName\": \"{{inputs.parameters.lock-file-name}}\",\n  \"lockHash\": \"{{inputs.parameters.lock-hash}}\",\n  \"imageReference\": \"{{inputs.parameters.image-reference}}\",\n  \"cacheReference\": \"{{inputs.parameters.cache-reference}}\"\n}\nJSON\npython /opt/build-tools/scripts/validate_build_spec.py \\\n  --schema /opt/build-tools/schemas/build-spec.schema.json \\\n  /workspace/generated/build-spec.json\npython /opt/build-tools/scripts/render_dockerfile.py \\\n  --template /opt/build-tools/templates/Dockerfile.template \\\n  --output /workspace/generated/context/Dockerfile\ncp /opt/build-tools/templates/docker-bake.hcl /workspace/generated/context/docker-bake.hcl\ntest -s /workspace/generated/context/Dockerfile\ntest -s /workspace/generated/context/docker-bake.hcl\n",
          "volumeMounts": [
            {
              "name": "workspace",
              "mountPath": "/workspace"
            }
          ]
        }
      },
      {
        "name": "build-test-target",
        "inputs": {
          "parameters": [
            {
              "name": "buildkit-address"
            },
            {
              "name": "runtime-image"
            },
            {
              "name": "cache-reference"
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
          "source": "set -euo pipefail\nbuildctl --addr \"{{inputs.parameters.buildkit-address}}\" build \\\n  --frontend dockerfile.v0 \\\n  --local context=/workspace/generated/context \\\n  --local dockerfile=/workspace/generated/context \\\n  --opt filename=Dockerfile \\\n  --opt target=test \\\n  --opt \"build-arg:RUNTIME_IMAGE={{inputs.parameters.runtime-image}}\" \\\n  --import-cache \"type=registry,ref={{inputs.parameters.cache-reference}}\" \\\n  --export-cache \"type=registry,ref={{inputs.parameters.cache-reference}},mode=max\" \\\n  --output type=cacheonly\n",
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
          "source": "set -euo pipefail\nmkdir -p /workspace/generated\nstart=\"$(date +%s)\"\nbuildctl --addr \"{{inputs.parameters.buildkit-address}}\" build \\\n  --frontend dockerfile.v0 \\\n  --local context=/workspace/generated/context \\\n  --local dockerfile=/workspace/generated/context \\\n  --opt filename=Dockerfile \\\n  --opt target=release \\\n  --opt \"build-arg:RUNTIME_IMAGE={{inputs.parameters.runtime-image}}\" \\\n  --import-cache \"type=registry,ref={{inputs.parameters.cache-reference}}\" \\\n  --export-cache \"type=registry,ref={{inputs.parameters.cache-reference}},mode=max\" \\\n  --output \"type=image,name={{inputs.parameters.image-reference}},push=true\" \\\n  --metadata-file /workspace/generated/build-metadata.json\nend=\"$(date +%s)\"\ndigest=\"$(jq -r '.\"containerimage.digest\" // .\"containerimage.descriptor\".digest // empty' /workspace/generated/build-metadata.json)\"\nprintf '%s' \"$digest\" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo \"BuildKit did not return a valid image digest\" >&2; exit 1; }\nprintf '%s' \"{{inputs.parameters.image-reference}}\" > /workspace/generated/image-reference.txt\nprintf '%s' \"$digest\" > /workspace/generated/image-digest.txt\nprintf '%s' \"$((end - start))\" > /workspace/generated/build-seconds.txt\nprintf '%s' '0' > /workspace/generated/push-seconds.txt\nprintf 'pushed %s@%s\\n' \"{{inputs.parameters.image-reference}}\" \"$digest\"\n",
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
              "name": "zeus-before-download-total-seconds"
            },
            {
              "name": "zeus-after-download-total-seconds"
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
          "source": "set -euo pipefail\nmkdir -p /workspace/output\njq -n \\\n  --arg workflowName \"{{workflow.name}}\" \\\n  --arg workflowUid \"{{workflow.uid}}\" \\\n  --arg namespace \"{{workflow.namespace}}\" \\\n  --arg repositoryName \"{{inputs.parameters.repository-name}}\" \\\n  --arg imageReference \"{{inputs.parameters.image-reference}}\" \\\n  --arg imageDigest \"{{inputs.parameters.image-digest}}\" \\\n  --arg parentImageDigest \"{{inputs.parameters.parent-image-digest}}\" \\\n  --arg runtimeImage \"{{inputs.parameters.runtime-image}}\" \\\n  --arg lockFileName \"{{inputs.parameters.lock-file-name}}\" \\\n  --arg lockHash \"{{inputs.parameters.lock-hash}}\" \\\n  --argjson wheelCount \"{{inputs.parameters.wheel-count}}\" \\\n  --argjson wheelTotalBytes \"{{inputs.parameters.wheel-total-bytes}}\" \\\n  --argjson wheelDownloadSeconds \"{{inputs.parameters.wheel-download-seconds}}\" \\\n  --argjson averageDownloadBytesPerSecond \"{{inputs.parameters.average-download-bytes-per-second}}\" \\\n  --argjson zeusBeforeDownloadTotalSeconds \"{{inputs.parameters.zeus-before-download-total-seconds}}\" \\\n  --argjson zeusAfterDownloadTotalSeconds \"{{inputs.parameters.zeus-after-download-total-seconds}}\" \\\n  --argjson buildSeconds \"{{inputs.parameters.build-seconds}}\" \\\n  --arg timestamp \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \\\n  '{workflowName:$workflowName,workflowUid:$workflowUid,namespace:$namespace,repositoryName:$repositoryName,imageReference:$imageReference,imageDigest:$imageDigest,parentImageDigest:$parentImageDigest,runtimeImage:$runtimeImage,lockFileName:$lockFileName,lockHash:$lockHash,wheelCount:$wheelCount,wheelTotalBytes:$wheelTotalBytes,wheelDownloadSeconds:$wheelDownloadSeconds,averageDownloadBytesPerSecond:$averageDownloadBytesPerSecond,zeusBeforeDownloadTotalSeconds:$zeusBeforeDownloadTotalSeconds,zeusAfterDownloadTotalSeconds:$zeusAfterDownloadTotalSeconds,buildSeconds:$buildSeconds,packageRepository:\"zeus\",wheelOnly:true,status:\"SUCCEEDED\",timestamp:$timestamp}' \\\n  > /workspace/output/build-report.json\njq . /workspace/output/build-report.json\n",
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

## 3. 필요한 Secret YAML

```yaml
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
      config.json: '{"auths":{"harbor.CHANGE_ME.internal":{"username":"CHANGE_ME","password":"CHANGE_ME"}}}' # CHANGE_ME
  - apiVersion: v1
    kind: Secret
    metadata:
      name: bitbucket-ssh
      namespace: argo
    type: Opaque
    stringData:
      id_rsa: | # CHANGE_ME
        CHANGE_ME
      known_hosts: | # CHANGE_ME; pin the real Bitbucket host key
        bitbucket.CHANGE_ME.internal ssh-ed25519 CHANGE_ME
  - apiVersion: v1
    kind: Secret
    metadata:
      name: zeus-pypi-auth
      namespace: argo
    type: Opaque
    stringData:
      username: CHANGE_ME
      password: CHANGE_ME
```

## 4. Secret JSON

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
    },
    {
      "apiVersion": "v1",
      "kind": "Secret",
      "metadata": {
        "name": "zeus-pypi-auth",
        "namespace": "argo"
      },
      "type": "Opaque",
      "stringData": {
        "username": "CHANGE_ME",
        "password": "CHANGE_ME"
      }
    }
  ]
}
```

## 5. Zeus 동시성 제한 ConfigMap YAML

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: zeus-concurrency-limit
  namespace: argo
data:
  wheel-downloads: "4" # CHANGE_ME
```

## 6. ConfigMap JSON

```json
{
  "apiVersion": "v1",
  "kind": "ConfigMap",
  "metadata": {
    "name": "zeus-concurrency-limit",
    "namespace": "argo"
  },
  "data": {
    "wheel-downloads": "4"
  }
}
```

## 7. Build Tools Image 디렉터리 구조

```text
build-tools/
├── Dockerfile
├── schemas/
│   └── build-spec.schema.json
├── scripts/
│   ├── generate_report.py
│   ├── render_dockerfile.py
│   ├── validate_build_spec.py
│   └── validate_lock.py
└── templates/
    ├── Dockerfile.template
    └── docker-bake.hcl
```

Build Tools의 전체 보조 파일은 `build-tools/` 디렉터리에 포함되어 있다.

## 8. Multi-stage Dockerfile Template

```dockerfile
# syntax=docker/dockerfile:1.7
ARG RUNTIME_IMAGE

# 1-3. Trusted base, Python runtime, common dependencies are inherited by digest.
FROM ${RUNTIME_IMAGE} AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app

# 4. Application dependencies are installed strictly from the wheelhouse.
FROM base AS dependencies
COPY requirements.lock /build/requirements.lock
COPY wheelhouse /build/wheelhouse
RUN python -m pip install \
      --no-index \
      --find-links=/build/wheelhouse \
      --only-binary=:all: \
      --prefix=/opt/python-dependencies \
      -r /build/requirements.lock \
    && rm -rf /root/.cache/pip

# The test target is cache-only and is never pushed by the workflow.
FROM base AS test
COPY --from=dependencies /opt/python-dependencies/ /usr/local/
COPY app /app
RUN python -m compileall -q /app \
    && if [ -d /app/tests ]; then python -m pytest -q /app/tests; fi

# 5. Remove test-only source before copying into the runtime image.
FROM base AS source-clean
COPY app /clean-app
RUN rm -rf /clean-app/tests /clean-app/test /clean-app/.git \
    /clean-app/.pytest_cache /clean-app/.mypy_cache /clean-app/.ruff_cache

# 6. Runtime configuration; no wheelhouse, compiler, cache, or BuildKit files.
FROM base AS release
COPY --from=dependencies /opt/python-dependencies/ /usr/local/
COPY --from=source-clean /clean-app /app
USER 10001:10001
CMD ["python", "-m", "app"]
```

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
