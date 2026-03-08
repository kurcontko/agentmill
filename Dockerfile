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
    && npm install -g @anthropic-ai/claude-code@2.1.71 \
    && useradd -m -s /bin/bash agent
WORKDIR /workspace
RUN chown agent:agent /workspace

# Entrypoints
COPY entrypoint.sh /entrypoint.sh
COPY entrypoint-tui.sh /entrypoint-tui.sh
COPY setup-claude-config.sh /setup-claude-config.sh
COPY setup-repo-env.sh /setup-repo-env.sh
COPY auto-trust.exp /auto-trust.exp
RUN chmod +x /entrypoint.sh /entrypoint-tui.sh /setup-claude-config.sh /setup-repo-env.sh /auto-trust.exp

USER agent

# Pre-configure Claude Code: skip onboarding + trust prompts
# NOSONAR — bypassPermissions is required for autonomous headless operation inside an isolated container
RUN mkdir -p /home/agent/.claude && \
    echo '{"hasCompletedOnboarding":true}' > /home/agent/.claude.json && \
    echo '{"hasCompletedOnboarding":true,"hasTrustDialogAccepted":true,"hasTrustDialogHooksAccepted":true}' > /home/agent/.claude/claude.json && \
    echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep"],"defaultMode":"bypassPermissions"}}' > /home/agent/.claude/settings.json

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD pgrep -f "node.*claude" > /dev/null || exit 1

# Default: headless pipe mode. Use entrypoint-tui.sh for TUI dashboard.
ENTRYPOINT ["/entrypoint.sh"]
