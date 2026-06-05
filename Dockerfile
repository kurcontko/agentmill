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

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    expect \
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
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
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
RUN chown agent:agent /workspace

# Entrypoints
COPY entrypoint.sh /entrypoint.sh
COPY entrypoint-tui.sh /entrypoint-tui.sh
COPY entrypoint-common.sh /entrypoint-common.sh
COPY lib/agentmill/sh /lib/agentmill/sh
COPY setup-claude-config.sh /setup-claude-config.sh
COPY setup-repo-env.sh /setup-repo-env.sh
COPY auto-trust.exp /auto-trust.exp
RUN chmod +x /entrypoint.sh /entrypoint-tui.sh /entrypoint-common.sh /setup-claude-config.sh /setup-repo-env.sh /auto-trust.exp

USER agent

# Pre-configure Claude Code: skip onboarding + trust prompts
# NOSONAR — bypassPermissions is required for autonomous headless operation inside an isolated container
RUN mkdir -p /home/agent/.claude && \
    echo '{"hasCompletedOnboarding":true}' > /home/agent/.claude.json && \
    echo '{"hasCompletedOnboarding":true,"hasTrustDialogAccepted":true,"hasTrustDialogHooksAccepted":true}' > /home/agent/.claude/claude.json && \
    echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep"],"defaultMode":"bypassPermissions"}}' > /home/agent/.claude/settings.json

# Default: headless pipe mode. Use entrypoint-tui.sh for watch/interactive modes.
ENTRYPOINT ["/entrypoint.sh"]
