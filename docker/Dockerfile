FROM nousresearch/hermes-agent:latest AS base

ARG HERMES_BASE_VERSION=latest
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION=0.1.0

LABEL org.opencontainers.image.title="omlx-agent-hermes" \
      org.opencontainers.image.description="Hermes Agent sandbox for Apple Silicon oMLX stack" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/aarogozin/mlx-to-isolated-hermes" \
      org.opencontainers.image.licenses="MIT"

USER root

# ── System packages ──────────────────────────────────────────────────────────
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    coreutils \
    curl \
    file \
    findutils \
    git \
    jq \
    less \
    nano \
    nodejs \
    npm \
    openssh-client \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    tar \
    unzip \
    wget \
    xz-utils \
    yq \
    zip \
  && npm install -g pnpm@10 \
  && uv pip install \
       --python /opt/hermes/.venv/bin/python \
       "python-telegram-bot>=21,<23" \
  && ln -sfn /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes \
  && mkdir -p /home/agent/.hermes /home/agent/workspace /mnt/obsidian \
  && chown -R 10000:10000 /home/agent /mnt/obsidian \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

USER 10000:10000

WORKDIR /home/agent

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://localhost:9119/health >/dev/null 2>&1 || exit 1
