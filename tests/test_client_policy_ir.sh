#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

trusted="$(AGENTMILL_PROFILE_LEVEL=trusted AGENTMILL_CLIENT=claude client_policy_ir_json)"
standard="$(AGENTMILL_PROFILE_LEVEL=standard AGENTMILL_CLIENT=opencode AGENTMILL_MCP_ALLOWLIST=BrightData,GitHub AGENTMILL_NETWORK=deny client_policy_ir_json)"
standard_allow="$(AGENTMILL_PROFILE_LEVEL=standard AGENTMILL_CLIENT=claude AGENTMILL_SHELL_ALLOWLIST='git status:*,make test:*' client_policy_ir_json)"
untrusted="$(AGENTMILL_PROFILE_LEVEL=untrusted AGENTMILL_CLIENT=codex client_policy_ir_json)"

python3 - "$trusted" "$standard" "$standard_allow" "$untrusted" <<'PY'
import json
import sys

trusted = json.loads(sys.argv[1])
standard = json.loads(sys.argv[2])
standard_allow = json.loads(sys.argv[3])
untrusted = json.loads(sys.argv[4])

assert trusted["client"] == "claude"
assert trusted["profile"] == "trusted"
assert trusted["shell"]["default"] == "allow"
assert trusted["web"]["default"] == "allow"
assert trusted["mcp"]["default"] == "allow"
assert trusted["project_config"]["import_host"] is True

assert standard["client"] == "opencode"
assert standard["profile"] == "standard"
assert standard["network"] == "deny"
assert standard["web"]["default"] == "deny"
assert standard["mcp"]["default"] == "allowlist"
assert standard["mcp"]["allowlist"] == ["BrightData", "GitHub"]
assert "git push:*" in standard["shell"]["deny"]
assert "npm install:*" in standard["shell"]["deny"]
assert "curl:*" in standard["shell"]["deny"]
assert standard["project_config"]["import_host"] is False
assert standard["project_config"]["allow_project_local"] is True

assert standard_allow["shell"]["default"] == "allowlist"
assert standard_allow["shell"]["allow"] == ["git status:*", "make test:*"]
assert "sudo:*" in standard_allow["shell"]["deny"]
assert standard_allow["web"]["default"] == "deny"

assert untrusted["client"] == "codex"
assert untrusted["profile"] == "untrusted"
assert untrusted["edit"]["default"] == "ask"
assert untrusted["shell"]["default"] == "deny"
assert untrusted["web"]["default"] == "deny"
assert untrusted["mcp"]["default"] == "deny"
assert untrusted["subagent"]["default"] == "deny"
assert untrusted["project_config"]["allow_project_local"] is False
PY

echo "PASS test_client_policy_ir"
