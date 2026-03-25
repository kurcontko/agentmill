FROM node:20-slim
COPY --from=ghcr.io/astral-sh/uv:0.8.17 /uv /uvx /usr/local/bin/

RUN apt-get update && apt-get install -y \
    ca-certificates \
    git \
    bash \
    curl \
    jq \
    ripgrep \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    expect \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code @openai/codex

# Non-root user (Claude Code refuses --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash agent
WORKDIR /workspace
RUN chown agent:agent /workspace

# Entrypoints
COPY entrypoint.sh /entrypoint.sh
COPY entrypoint-tui.sh /entrypoint-tui.sh
COPY entrypoint-codex.sh /entrypoint-codex.sh
COPY entrypoint-codex-tui.sh /entrypoint-codex-tui.sh
COPY codex_preview_supervisor.py /codex_preview_supervisor.py
COPY codex_preview_server.py /codex_preview_server.py
COPY static/ /static/
COPY setup-claude-config.sh /setup-claude-config.sh
COPY setup-repo-env.sh /setup-repo-env.sh
COPY auto-trust.exp /auto-trust.exp
RUN chmod +x /entrypoint.sh /entrypoint-tui.sh /entrypoint-codex.sh /entrypoint-codex-tui.sh /codex_preview_supervisor.py /codex_preview_server.py /setup-claude-config.sh /setup-repo-env.sh /auto-trust.exp

USER agent

# Pre-configure Claude Code: skip onboarding + trust prompts
RUN mkdir -p /home/agent/.claude && \
    echo '{"hasCompletedOnboarding":true}' > /home/agent/.claude.json && \
    echo '{"hasCompletedOnboarding":true,"hasTrustDialogAccepted":true,"hasTrustDialogHooksAccepted":true}' > /home/agent/.claude/claude.json && \
    echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep"],"defaultMode":"bypassPermissions"}}' > /home/agent/.claude/settings.json

# Default: headless pipe mode. Use entrypoint-tui.sh for TUI dashboard.
ENTRYPOINT ["/entrypoint.sh"]
