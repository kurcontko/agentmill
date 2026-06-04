FROM node:22-slim@sha256:7af03b14a13c8cdd38e45058fd957bf00a72bbe17feac43b1c15a689c029c732
COPY --from=ghcr.io/astral-sh/uv:0.8.17 /uv /uvx /usr/local/bin/

# Pin Claude Code CLI version. Floor is v2.1.154 — earlier versions ship with
# a stale alias table (`opus` resolves below 4.8) and stale model-capability
# metadata, so passing `claude --model claude-opus-4-8` can silently
# downshift to an older Opus. Bump CLAUDE_CODE_VERSION to upgrade the CLI
# (cache-busts the npm install layer cleanly).
# Refs: https://github.com/anthropics/claude-code/issues/50810
#       https://code.claude.com/docs/en/changelog
ARG CLAUDE_CODE_VERSION=2.1.154
ARG OPENCODE_VERSION=0.6.6
ARG CODEX_CLI_VERSION=latest
ARG QWEN_CODE_VERSION=latest
ARG GEMINI_CLI_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    bubblewrap \
    ca-certificates \
    curl \
    expect \
    cargo \
    git \
    golang-go \
    jq \
    make \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/lib/python*/EXTERNALLY-MANAGED \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "opencode-ai@${OPENCODE_VERSION}" "@openai/codex@${CODEX_CLI_VERSION}" "@qwen-code/qwen-code@${QWEN_CODE_VERSION}" "@google/gemini-cli@${GEMINI_CLI_VERSION}" pnpm \
    && userdel -r node \
    && useradd -m -s /bin/bash -u 1000 agent

# Belt-and-suspenders: pin per-family aliases at the env layer so any code
# path that uses bare `opus` / `sonnet` / `haiku` resolves to the right
# version even if the CLI's internal alias table goes stale again.
# These are documented overrides:
# https://code.claude.com/docs/en/model-config
ENV ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8 \
    ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6 \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001
WORKDIR /workspace
RUN chown agent:agent /workspace

# Entrypoints
COPY entrypoint.sh /entrypoint.sh
COPY entrypoint-tui.sh /entrypoint-tui.sh
COPY entrypoint-common.sh /entrypoint-common.sh
COPY setup-claude-config.sh /setup-claude-config.sh
COPY setup-repo-env.sh /setup-repo-env.sh
COPY auto-trust.exp /auto-trust.exp
COPY scripts/acp-stdio-bridge.py /acp-stdio-bridge.py
COPY scripts/pretool-policy.py /agentmill-pretool-policy.py
COPY scripts/egress-proxy.py /agentmill-egress-proxy.py
RUN chmod +x /entrypoint.sh /entrypoint-tui.sh /entrypoint-common.sh /setup-claude-config.sh /setup-repo-env.sh /auto-trust.exp /acp-stdio-bridge.py /agentmill-pretool-policy.py /agentmill-egress-proxy.py

USER agent

# Pre-configure Claude Code: skip onboarding + trust prompts
# NOSONAR — bypassPermissions is required for autonomous headless operation inside an isolated container
RUN mkdir -p /home/agent/.claude && \
    echo '{"hasCompletedOnboarding":true}' > /home/agent/.claude.json && \
    echo '{"hasCompletedOnboarding":true,"hasTrustDialogAccepted":true,"hasTrustDialogHooksAccepted":true}' > /home/agent/.claude/claude.json && \
    echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep"],"defaultMode":"bypassPermissions"}}' > /home/agent/.claude/settings.json

# Default: headless pipe mode. Use entrypoint-tui.sh for watch/interactive modes.
ENTRYPOINT ["/entrypoint.sh"]
