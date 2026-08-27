FROM node:22-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5

# Bump to upgrade the CLIs (cache-busts the npm layer cleanly).
ARG CLAUDE_CODE_VERSION=2.1.241
ARG CODEX_VERSION=0.147.0

# Only what the loop itself needs. Repo toolchains are the agent's job:
# it runs `sudo apt-get install` (scoped below) or a language installer.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq openssh-client python3 sudo \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
                      "@openai/codex@${CODEX_VERSION}" \
    && useradd -m -s /bin/bash agent \
    && echo 'agent ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt' \
        > /etc/sudoers.d/agent

WORKDIR /workspace
RUN chown agent:agent /workspace
COPY loop.sh /loop.sh
RUN chmod 755 /loop.sh

USER agent
# Skip onboarding; bypassPermissions is intentional — the container is the boundary.
RUN mkdir -p /home/agent/.claude \
    && echo '{"hasCompletedOnboarding":true}' > /home/agent/.claude.json \
    && echo '{"permissions":{"defaultMode":"bypassPermissions"}}' > /home/agent/.claude/settings.json

ENTRYPOINT ["/loop.sh"]
