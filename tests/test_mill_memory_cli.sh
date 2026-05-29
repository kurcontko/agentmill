#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
mkdir -p "$harness/memory"
cp "$REPO_ROOT/mill" "$harness/mill"
chmod +x "$harness/mill"

cat > "$harness/memory/sources.md" <<'MD'
---
agent: a
timestamp: 2026-05-29T00:00:00Z
---
- https://example.com/a first
- https://example.com/b second
- https://example.com/a duplicate
MD

dedup_output="$("$harness/mill" memory dedup)"
[[ "$dedup_output" == *"Removed 1 duplicate URL line"* ]]
[[ "$(grep -c 'https://example.com/a' "$harness/memory/sources.md")" -eq 1 ]]
[[ "$(grep -c 'https://example.com/b' "$harness/memory/sources.md")" -eq 1 ]]

rotate_output="$("$harness/mill" memory rotate)"
[[ "$rotate_output" == *"Archived memory topics to"* ]]
[[ ! -f "$harness/memory/sources.md" ]]
archived_sources="$(find "$harness/memory/archive" -name sources.md -print)"
[[ -n "$archived_sources" ]]

echo "PASS test_mill_memory_cli"
