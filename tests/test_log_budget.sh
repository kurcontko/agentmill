#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="logbudget"
export ITERATION="1"
export AGENTMILL_RUN_ID="log-budget-test"
export AGENTMILL_PROFILE_LEVEL="standard"
export MAX_ITERATIONS="1"
export MAX_WALL_SECONDS="0"
export MAX_LOG_BYTES="32"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

validate_runtime_policy headless >/dev/null

mkdir -p "$LOG_DIR"
printf '0123456789012345678901234567890123456789\n' > "$LOG_DIR/session.log"

if enforce_log_budget >/dev/null; then
    echo "expected log budget to be exhausted" >&2
    exit 1
fi

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1])]
budget_events = [event for event in events if event["type"] == "budget.exhausted"]
assert budget_events, events
event = budget_events[-1]
assert event["payload"]["budget"] == "log_bytes"
assert event["payload"]["max_log_bytes"] == 32
assert event["payload"]["used_bytes"] >= 32
PY

echo "PASS test_log_budget"
