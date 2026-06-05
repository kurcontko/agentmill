#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export CONVERGENCE_LOG="$LOG_DIR/convergence.tsv"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export RESULTS_LOG="$LOG_DIR/results.tsv"
export MEMORY_DIR="$TMPDIR/memory"
export AGENT_ID="researcher"
export ITERATION="0"
export AGENTMILL_RUN_ID="research-gate-test"
export AGENTMILL_RESEARCH_SATURATION_ITERATIONS=3
export AGENTMILL_RESEARCH_OPEN_QUESTIONS_MAX=0

mkdir -p "$LOG_DIR" "$MEMORY_DIR"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

assert_gate() {
    local expected_passed="$1" expected_value="$2" expected_threshold="$3"
    if [[ "$COMPLETION_GATE_PASSED" != "$expected_passed" ]]; then
        echo "expected gate passed=$expected_passed, got $COMPLETION_GATE_PASSED" >&2
        return 1
    fi
    if [[ "$COMPLETION_GATE_VALUE" != "$expected_value" ]]; then
        echo "expected gate value=$expected_value, got $COMPLETION_GATE_VALUE" >&2
        return 1
    fi
    if [[ "$COMPLETION_GATE_THRESHOLD" != "$expected_threshold" ]]; then
        echo "expected gate threshold=$expected_threshold, got $COMPLETION_GATE_THRESHOLD" >&2
        return 1
    fi
}

cat > "$RESULTS_LOG" <<'TSV'
iteration	agent	timestamp	sources_added	section	status	description
1	researcher	2026-05-29T00:00:00Z	3	overview	ok	found sources
2	researcher	2026-05-29T00:01:00Z	0	overview	ok	no new sources
3	researcher	2026-05-29T00:02:00Z	0	overview	ok	no new sources
TSV
cat > "$MEMORY_DIR/open_questions.md" <<'MD'
---
type: open_questions
owners:
  - research
---
- [x] answered
MD
completion_gate_evaluate research_saturation
assert_gate false "zero_source_streak=2;open_questions=0" "zero_source_streak>=3;open_questions<=0"

cat > "$RESULTS_LOG" <<'TSV'
iteration	agent	timestamp	sources_added	section	status	description
1	researcher	2026-05-29T00:00:00Z	4	overview	ok	found sources
2	researcher	2026-05-29T00:01:00Z	0	overview	ok	no new sources
3	researcher	2026-05-29T00:02:00Z	0	overview	ok	no new sources
4	researcher	2026-05-29T00:03:00Z	0	overview	ok	no new sources
TSV
cat > "$MEMORY_DIR/open_questions.md" <<'MD'
---
type: open_questions
owners:
  - research
---
- [ ] unresolved source conflict
- [x] closed item
MD
completion_gate_evaluate research_depth_iteration
assert_gate false "zero_source_streak=3;open_questions=1" "zero_source_streak>=3;open_questions<=0"

cat > "$MEMORY_DIR/open_questions.md" <<'MD'
---
type: open_questions
owners:
  - research
---
- [x] source conflict resolved
MD
completion_gate_evaluate source_saturation
assert_gate true "zero_source_streak=3;open_questions=0" "zero_source_streak>=3;open_questions<=0"

convergence_log_append 4 researcher "$COMPLETION_GATE_NAME" "$COMPLETION_GATE_PASSED" "$COMPLETION_GATE_VALUE" "$COMPLETION_GATE_THRESHOLD" "$COMPLETION_GATE_EVIDENCE" allow

python3 - "$CONVERGENCE_LOG" <<'PY'
import csv
import sys

rows = list(csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8"), delimiter="\t"))
assert len(rows) == 1, rows
row = rows[0]
assert row["gate"] == "source_saturation", row
assert row["passed"] == "true", row
assert row["value"] == "zero_source_streak=3;open_questions=0", row
assert row["threshold"] == "zero_source_streak>=3;open_questions<=0", row
assert "results=" in row["evidence"], row
assert "open_questions=" in row["evidence"], row
PY

echo "PASS test_research_completion_gate"
