FROM node:20-slim@sha256:17281e8d1dc4d671976c6b89a12f47a44c2f390b63a989e2e327631041f544fd
COPY --from=ghcr.io/astral-sh/uv:0.8.17 /uv /uvx /usr/local/bin/

# Pin Claude Code CLI version. Floor is v2.1.111 — earlier versions ship with
# a stale alias table (`opus` resolves to 4.6 instead of 4.7) and stale model-
# capability metadata, so passing `claude --model claude-opus-4-7` silently
# downshifts to an older Opus. Bump CLAUDE_CODE_VERSION to upgrade the CLI
# (cache-busts the npm install layer cleanly).
# Refs: https://github.com/anthropics/claude-code/issues/50810
#       https://code.claude.com/docs/en/changelog
ARG CLAUDE_CODE_VERSION=2.1.119
ARG CODEX_VERSION=0.154.0

# Disable dependency lifecycle scripts. Only Claude's pinned, reviewed installer
# is run explicitly: it places the already-downloaded platform binary (no fetch).
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    make \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/lib/python*/EXTERNALLY-MANAGED \
    && npm install -g --ignore-scripts "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" \
    && node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs \
    && claude --version && codex --version \
    && useradd -m -s /bin/bash agent

# Belt-and-suspenders: pin per-family aliases at the env layer so any code
# path that uses bare `opus` / `sonnet` / `haiku` resolves to the right
# version even if the CLI's internal alias table goes stale again.
# These are documented overrides:
# https://code.claude.com/docs/en/model-config
ENV ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-7 \
    ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6 \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001
WORKDIR /workspace
# uv must not replace a macOS/host virtualenv in a bind-mounted checkout.
ENV UV_PROJECT_ENVIRONMENT=/tmp/agentmill-venv
RUN chown agent:agent /workspace

USER agent

# The host supervisor selects each container command and supplies native settings.
CMD ["bash"]
