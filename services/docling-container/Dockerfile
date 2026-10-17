# UNBUILT recipe. Supply a reviewed Python 3.12 Linux image BY DIGEST.
# Use repository root as context and this adjacent Dockerfile.dockerignore.
ARG PYTHON_BASE
FROM ${PYTHON_BASE}
ARG PYTHON_BASE
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INDEX=1 \
    HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 \
    DO_NOT_TRACK=1 TOKENIZERS_PARALLELISM=false
# Provisioning is deliberately absent from Git. Never reuse the macOS freeze as a Linux hash lock.
COPY services/docling-container/provisioned/requirements-linux.lock.txt /build/requirements-linux.lock.txt
COPY services/docling-container/provisioned/wheels/ /build/wheels/
RUN --network=none python -c 'import os,re; assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9./:_-]*@sha256:[a-f0-9]{64}", os.environ["PYTHON_BASE"]); import sys; assert sys.version_info[:2] == (3,12)' \
    && python -m venv /opt/docling-env \
    && /opt/docling-env/bin/python -m pip install --no-index --only-binary=:all: --no-cache-dir --require-hashes --find-links=/build/wheels -r /build/requirements-linux.lock.txt \
    && /opt/docling-env/bin/python -c 'import importlib.metadata; assert importlib.metadata.version("docling") == "2.139.0"; assert importlib.metadata.version("regex") == "2026.9.29"' \
    && rm -rf /build
COPY tools/docling/extract_pdf.py tools/docling/index_payload.py tools/docling/structured_chunking.py tools/docling/metadata.py /app/tools/docling/
COPY services/docling-processor/runner.py services/docling-processor/validation.py services/docling-processor/child_entry.py services/docling-processor/private_http.py services/docling-processor/container_entry.py /app/services/docling-processor/
COPY services/docling-container/provisioned/models/ /opt/docling-models/
# Code and models are owned by root, never by the serving process.
RUN --network=none mkdir -p /tmp/studiquo-docling-jobs \
    && chmod -R a+rX /app /opt/docling-models /opt/docling-env \
    && chmod -R a-w /app /opt/docling-models /opt/docling-env \
    && chown 10001:10001 /tmp/studiquo-docling-jobs \
    && chmod 0700 /tmp/studiquo-docling-jobs
USER 10001:10001
WORKDIR /app/services/docling-processor
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/docling-env/bin/python", "-I", "-B", "/app/services/docling-processor/container_entry.py"]
