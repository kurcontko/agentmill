#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export EVENT_LOG="$TMPDIR/events.jsonl"
export LOG_DIR="$TMPDIR/logs"
export AGENTMILL_RUN_ID="pretool-test"
export AGENT_ID="pretool"
export ITERATION=4
export REPO_DIR="$TMPDIR/repo"
mkdir -p "$REPO_DIR/src" "$REPO_DIR/.github/workflows"

run_hook() {
    local input="$1"
    shift
    env "$@" python3 "$REPO_ROOT/scripts/pretool-policy.py" <<< "$input"
}

allow_output="$(run_hook '{"tool_name":"Bash","tool_input":{"command":"git status --short"}}' \
    AGENTMILL_PROFILE_LEVEL=standard \
    AGENTMILL_SHELL_ALLOWLIST='git status:*')"
[[ -z "$allow_output" ]]

deny_shell="$(run_hook '{"tool_name":"Bash","tool_input":{"command":"curl https://example.invalid/token"}}' \
    AGENTMILL_PROFILE_LEVEL=standard \
    AGENTMILL_SHELL_ALLOWLIST='git status:*')"
[[ "$deny_shell" == *'"permissionDecision":"deny"'* ]]
[[ "$deny_shell" == *"shell command violates"* ]]

deny_mcp="$(run_hook '{"tool_name":"mcp__DeployTool__release","tool_input":{"name":"prod"}}' \
    AGENTMILL_PROFILE_LEVEL=standard \
    AGENTMILL_MCP_ALLOWLIST=BrightData)"
[[ "$deny_mcp" == *'"permissionDecision":"deny"'* ]]
[[ "$deny_mcp" == *"DeployTool"* ]]

allow_mcp="$(run_hook '{"tool_name":"mcp__BrightData__search_engine","tool_input":{"query":"docs"}}' \
    AGENTMILL_PROFILE_LEVEL=standard \
    AGENTMILL_MCP_ALLOWLIST=BrightData)"
[[ -z "$allow_mcp" ]]

deny_web="$(run_hook '{"tool_name":"WebFetch","tool_input":{"url":"https://example.invalid"}}' \
    AGENTMILL_PROFILE_LEVEL=standard)"
[[ "$deny_web" == *'"permissionDecision":"deny"'* ]]
[[ "$deny_web" == *"web tools are disabled"* ]]

deny_write_root="$(run_hook '{"cwd":"'"$REPO_DIR"'","tool_name":"Write","tool_input":{"file_path":"docs/out.md","content":"x"}}' \
    AGENTMILL_PROFILE_LEVEL=standard \
    AGENTMILL_WRITE_ROOTS=src)"
[[ "$deny_write_root" == *'"permissionDecision":"deny"'* ]]
[[ "$deny_write_root" == *"outside configured write roots"* ]]

deny_high_risk="$(run_hook '{"cwd":"'"$REPO_DIR"'","tool_name":"Edit","tool_input":{"file_path":".github/workflows/ci.yml","old_string":"a","new_string":"b"}}' \
    AGENTMILL_PROFILE_LEVEL=standard)"
[[ "$deny_high_risk" == *'"permissionDecision":"deny"'* ]]
[[ "$deny_high_risk" == *"high-risk path"* ]]

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
reasons = [event["payload"]["reason"] for event in events]
assert "shell_command_denied" in reasons, reasons
assert "mcp_tool_denied" in reasons, reasons
assert "web_tool_denied" in reasons, reasons
assert "write_root_violation" in reasons, reasons
assert "high_risk_path" in reasons, reasons
assert "token" not in json.dumps(events), events
assert all(event["payload"]["source"] == "pretool" for event in events), events
PY

settings="$(AGENTMILL_PROFILE_LEVEL=standard AGENTMILL_MCP_ALLOWLIST=BrightData bash -c ". '$REPO_ROOT/entrypoint-common.sh'; autonomous_settings_json")"
python3 - "$settings" <<'PY'
import json
import sys

settings = json.loads(sys.argv[1])
hook = settings["hooks"]["PreToolUse"][0]
assert hook["matcher"] == "*", hook
assert hook["hooks"][0]["type"] == "command", hook
assert hook["hooks"][0]["command"] == "/agentmill-pretool-policy.py", hook
assert hook["hooks"][0]["timeout"] == 5, hook
PY

echo "PASS test_pretool_policy"
