FROM node:20-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    git \
    bash \
    curl \
    openssh-client \
    python3 \
    expect \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code opencode-ai

# Non-root user (Claude Code refuses --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash agent
WORKDIR /workspace
RUN chown agent:agent /workspace

# Entrypoints
COPY entrypoint.sh /entrypoint.sh
COPY entrypoint-tui.sh /entrypoint-tui.sh
COPY setup-claude-config.sh /setup-claude-config.sh
#COPY auto-trust.exp /auto-trust.exp
RUN chmod +x /entrypoint.sh /entrypoint-tui.sh /setup-claude-config.sh

USER agent

# Pre-configure Claude Code: skip onboarding + trust prompts
RUN mkdir -p /home/agent/.claude && \
    echo '{"hasCompletedOnboarding":true}' > /home/agent/.claude.json && \
    echo '{"hasCompletedOnboarding":true,"hasTrustDialogAccepted":true,"hasTrustDialogHooksAccepted":true}' > /home/agent/.claude/claude.json && \
    echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep"],"defaultMode":"bypassPermissions"}}' > /home/agent/.claude/settings.json

# Default: headless pipe mode. Use entrypoint-tui.sh for TUI dashboard.
ENTRYPOINT ["/entrypoint.sh"]