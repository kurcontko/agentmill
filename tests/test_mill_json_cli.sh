#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
mkdir -p "$harness/logs"
cp "$REPO_ROOT/mill" "$harness/mill"
chmod +x "$harness/mill"

cat > "$harness/logs/status-1.json" <<'JSON'
{"agent":"1","iteration":2,"max_iterations":5,"state":"running","detail":"working","timestamp":"2026-05-29T00:00:00Z"}
JSON

cat > "$harness/logs/results.tsv" <<'TSV'
iteration	agent	timestamp	files_changed	commits	status	description
1	1	2026-05-29T00:00:00Z	2	1	kept	exit=0
2	1	2026-05-29T00:01:00Z	0	0	noop	exit=0
3	2	2026-05-29T00:02:00Z	1	0	error	exit=1
TSV

cat > "$harness/logs/events.jsonl" <<'JSONL'
{"agent_id":"1","iteration":1,"run_id":"run-a","type":"iteration.completed"}
{"agent_id":"2","iteration":3,"run_id":"run-a","type":"iteration.failed"}
JSONL

status_json="$("$harness/mill" status --json)"
history_json="$("$harness/mill" history --json --tail 1)"
filtered_history_json="$("$harness/mill" history --json --since 2026-05-29T00:01:30Z --agent 2 --failed-only)"
tail_json="$("$harness/mill" tail --json --tail 1 --no-follow)"

python3 - "$status_json" "$history_json" "$filtered_history_json" "$tail_json" <<'PY'
import json
import sys

status = json.loads(sys.argv[1])
history = json.loads(sys.argv[2])
filtered_history = json.loads(sys.argv[3])
tail_event = json.loads(sys.argv[4])

assert len(status) == 1, status
assert status[0]["agent"] == "1"
assert status[0]["iteration"] == 2
assert status[0]["state"] == "running"
assert status[0]["file"].endswith("status-1.json")

assert len(history) == 1, history
assert history[0]["iteration"] == 3
assert history[0]["files_changed"] == 1
assert history[0]["commits"] == 0
assert history[0]["status"] == "error"

assert len(filtered_history) == 1, filtered_history
assert filtered_history[0]["agent"] == "2"
assert filtered_history[0]["status"] == "error"

assert tail_event["agent_id"] == "2"
assert tail_event["type"] == "iteration.failed"
PY

filtered_history_text="$("$harness/mill" history --since 2026-05-29T00:01:30Z --agent 2 --failed-only)"
[[ "$filtered_history_text" == *"error"* ]] || { echo "expected filtered text history to include error row" >&2; exit 1; }
[[ "$filtered_history_text" != *"kept"* ]] || { echo "filtered text history included kept row" >&2; exit 1; }

echo "PASS test_mill_json_cli"
