#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="7"
export ITERATION="3"
export AGENTMILL_RUN_ID="test-run"
export AGENTMILL_PROFILE_LEVEL="standard"
export ANTHROPIC_API_KEY="sk-ant-testsecret1234567890"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

event_emit_kv iteration.started prompt_file=/prompts/PROMPT.md secret="$ANTHROPIC_API_KEY"
event_emit_kv convergence.evaluated gate=done_file passed=true count=2

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

path = sys.argv[1]
events = [json.loads(line) for line in open(path)]

assert len(events) == 2, events
first, second = events

assert first["version"] == 1
assert first["run_id"] == "test-run"
assert first["agent_id"] == "7"
assert first["profile"] == "standard"
assert first["iteration"] == 3
assert first["type"] == "iteration.started"
assert first["payload"]["prompt_file"] == "/prompts/PROMPT.md"
assert first["payload"]["secret"] == "[REDACTED]"

assert second["type"] == "convergence.evaluated"
assert second["payload"]["passed"] is True
assert second["payload"]["count"] == 2
PY

echo "PASS test_events_jsonl"
