#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="acp"
export AGENTMILL_RUN_ID="acp-test"
export AGENTMILL_CLIENT=opencode
export AGENTMILL_CLIENT_TRANSPORT=acp
export AGENTMILL_PROFILE_LEVEL=standard
export AGENTMILL_WRITE_ROOTS=src
export AGENTMILL_OPENCODE_REQUIRE_AUTH=false
export AGENTMILL_ACP_BRIDGE="$REPO_ROOT/scripts/acp-stdio-bridge.py"
export REPO_DIR="$TMPDIR/repo"
export DONE_FILE="$TMPDIR/done"
export ACP_MESSAGES_LOG="$TMPDIR/acp-messages.jsonl"
export BWRAP_ARGS_LOG="$TMPDIR/bwrap-args.log"

mkdir -p "$HOME" "$REPO_DIR/src" "$TMPDIR/bin"
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

cat > "$TMPDIR/acp-agent.py" <<'PY'
import json
import os
import sys

log = open(os.environ["ACP_MESSAGES_LOG"], "w", encoding="utf-8")
session = "sess-agentmill"
for line in sys.stdin:
    msg = json.loads(line)
    log.write(json.dumps(msg, sort_keys=True) + "\n")
    log.flush()
    method = msg.get("method")
    if method == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}}), flush=True)
    elif method == "session/new":
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": session}}), flush=True)
    elif method == "session/prompt":
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": {"sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Bash", "kind": "execute", "status": "pending"}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": {"sessionUpdate": "tool_call_update", "toolCallId": "tool-1", "status": "completed"}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": "end_turn"}}), flush=True)
        open(os.environ["DONE_FILE"], "w", encoding="utf-8").write("done\n")
        break
PY

cat > "$TMPDIR/bin/opencode" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
    echo "opencode 0.6.6"
    exit 0
fi
if [[ "${1:-}" != "acp" ]]; then
    echo "expected acp subcommand" >&2
    exit 2
fi

python3 "${ACP_AGENT_SCRIPT:?}"
SH
chmod +x "$TMPDIR/bin/opencode"
export AGENTMILL_OPENCODE_COMMAND="$TMPDIR/bin/opencode"
export ACP_AGENT_SCRIPT="$TMPDIR/acp-agent.py"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

client_select opencode
MODEL="$(client_resolve_model sonnet)"
client_require_auth
client_prepare_home

export CLAUDE_INITIAL_PROMPT="hello over acp"
client_run_tui

acp_log="$LOG_DIR/acp-${AGENT_ID}-iter0.jsonl"
[[ -f "$DONE_FILE" ]]
[[ -f "$acp_log" ]]
grep -Fx -- '--ro-bind' "$BWRAP_ARGS_LOG"
grep -Fx "$REPO_DIR" "$BWRAP_ARGS_LOG"
grep -Fx "$REPO_DIR/src" "$BWRAP_ARGS_LOG"
grep -Fx -- '--chdir' "$BWRAP_ARGS_LOG"
grep -Fx -- '--' "$BWRAP_ARGS_LOG"

python3 - "$ACP_MESSAGES_LOG" <<'PY'
import json
import sys

messages = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [m["method"] for m in messages] == ["initialize", "session/new", "session/prompt"], messages
prompt = messages[-1]["params"]["prompt"][0]["text"]
assert prompt == "hello over acp", messages[-1]
assert messages[0]["params"]["clientCapabilities"]["terminal"] is False, messages[0]
assert messages[0]["params"]["clientCapabilities"]["fs"]["writeTextFile"] is False, messages[0]
PY

record_tool_events_from_session 1 acp "$acp_log"
python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert any(event["type"] == "policy.allowed" and event["payload"]["reason"] == "write_root_filesystem_sandbox" for event in events), events
started = next(event for event in events if event["type"] == "acp.started")
assert started["payload"]["client"] == "opencode", started
tool = next(event for event in events if event["type"] == "tool.invoked")
assert tool["payload"]["provider"] == "acp_json", tool
assert tool["payload"]["tool_name"] == "Bash", tool
completed = next(event for event in events if event["type"] == "tool.completed")
assert completed["payload"]["status"] == "completed", completed
PY

echo "PASS test_acp_transport"
