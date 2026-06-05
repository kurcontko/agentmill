#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="tool-class-policy"
export ITERATION="1"
export AGENTMILL_RUN_ID="tool-class-policy-test"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

allowed_log="$TMPDIR/allowed.jsonl"
cat > "$allowed_log" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"mcp_ok","name":"mcp__BrightData__search_engine","input":{"query":"secret-query-allowed"}}]}}
JSONL

AGENTMILL_PROFILE_LEVEL=standard \
AGENTMILL_CLIENT=opencode \
AGENTMILL_MCP_ALLOWLIST=BrightData \
enforce_tool_class_policy_from_session "$allowed_log"

standard_denied_log="$TMPDIR/standard-denied.jsonl"
cat > "$standard_denied_log" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"web_bad","name":"WebFetch","input":{"url":"https://example.invalid/secret-query-web"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"mcp_bad","name":"mcp__DeployTool__release","input":{"target":"prod-secret"}}]}}
{"stats":{"tools":{"byName":{"google_web_search":{"count":2,"durationMs":25}}}}}
JSONL

set +e
AGENTMILL_PROFILE_LEVEL=standard \
AGENTMILL_CLIENT=gemini \
AGENTMILL_MCP_ALLOWLIST=BrightData \
enforce_tool_class_policy_from_session "$standard_denied_log"
standard_rc=$?
set -e
[[ "$standard_rc" -ne 0 ]] || { echo "expected standard profile tool-class denial" >&2; exit 1; }

untrusted_log="$TMPDIR/untrusted.jsonl"
cat > "$untrusted_log" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"task_bad","name":"Task","input":{"prompt":"secret-query-subagent"}}]}}
JSONL

set +e
AGENTMILL_PROFILE_LEVEL=untrusted \
AGENTMILL_CLIENT=codex \
AGENTMILL_MCP_ALLOWLIST= \
enforce_tool_class_policy_from_session "$untrusted_log"
untrusted_rc=$?
set -e
[[ "$untrusted_rc" -ne 0 ]] || { echo "expected untrusted subagent denial" >&2; exit 1; }

trusted_log="$TMPDIR/trusted.jsonl"
cat > "$trusted_log" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"web_ok","name":"WebSearch","input":{"query":"secret-query-trusted"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"task_ok","name":"Task","input":{"prompt":"secret-query-trusted-subagent"}}]}}
JSONL

AGENTMILL_PROFILE_LEVEL=trusted \
AGENTMILL_CLIENT=claude \
enforce_tool_class_policy_from_session "$trusted_log"

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
denied = [event["payload"] for event in events if event["type"] == "policy.denied"]
reasons = [payload["reason"] for payload in denied]

assert reasons.count("web_tool_denied") == 2, reasons
assert "mcp_tool_denied" in reasons, reasons
assert "subagent_denied" in reasons, reasons

mcp = next(payload for payload in denied if payload["reason"] == "mcp_tool_denied")
assert mcp["mcp_server"] == "DeployTool", mcp
assert mcp["mcp_allowlist"] == "BrightData", mcp
assert mcp["source"] == "post_session_tool_policy", mcp

web = [payload for payload in denied if payload["reason"] == "web_tool_denied"]
assert {payload["tool_name"] for payload in web} == {"WebFetch", "google_web_search"}, web

subagent = next(payload for payload in denied if payload["reason"] == "subagent_denied")
assert subagent["tool_name"] == "Task", subagent
assert "secret-query" not in json.dumps(denied), denied
PY

grep -q 'enforce_tool_class_policy_from_session "$SESSION_LOG"' "$REPO_ROOT/entrypoint.sh"
grep -q 'enforce_tool_class_policy_from_session "$SESSION_LOG"' "$REPO_ROOT/entrypoint-tui.sh"

echo "PASS test_tool_class_policy"
