#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="failed"
export ITERATION="2"
export AGENTMILL_RUN_ID="failed-test"
export AGENTMILL_PROFILE_LEVEL="standard"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

emit_iteration_failed claude_exit error "exit=42" 42 3 1

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(events) == 1, events
event = events[0]

assert event["type"] == "iteration.failed", event
assert event["run_id"] == "failed-test"
assert event["agent_id"] == "failed"
assert event["profile"] == "standard"
assert event["iteration"] == 2
assert event["payload"]["reason"] == "claude_exit"
assert event["payload"]["status"] == "error"
assert event["payload"]["description"] == "exit=42"
assert event["payload"]["exit_code"] == 42
assert event["payload"]["files_changed"] == 3
assert event["payload"]["commits"] == 1
PY

grep -q 'emit_iteration_failed "claude_exit"' "$REPO_ROOT/entrypoint.sh"
grep -q 'emit_iteration_failed "push_failed"' "$REPO_ROOT/entrypoint.sh"
grep -q 'emit_iteration_failed "pre_iteration_${HOOK_LAST_DECISION:-denied}"' "$REPO_ROOT/entrypoint-tui.sh"

echo "PASS test_iteration_failed_events"
