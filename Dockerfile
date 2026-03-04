FROM node:20-slim

RUN apt-get update && apt-get install -y \
    git \
    bash \
    curl \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

WORKDIR /workspace

# Entrypoints
COPY entrypoint.sh /entrypoint.sh
COPY entrypoint-tui.sh /entrypoint-tui.sh
RUN chmod +x /entrypoint.sh /entrypoint-tui.sh

# Default: headless pipe mode. Use entrypoint-tui.sh for TUI dashboard.
ENTRYPOINT ["/entrypoint.sh"]
