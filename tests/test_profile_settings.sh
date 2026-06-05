#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

check_settings() {
    local profile="$1" allowlist="$2" network="${3:-}"
    AGENTMILL_PROFILE_LEVEL="$profile" AGENTMILL_MCP_ALLOWLIST="$allowlist" AGENTMILL_NETWORK="$network" autonomous_settings_json
}

standard_with_mcp="$(check_settings standard BrightData)"
standard_without_mcp="$(check_settings standard '')"
standard_network_deny="$(check_settings standard '' deny)"
standard_shell_allow="$(AGENTMILL_PROFILE_LEVEL=standard AGENTMILL_SHELL_ALLOWLIST='git status:*,make test:*' autonomous_settings_json)"
untrusted_shell_allow="$(AGENTMILL_PROFILE_LEVEL=untrusted AGENTMILL_SHELL_ALLOWLIST='git status:*' autonomous_settings_json)"
untrusted_without_mcp="$(check_settings untrusted '')"
trusted_settings="$(check_settings trusted '')"

python3 - "$standard_with_mcp" "$standard_without_mcp" "$standard_network_deny" "$standard_shell_allow" "$untrusted_shell_allow" "$untrusted_without_mcp" "$trusted_settings" <<'PY'
import json
import sys

standard_with_mcp = json.loads(sys.argv[1])
standard_without_mcp = json.loads(sys.argv[2])
standard_network_deny = json.loads(sys.argv[3])
standard_shell_allow = json.loads(sys.argv[4])
untrusted_shell_allow = json.loads(sys.argv[5])
untrusted_without_mcp = json.loads(sys.argv[6])
trusted_settings = json.loads(sys.argv[7])

assert standard_with_mcp["enableAllProjectMcpServers"] is True
assert standard_with_mcp["hooks"]["PreToolUse"][0]["matcher"] == "*"
assert standard_with_mcp["hooks"]["PreToolUse"][0]["hooks"][0]["command"] == "/agentmill-pretool-policy.py"
assert "mcp__BrightData__*" in standard_with_mcp["permissions"]["allow"]
assert "mcp__BrightData.*" in standard_with_mcp["permissions"]["allow"]
assert "mcp__*" not in standard_with_mcp["permissions"].get("deny", [])

assert standard_without_mcp["enableAllProjectMcpServers"] is False
assert "mcp__*" in standard_without_mcp["permissions"]["deny"]
assert "WebFetch" in standard_without_mcp["permissions"]["deny"]
assert "Bash(curl:*)" in standard_without_mcp["permissions"]["deny"]
assert "Bash(wget:*)" in standard_without_mcp["permissions"]["deny"]
assert "Bash(sudo:*)" in standard_without_mcp["permissions"]["deny"]
assert "Bash(rm -rf:*)" in standard_without_mcp["permissions"]["deny"]
assert "Bash(git push:*)" not in standard_without_mcp["permissions"]["deny"]

assert "Bash(git push:*)" in standard_network_deny["permissions"]["deny"]
assert "Bash(npm install:*)" in standard_network_deny["permissions"]["deny"]

assert "Bash" not in standard_shell_allow["permissions"]["allow"]
assert "Bash(git status:*)" in standard_shell_allow["permissions"]["allow"]
assert "Bash(make test:*)" in standard_shell_allow["permissions"]["allow"]
assert "Bash(sudo:*)" in standard_shell_allow["permissions"]["deny"]

assert "Bash" not in untrusted_shell_allow["permissions"]["deny"]
assert "Bash(git status:*)" in untrusted_shell_allow["permissions"]["allow"]
assert "Bash(git push:*)" in untrusted_shell_allow["permissions"]["deny"]

assert untrusted_without_mcp["permissions"]["defaultMode"] == "acceptEdits"
assert "PreToolUse" in untrusted_without_mcp["hooks"]
assert "Bash" in untrusted_without_mcp["permissions"]["deny"]
assert "mcp__*" in untrusted_without_mcp["permissions"]["deny"]
assert "Bash(curl:*)" in untrusted_without_mcp["permissions"]["deny"]

assert "Bash(curl:*)" not in trusted_settings["permissions"].get("deny", [])
assert "hooks" not in trusted_settings
PY

echo "PASS test_profile_settings"
