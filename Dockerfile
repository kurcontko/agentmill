FROM node:22-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5

# Bump to upgrade the CLIs (cache-busts the npm layer cleanly).
ARG CLAUDE_CODE_VERSION=2.1.241
ARG CODEX_VERSION=0.147.0
# Client only — `mill --dind` points it at the sidecar daemon; no daemon here.
ARG DOCKER_CLI_VERSION=27.5.1
# The container user must be able to write the bind-mounted repo and logs.
# Docker Desktop maps ownership; on a Linux host the ids must match the
# caller's — `mill build` passes them. (node:22-slim's `node` user holds
# uid 1000, so it is removed rather than left to collide.)
ARG AGENT_UID=1000
ARG AGENT_GID=1000

# Only what the loop itself needs. Repo toolchains are the agent's job:
# it runs `sudo apt-get install` (scoped below) or a language installer.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq openssh-client python3 sudo \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
                      "@openai/codex@${CODEX_VERSION}" \
    && userdel -r node \
    && (getent group "${AGENT_GID}" >/dev/null || groupadd -g "${AGENT_GID}" agent) \
    && useradd -m -u "${AGENT_UID}" -g "${AGENT_GID}" -s /bin/bash agent \
    && echo 'agent ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt' \
        > /etc/sudoers.d/agent

# The docker CLI, so --dind's DOCKER_HOST is actually usable by the agent.
RUN curl -fsSL "https://download.docker.com/linux/static/stable/$(uname -m)/docker-${DOCKER_CLI_VERSION}.tgz" \
        | tar -xzC /usr/local/bin --strip-components=1 docker/docker \
    && docker --version

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
