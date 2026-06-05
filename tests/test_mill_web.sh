#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
mkdir -p "$harness/logs"
cp "$REPO_ROOT/mill" "$harness/"
chmod +x "$harness/mill"

cat > "$harness/logs/status-1.json" <<'JSON'
{"agent":"1","iteration":2,"max_iterations":3,"state":"running","detail":"working","timestamp":"2026-05-29T00:01:00Z"}
JSON

cat > "$harness/logs/results.tsv" <<'TSV'
iteration	agent	timestamp	files_changed	commits	status	description	input_tokens	output_tokens	cache_creation_input_tokens	cache_read_input_tokens	total_tokens	cost_usd
1	1	2026-05-29T00:00:00Z	1	1	kept	exit=0	10	5	0	0	15	0.01
2	1	2026-05-29T00:01:00Z	0	0	push_failed	push_failed	10	5	0	0	15	0.02
TSV

cat > "$harness/logs/usage.tsv" <<'TSV'
iteration	agent	timestamp	input_tokens	output_tokens	cache_creation_input_tokens	cache_read_input_tokens	total_tokens	cost_usd
1	1	2026-05-29T00:00:00Z	10	5	0	0	15	0.01
2	1	2026-05-29T00:01:00Z	10	5	0	0	15	0.02
TSV

cat > "$harness/logs/events.jsonl" <<'JSONL'
{"version":1,"timestamp":"2026-05-29T00:00:00Z","run_id":"web-test","agent_id":"1","iteration":1,"type":"iteration.started","payload":{"prompt_file":"/prompts/PROMPT.md"}}
{"version":1,"timestamp":"2026-05-29T00:01:00Z","run_id":"web-test","agent_id":"1","iteration":2,"type":"push.failed","payload":{"reason":"retry limit reached"}}
JSONL

output="$("$harness/mill" web --no-serve)"
html="$harness/logs/index.html"

[[ "$output" == *"Wrote $html"* ]]
[[ -f "$html" ]]
grep -q 'AgentMill Dashboard' "$html"
grep -q 'push.failed' "$html"
grep -q 'retry limit reached' "$html"
grep -q '<strong>2</strong>' "$html"

set +e
bad_output="$("$harness/mill" web --port bad --no-serve 2>&1)"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]]
[[ "$bad_output" == *"--port must be a positive integer"* ]]

echo "PASS test_mill_web"
