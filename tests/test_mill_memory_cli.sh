#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
repo="$TMPDIR/repo"
mkdir -p "$harness/memory" "$repo/memory"
cp "$REPO_ROOT/mill" "$harness/mill"
chmod +x "$harness/mill"
printf 'REPO_PATH=%s\n' "$repo" > "$harness/.env"

cat > "$harness/memory/sources.md" <<'MD'
---
agent: a
timestamp: 2026-05-29T00:00:00Z
---
- https://example.com/a first
- https://example.com/b second
- https://example.com/a duplicate
MD
cat > "$repo/memory/sources.md" <<'MD'
---
agent: wrong
timestamp: 2026-05-29T00:00:00Z
---
- https://repo.example.com/should-not-be-read
MD

dedup_output="$("$harness/mill" memory dedup)"
[[ "$dedup_output" == *"Removed 1 duplicate URL line"* ]]
[[ "$(grep -c 'https://example.com/a' "$harness/memory/sources.md")" -eq 1 ]]
[[ "$(grep -c 'https://example.com/b' "$harness/memory/sources.md")" -eq 1 ]]
grep -q 'https://repo.example.com/should-not-be-read' "$repo/memory/sources.md"

rotate_output="$("$harness/mill" memory rotate)"
[[ "$rotate_output" == *"Archived memory topics to"* ]]
[[ ! -f "$harness/memory/sources.md" ]]
archived_sources="$(find "$harness/memory/archive" -name sources.md -print)"
[[ -n "$archived_sources" ]]
[[ -f "$repo/memory/sources.md" ]]

echo "PASS test_mill_memory_cli"
