#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export CONVERGENCE_LOG="$LOG_DIR/convergence.tsv"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="gate"
export ITERATION="0"
export AGENTMILL_RUN_ID="convergence-test"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

convergence_log_append 2 gate done_file true true true /tmp/.agentmill-done allow
convergence_log_append 3 $'agent\tbad' done_file false false true $'line\nwith\ttabs' deny

python3 - "$CONVERGENCE_LOG" <<'PY'
import csv
import sys

rows = list(csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8"), delimiter="\t"))

assert len(rows) == 2, rows
assert rows[0]["iteration"] == "2"
assert rows[0]["agent"] == "gate"
assert rows[0]["gate"] == "done_file"
assert rows[0]["passed"] == "true"
assert rows[0]["value"] == "true"
assert rows[0]["threshold"] == "true"
assert rows[0]["evidence"] == "/tmp/.agentmill-done"
assert rows[0]["hook_decision"] == "allow"

assert rows[1]["agent"] == "agent bad"
assert rows[1]["evidence"] == "line with tabs"
assert rows[1]["hook_decision"] == "deny"
PY

grep -q 'convergence_log_append "$ITERATION" "$AGENT_ID"' "$REPO_ROOT/entrypoint.sh"
grep -q 'convergence_log_append "$ITERATION" "${AGENT_ID:-tui}"' "$REPO_ROOT/entrypoint-tui.sh"
grep -q 'loop.stopped reason=completion' "$REPO_ROOT/entrypoint.sh"
grep -q 'loop.stopped reason=completion' "$REPO_ROOT/entrypoint-tui.sh"

echo "PASS test_convergence_log"
