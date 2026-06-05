#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="opencode"
export AGENTMILL_RUN_ID="opencode-test"
export AGENTMILL_CLIENT=opencode
export AGENTMILL_PROFILE_LEVEL=standard
export AGENTMILL_NETWORK=deny
export AGENTMILL_MCP_ALLOWLIST=BrightData
export AGENTMILL_WRITE_ROOTS=src,tests
export MODEL="anthropic/claude-sonnet-4-5"
export REPO_DIR="$TMPDIR/repo"
export DONE_FILE="$TMPDIR/done"
export ANTHROPIC_API_KEY="test-key"
export BWRAP_ARGS_LOG="$TMPDIR/bwrap-args.log"

mkdir -p "$HOME" "$REPO_DIR" "$TMPDIR/bin"
cat > "$TMPDIR/bin/bwrap" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" > "${BWRAP_ARGS_LOG:?}"
cwd=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --chdir)
            cwd="${2:?}"
            shift 2
            ;;
        --)
            shift
            [[ -n "$cwd" ]] && cd "$cwd"
            exec "$@"
            ;;
        *)
            shift
            ;;
    esac
done
echo "missing bwrap command delimiter" >&2
exit 99
SH
chmod +x "$TMPDIR/bin/bwrap"
export AGENTMILL_BWRAP_COMMAND="$TMPDIR/bin/bwrap"

cat > "$TMPDIR/bin/opencode" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
    echo "opencode 0.6.6"
    exit 0
fi

printf '%s\n' "$@" > "${OPENCODE_ARGS_LOG:?}"
printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG:-}" >> "${OPENCODE_ARGS_LOG:?}"
printf 'OPENCODE_CONFIG_DIR=%s\n' "${OPENCODE_CONFIG_DIR:-}" >> "${OPENCODE_ARGS_LOG:?}"
printf 'OPENCODE_DISABLE_AUTOUPDATE=%s\n' "${OPENCODE_DISABLE_AUTOUPDATE:-}" >> "${OPENCODE_ARGS_LOG:?}"
printf 'OPENCODE_DISABLE_CLAUDE_CODE=%s\n' "${OPENCODE_DISABLE_CLAUDE_CODE:-}" >> "${OPENCODE_ARGS_LOG:?}"
printf '{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"echo hi"}}\n'
printf '{"type":"tool_result","tool_use_id":"tool-1","status":"completed"}\n'
touch "${DONE_FILE:?}"
SH
chmod +x "$TMPDIR/bin/opencode"
export AGENTMILL_OPENCODE_COMMAND="$TMPDIR/bin/opencode"
export OPENCODE_ARGS_LOG="$TMPDIR/opencode-args.log"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

client_select opencode
client_version "$MODEL"
client_require_auth
client_prepare_home

[[ "$AGENTMILL_CLIENT_HOME" == "$HOME/.agentmill/clients/opencode" ]]
[[ "$OPENCODE_CONFIG" == "$AGENTMILL_CLIENT_HOME/opencode.json" ]]
[[ -f "$OPENCODE_CONFIG" ]]

python3 - "$OPENCODE_CONFIG" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
assert config["model"] == "anthropic/claude-sonnet-4-5", config
assert config["autoupdate"] is False, config
assert config["share"] == "disabled", config
assert config["permission"]["edit"] == "allow", config
assert config["permission"]["bash"] == "ask", config
assert config["permission"]["webfetch"] == "deny", config
assert config["permission"]["websearch"] == "deny", config
assert config["agentmill_policy"]["client"] == "opencode", config
assert config["agentmill_policy"]["network"] == "deny", config
assert "git push:*" in config["agentmill_policy"]["shell"]["deny"], config
assert config["agentmill_mcp_allowlist"] == ["BrightData"], config
PY

session_log="$TMPDIR/session.jsonl"
client_run_headless "write a file" "$session_log"
rc=$?
[[ "$rc" -eq 0 ]]
[[ -f "$DONE_FILE" ]]
grep -Fx 'run' "$OPENCODE_ARGS_LOG"
grep -Fx -- '--format' "$OPENCODE_ARGS_LOG"
grep -Fx 'json' "$OPENCODE_ARGS_LOG"
grep -Fx -- '--dir' "$OPENCODE_ARGS_LOG"
grep -Fx "$REPO_DIR" "$OPENCODE_ARGS_LOG"
grep -Fx -- '--model' "$OPENCODE_ARGS_LOG"
grep -Fx "$MODEL" "$OPENCODE_ARGS_LOG"
grep -Fx "OPENCODE_CONFIG=$OPENCODE_CONFIG" "$OPENCODE_ARGS_LOG"
grep -Fx "OPENCODE_CONFIG_DIR=$AGENTMILL_CLIENT_HOME" "$OPENCODE_ARGS_LOG"
grep -Fx "OPENCODE_DISABLE_AUTOUPDATE=true" "$OPENCODE_ARGS_LOG"
grep -Fx "OPENCODE_DISABLE_CLAUDE_CODE=true" "$OPENCODE_ARGS_LOG"
grep -Fx -- '--ro-bind' "$BWRAP_ARGS_LOG"
grep -Fx "$REPO_DIR" "$BWRAP_ARGS_LOG"
grep -Fx -- '--bind' "$BWRAP_ARGS_LOG"
grep -Fx "$REPO_DIR/src" "$BWRAP_ARGS_LOG"
grep -Fx "$REPO_DIR/tests" "$BWRAP_ARGS_LOG"
grep -Fx -- '--chdir' "$BWRAP_ARGS_LOG"
grep -Fx -- '--' "$BWRAP_ARGS_LOG"

record_tool_events_from_session 1 opencode "$session_log"
python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert any(event["type"] == "policy.allowed" and event["payload"]["reason"] == "write_root_filesystem_sandbox" for event in events), events
tool = next(event for event in events if event["type"] == "tool.invoked")
assert tool["payload"]["client"] == "opencode", tool
assert tool["payload"]["provider"] == "opencode_json", tool
completed = next(event for event in events if event["type"] == "tool.completed")
assert completed["payload"]["client"] == "opencode", completed
PY

grep -q 'ARG OPENCODE_VERSION=0.6.6' "$REPO_ROOT/Dockerfile"
grep -q '"opencode-ai@${OPENCODE_VERSION}"' "$REPO_ROOT/Dockerfile"

echo "PASS test_opencode_adapter"
