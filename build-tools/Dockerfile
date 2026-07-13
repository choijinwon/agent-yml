ARG INTERNAL_PYTHON_IMAGE=harbor.CHANGE_ME.internal/runtime/python311@sha256:0000000000000000000000000000000000000000000000000000000000000000
FROM ${INTERNAL_PYTHON_IMAGE}

COPY templates /opt/build-tools/templates
COPY scripts /opt/build-tools/scripts
COPY schemas /opt/build-tools/schemas
RUN chmod 0555 /opt/build-tools/scripts/*.py

ENTRYPOINT ["python"]
