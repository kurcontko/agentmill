#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="policy"
export ITERATION="0"
export AGENTMILL_RUN_ID="policy-test"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

assert_allows() {
    local profile="$1" mode="$2" max_iterations="$3" max_wall="$4" respawn="${5:-false}" max_log="${6:-0}"
    AGENTMILL_PROFILE_LEVEL="$profile" MAX_ITERATIONS="$max_iterations" MAX_WALL_SECONDS="$max_wall" MAX_LOG_BYTES="$max_log" RESPAWN="$respawn" \
        validate_runtime_policy "$mode" >/dev/null
}

assert_denies() {
    local profile="$1" mode="$2" max_iterations="$3" max_wall="$4" respawn="${5:-false}" max_log="${6:-0}"
    if AGENTMILL_PROFILE_LEVEL="$profile" MAX_ITERATIONS="$max_iterations" MAX_WALL_SECONDS="$max_wall" MAX_LOG_BYTES="$max_log" RESPAWN="$respawn" \
        validate_runtime_policy "$mode" >/dev/null; then
        echo "expected policy denial for profile=$profile mode=$mode max_iterations=$max_iterations max_wall=$max_wall respawn=$respawn max_log=$max_log" >&2
        return 1
    fi
}

assert_allows trusted headless 0 0
assert_allows standard headless 1 0
assert_allows standard headless 0 60
assert_allows untrusted tui 0 60 true

assert_denies standard headless 0 0
assert_denies untrusted headless 0 0
assert_denies standard tui 0 0 true
assert_denies invalid headless 1 0
assert_denies trusted headless not-a-number 0
assert_denies trusted headless 1 not-a-number
assert_denies trusted headless 1 0 false not-a-number

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1])]
denied = [event for event in events if event["type"] == "policy.denied"]
allowed = [event for event in events if event["type"] == "policy.allowed"]

assert allowed, events
assert denied, events
assert any(event["payload"]["reason"] == "unbounded_headless_run" for event in denied)
assert any(event["payload"]["reason"] == "unbounded_respawn_run" for event in denied)
assert any(event["payload"]["reason"] == "unknown_profile" for event in denied)
assert any(event["payload"]["reason"] == "invalid_max_log_bytes" for event in denied)
PY

echo "PASS test_runtime_policy"
