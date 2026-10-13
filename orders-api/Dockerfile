# syntax=docker/dockerfile:1

# ---- Stage 1: build a virtualenv with only runtime dependencies ----
FROM python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt


# ---- Stage 2: minimal runtime image, running as a non-root user ----
FROM python:3.12-slim AS runtime

ARG APP_VERSION=dev

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    APP_VERSION=${APP_VERSION}

LABEL org.opencontainers.image.title="orders-api" \
      org.opencontainers.image.version="${APP_VERSION}"

# Fixed numeric UID/GID so Kubernetes can verify runAsNonRoot.
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=10001:10001 orders_api ./orders_api

USER 10001:10001
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status == 200 else 1)"]

CMD ["uvicorn", "orders_api.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
