#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
target="$TMPDIR/research/container-escape-cves"
mkdir -p "$harness/prompts"
cp "$REPO_ROOT/mill" "$harness/mill"
cp "$REPO_ROOT/prompts/TASK_TEMPLATE.md" "$harness/prompts/TASK_TEMPLATE.md"
chmod +x "$harness/mill"

output="$("$harness/mill" init --research "Container Escape CVEs" --dir "$target")"
[[ "$output" == *"Research scaffold ready: $target"* ]]

[[ -f "$target/TASK.md" ]]
[[ -f "$target/REPORT.md" ]]
[[ -d "$target/memory" ]]
[[ -d "$target/logs" ]]
[[ -d "$target/.git" ]]

grep -q '# Research: Container Escape CVEs' "$target/TASK.md"
grep -q '## Source-class filters' "$target/TASK.md"
grep -q 'Peer-reviewed papers' "$target/TASK.md"
grep -q '# Research Report: Container Escape CVEs' "$target/REPORT.md"
grep -q '^type: findings$' "$target/memory/findings.md"
grep -q '^type: sources$' "$target/memory/sources.md"
grep -q '^type: open_questions$' "$target/memory/open_questions.md"
grep -q '^type: contradictions$' "$target/memory/contradictions.md"
grep -q '^type: decisions$' "$target/memory/hypotheses.md"
grep -q '^last_iteration: 0$' "$target/memory/sources.md"

printf 'custom report\n' > "$target/REPORT.md"
"$harness/mill" init --research "Container Escape CVEs" --dir "$target" >/tmp/agentmill-init-research-repeat.out
grep -q 'custom report' "$target/REPORT.md"

echo "PASS test_mill_init_research"
