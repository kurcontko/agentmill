#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
mkdir -p "$harness/logs"
cp "$REPO_ROOT/mill" "$harness/mill"
chmod +x "$harness/mill"

cat > "$harness/logs/results.tsv" <<'TSV'
iteration	agent	timestamp	files_changed	commits	status	description
1	1	2026-05-29T00:00:00Z	1	1	kept	done
2	1	2026-05-29T00:01:00Z	0	0	error	exit=1
TSV

cat > "$harness/logs/usage.tsv" <<'TSV'
iteration	agent	timestamp	input_tokens	output_tokens	cache_creation_input_tokens	cache_read_input_tokens	total_tokens	cost_usd
1	1	2026-05-29T00:00:00Z	100	20	50	50	220	0.010000
TSV

cat > "$harness/logs/status-1.json" <<'JSON'
{"agent":"1","iteration":2,"state":"running"}
JSON

metrics_path="$("$harness/mill" metrics)"
[[ "$metrics_path" == "$harness/logs/metrics.prom" ]]

grep -q 'agentmill_results_iterations_total{agent="1",status="kept"} 1' "$metrics_path"
grep -q 'agentmill_results_iterations_total{agent="1",status="error"} 1' "$metrics_path"
grep -q 'agentmill_usage_total_tokens{agent="1"} 220' "$metrics_path"
grep -q 'agentmill_usage_cost_usd{agent="1"} 0.010000' "$metrics_path"
grep -q 'agentmill_cache_read_ratio{agent="1"} 0.250000' "$metrics_path"
grep -q 'agentmill_status_iteration{agent="1",state="running"} 2' "$metrics_path"

echo "PASS test_mill_metrics"
