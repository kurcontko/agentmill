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
1	1	2026-05-29T00:00:00Z	2	1	kept	done
TSV

output="$("$harness/mill" watch-status --once)"
[[ "$output" == *"AgentMill status"* ]]
[[ "$output" == *"1         2/5"* ]]
[[ "$output" == *"Recent history"* ]]
[[ "$output" == *"kept"* ]]

echo "PASS test_mill_watch_status"
