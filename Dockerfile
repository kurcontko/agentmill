FROM node:20-slim
COPY --from=ghcr.io/astral-sh/uv:0.8.17 /uv /uvx /usr/local/bin/

RUN apt-get update && apt-get install -y \
    bash \
    ca-certificates \
    curl \
    expect \
    git \
    jq \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code @openai/codex \
    && useradd -m -s /bin/bash agent
WORKDIR /workspace
RUN chown agent:agent /workspace

# Entrypoints
COPY entrypoint.sh /entrypoint.sh
COPY entrypoint-tui.sh /entrypoint-tui.sh
COPY entrypoint-codex.sh /entrypoint-codex.sh
COPY entrypoint-codex-tui.sh /entrypoint-codex-tui.sh
COPY entrypoint-common.sh /entrypoint-common.sh
COPY setup-claude-config.sh /setup-claude-config.sh
COPY setup-repo-env.sh /setup-repo-env.sh
COPY auto-trust.exp /auto-trust.exp
RUN chmod +x /entrypoint.sh /entrypoint-tui.sh /entrypoint-codex.sh /entrypoint-codex-tui.sh /entrypoint-common.sh /setup-claude-config.sh /setup-repo-env.sh /auto-trust.exp

USER agent

# Pre-configure Claude Code: skip onboarding + trust prompts
# NOSONAR — bypassPermissions is required for autonomous headless operation inside an isolated container
RUN mkdir -p /home/agent/.claude && \
    echo '{"hasCompletedOnboarding":true}' > /home/agent/.claude.json && \
    echo '{"hasCompletedOnboarding":true,"hasTrustDialogAccepted":true,"hasTrustDialogHooksAccepted":true}' > /home/agent/.claude/claude.json && \
    echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep"],"defaultMode":"bypassPermissions"}}' > /home/agent/.claude/settings.json

# Pre-create Codex config dir (host ~/.codex mount overlays this if provided)
RUN mkdir -p /home/agent/.codex

# Codex requires this env var to skip native sandbox in Docker (container is the sandbox)
ENV CODEX_UNSAFE_ALLOW_NO_SANDBOX=1

# Default: headless pipe mode. Use entrypoint-tui.sh for TUI dashboard.
ENTRYPOINT ["/entrypoint.sh"]
