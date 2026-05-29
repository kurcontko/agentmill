#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
repo="$TMPDIR/research"
mkdir -p "$harness" "$repo/memory" "$repo/logs"
cp "$REPO_ROOT/mill" "$harness/mill"
chmod +x "$harness/mill"

cat > "$repo/REPORT.md" <<'MD'
# Research Report

## Summary

Claim one.[^1]

## Details

Claim two.[^2] Claim three.[^3]

[^1]: https://example.com/a
[^2]: https://example.com/b
[^3]: https://example.com/c
MD

cat > "$repo/memory/sources.md" <<'MD'
---
type: sources
created: 2026-05-29T00:00:00Z
last_iteration: 2
---
- https://example.com/a — primary
- https://example.com/b — vendor docs
- https://example.com/a — duplicate
MD

cat > "$repo/memory/open_questions.md" <<'MD'
---
type: open_questions
created: 2026-05-29T00:00:00Z
last_iteration: 2
---
- [ ] Is claim one replicated?
- [x] Is claim two dated?
- unresolved plain bullet
MD

cat > "$repo/logs/results.tsv" <<'TSV'
iteration	agent	timestamp	sources_added	section	status	description
1	breadth	2026-05-29T00:00:00Z	2	Summary	kept	added sources
2	depth	2026-05-29T00:01:00Z	0	Details	noop	no new sources
TSV

json_output="$("$harness/mill" report status "$repo" --json)"
text_output="$("$harness/mill" report status "$repo")"

python3 - "$json_output" "$text_output" "$repo" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
text = sys.argv[2]
repo = sys.argv[3]

assert data["repo"] == repo, data
assert data["report_exists"] is True, data
assert data["source_count"] == 2, data
assert data["open_questions"] == 2, data
sections = {section["title"]: section for section in data["sections"]}
assert sections["Summary"]["citations"] == 1, sections
assert sections["Details"]["citations"] == 2, sections
assert data["recent_iterations"][-1]["sources_added"] == "0", data
assert data["recent_iterations"][-1]["section"] == "Details", data

assert "source_count: 2" in text, text
assert "open_questions: 2" in text, text
assert "sources_added=0" in text, text
assert "section=Details" in text, text
PY

echo "PASS test_mill_report_status"
