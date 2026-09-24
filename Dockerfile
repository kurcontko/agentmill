FROM node:24-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6
COPY --from=ghcr.io/astral-sh/uv:0.8.17 /uv /uvx /usr/local/bin/

# Pinned native CLIs. Model aliases such as `opus` resolve inside the pinned CLI,
# so bump these (and re-run tests/smoke_native_clis.py) to pick up new models.
ARG CLAUDE_CODE_VERSION=2.1.281
ARG CODEX_VERSION=0.156.1

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

WORKDIR /workspace
# uv must not replace a macOS/host virtualenv in a bind-mounted checkout.
ENV UV_PROJECT_ENVIRONMENT=/tmp/agentmill-venv
RUN chown agent:agent /workspace

USER agent

# The host supervisor selects each container command and supplies native settings.
CMD ["bash"]
