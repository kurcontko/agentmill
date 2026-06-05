#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
mkdir -p "$harness/logs"
cp "$REPO_ROOT/mill" "$harness/mill"
chmod +x "$harness/mill"

cat > "$harness/logs/usage.tsv" <<'TSV'
iteration	agent	timestamp	input_tokens	output_tokens	cache_creation_input_tokens	cache_read_input_tokens	total_tokens	cost_usd
1	1	2026-05-29T00:00:00Z	100	20	50	50	220	0.010000
2	1	2026-05-29T01:00:00Z	10	5	0	90	105	0.005000
1	2	2026-05-30T00:00:00Z	40	10	0	0	50	0.002000
TSV

agent_json="$("$harness/mill" cost --json --by agent)"
day_text="$("$harness/mill" cost --by day)"

python3 - "$agent_json" "$day_text" <<'PY'
import json
import sys

agents = json.loads(sys.argv[1])
day_text = sys.argv[2]

by_agent = {row["group"]: row for row in agents}
assert by_agent["1"]["iterations"] == 2, by_agent
assert by_agent["1"]["total_tokens"] == 325, by_agent
assert by_agent["1"]["cost_usd"] == 0.015, by_agent
assert by_agent["1"]["cache_read_input_tokens"] == 140, by_agent
assert by_agent["1"]["cache_read_ratio"] == 0.466667, by_agent
assert by_agent["2"]["total_tokens"] == 50, by_agent

assert "2026-05-29" in day_text, day_text
assert "2026-05-30" in day_text, day_text
assert "cache_read_ratio" in day_text, day_text
PY

echo "PASS test_mill_cost_cli"
