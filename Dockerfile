FROM node:22.23.2-alpine3.24@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32

# Bump to upgrade the CLIs (cache-busts the npm layer cleanly).
ARG CLAUDE_CODE_VERSION=2.1.241
ARG CODEX_VERSION=0.147.0
# Node's bundled npm can lag security fixes in its vendored dependencies.
ARG NPM_VERSION=11.19.1
# Client only — `mill --dind` points it at the sidecar daemon; no daemon here.
ARG DOCKER_CLI_VERSION=29.8.0
# The container user must be able to write the bind-mounted repo and logs.
# Docker Desktop maps ownership; on a Linux host the ids must match the
# caller's — `mill build` passes them. (The base image's `node` user holds
# uid 1000, so it is removed rather than left to collide.)
ARG AGENT_UID=1000
ARG AGENT_GID=1000

# System dependencies belong in this image or an operator-built derived image.
# Neither worker nor reviewer receives sudo or a runtime package-install API.
RUN apk upgrade --no-cache \
    && apk add --no-cache bash ca-certificates coreutils curl findutils git grep \
        jq openssh-client procps python3 sed shadow tar util-linux \
    && npm install -g "npm@${NPM_VERSION}" \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
                      "@openai/codex@${CODEX_VERSION}" \
    && userdel -r node \
    && (getent group "${AGENT_GID}" >/dev/null || groupadd -g "${AGENT_GID}" agent) \
    && useradd -m -u "${AGENT_UID}" -g "${AGENT_GID}" -s /bin/bash agent \
    && groupadd -r agentmill-reviewer \
    && useradd -m -r -g agentmill-reviewer -s /bin/bash agentmill-reviewer \
    && mkdir -p /run/agentmill \
    && chown "root:$(id -gn agent)" /run/agentmill \
    && chmod 2750 /run/agentmill

# Keep the evaluator's fixed trusted paths independent of Alpine's /bin layout.
RUN ln -s /bin/tar /usr/bin/tar && ln -s /bin/chmod /usr/bin/chmod

# The docker CLI, so --dind's DOCKER_HOST is actually usable by the agent.
RUN curl -fsSL "https://download.docker.com/linux/static/stable/$(uname -m)/docker-${DOCKER_CLI_VERSION}.tgz" \
        | tar -xzC /usr/local/bin --strip-components=1 docker/docker \
    && docker --version

WORKDIR /workspace
# AGENT_GID may already belong to a differently named base-image group. Resolve
# the user's primary group instead of assuming the fallback `agent` group was
# created above.
RUN chown "agent:$(id -gn agent)" /workspace
COPY loop.sh /loop.sh
COPY run_state.py /run_state.py
COPY landlock_exec.py /usr/local/bin/landlock-exec
COPY reviewer_control.py /usr/local/bin/agentmill-reviewer-control
COPY reviewer_exec.sh /usr/local/bin/agentmill-reviewer-exec
COPY reviewer_rpc.py /usr/local/bin/reviewer-rpc
COPY supervisor.py /usr/local/bin/agentmill-supervisor
RUN chmod 755 /loop.sh /usr/local/bin/landlock-exec \
        /usr/local/bin/agentmill-reviewer-control \
        /usr/local/bin/agentmill-reviewer-exec /usr/local/bin/reviewer-rpc \
        /usr/local/bin/agentmill-supervisor

USER agent
# Skip onboarding; bypassPermissions is intentional — the container is the boundary.
RUN mkdir -p /home/agent/.claude \
    && echo '{"hasCompletedOnboarding":true}' > /home/agent/.claude.json \
    && echo '{"permissions":{"defaultMode":"bypassPermissions"}}' > /home/agent/.claude/settings.json

# Root runs only the fixed supervisor, which drops credentials before any
# worker/reviewer command. mill grants it only SETUID, SETGID, and KILL.
USER root
ENV HOME=/home/agent
ENTRYPOINT ["/usr/bin/python3", "-I", "/usr/local/bin/agentmill-supervisor"]
