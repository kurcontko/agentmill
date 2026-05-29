#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="tools"
export ITERATION="5"
export AGENTMILL_RUN_ID="tool-events-test"
export AGENTMILL_PROFILE_LEVEL="standard"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

session_log="$TMPDIR/session.jsonl"
cat > "$session_log" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_bash","name":"Bash","input":{"command":"echo sk-ant-secret1234567890","description":"do not leak full args"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_bash","content":"ok","is_error":false}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_mcp","name":"mcp__BrightData__search_engine","input":{"query":"secret research term"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_mcp","content":[{"text":"ok"}],"is_error":false}]}}
{"type":"item.started","item":{"type":"command_execution","id":"cmd1","command":"pytest -q"}}
{"type":"item.completed","item":{"type":"command_execution","id":"cmd1","status":"completed","exit_code":0}}
JSONL

record_tool_events_from_session 5 tools "$session_log"
[[ "$TOOL_EVENTS_LAST_COUNT" == 6 ]]

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
types = [event["type"] for event in events]

assert types.count("tool.invoked") == 2, types
assert types.count("tool.completed") == 2, types
assert types.count("mcp.tool.invoked") == 1, types
assert types.count("mcp.tool.completed") == 1, types
assert types.count("tool.summary") == 1, types

invoked = [event for event in events if event["type"] == "tool.invoked"]
bash = next(event for event in invoked if event["payload"]["tool_id"] == "toolu_bash")
assert bash["payload"]["tool_name"] == "Bash"
assert bash["payload"]["input_keys"] == ["command", "description"]
assert "input_hash" in bash["payload"]
assert "echo sk-ant-secret" not in json.dumps(bash), bash

mcp = next(event for event in events if event["type"] == "mcp.tool.invoked")
assert mcp["payload"]["mcp_server"] == "BrightData"
assert mcp["payload"]["mcp_tool"] == "search_engine"
assert "secret research term" not in json.dumps(mcp), mcp

summary = next(event for event in events if event["type"] == "tool.summary")
assert summary["payload"]["invoked"] == 2, summary
assert summary["payload"]["completed"] == 2, summary
assert summary["payload"]["mcp_invoked"] == 1, summary
assert summary["payload"]["mcp_completed"] == 1, summary
assert summary["payload"]["total"] == 6, summary
PY

grep -q 'record_tool_events_from_session "$ITERATION" "$AGENT_ID"' "$REPO_ROOT/entrypoint.sh"

echo "PASS test_tool_events"
