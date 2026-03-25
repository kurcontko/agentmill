#!/usr/bin/env bash
set -euo pipefail

# AgentMill CLI installer
# Usage: curl -fsSL https://raw.githubusercontent.com/kurcontko/autonomous-agents/main/install.sh | bash

INSTALL_DIR="${1:-/usr/local/bin}"
REPO_URL="https://raw.githubusercontent.com/kurcontko/autonomous-agents/main/bin/agentmill"

echo "Installing agentmill to $INSTALL_DIR..."

if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "error: $INSTALL_DIR does not exist" >&2
    exit 1
fi

if [[ ! -w "$INSTALL_DIR" ]]; then
    echo "error: $INSTALL_DIR is not writable (try: sudo bash -s -- $INSTALL_DIR)" >&2
    exit 1
fi

curl -fsSL "$REPO_URL" -o "$INSTALL_DIR/agentmill"
chmod +x "$INSTALL_DIR/agentmill"

echo "agentmill installed to $INSTALL_DIR/agentmill"
echo "Run 'agentmill --help' to get started."
