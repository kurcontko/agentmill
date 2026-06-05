#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export MEMORY_DIR="$TMPDIR/memory"
export LOG_DIR="$TMPDIR/logs"
export ITERATION=7
mkdir -p "$MEMORY_DIR" "$LOG_DIR"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

memory_write sources "https://example.com/source" researcher
memory_write open_questions "what remains?" researcher
memory_write failed_approaches "bad path" coder

set +e
memory_write "../escape" "bad topic" attacker >/dev/null 2>&1
invalid_rc=$?
set -e
[[ "$invalid_rc" -ne 0 ]] || { echo "expected invalid memory topic to fail" >&2; exit 1; }
[[ ! -f "$TMPDIR/escape.md" ]] || { echo "invalid memory topic escaped MEMORY_DIR" >&2; exit 1; }

python3 - "$MEMORY_DIR" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = {
    "sources.md": "sources",
    "open_questions.md": "open_questions",
    "failed_approaches.md": "decisions",
}

for filename, topic_type in expected.items():
    text = (root / filename).read_text(encoding="utf-8")
    assert text.startswith("---\n"), text
    header = text.split("---\n", 2)[1]
    assert f"type: {topic_type}\n" in header, header
    assert "created: " in header, header
    assert "last_iteration: 7\n" in header, header
    assert "\nagent: " in text, text
PY

summary="$(memory_summary)"
[[ "$summary" == *"[[sources]] (1 entries)"* ]]
[[ "$summary" == *"[[open_questions]] (1 entries)"* ]]
[[ "$summary" == *"[[failed_approaches]] (1 entries)"* ]]

echo "PASS test_memory_schema"
