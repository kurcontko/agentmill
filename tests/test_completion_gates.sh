#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export CONVERGENCE_LOG="$LOG_DIR/convergence.tsv"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export MEMORY_DIR="$TMPDIR/memory"
export DONE_FILE="$TMPDIR/done"
export AGENT_ID="gate"
export ITERATION="1"
export AGENTMILL_RUN_ID="completion-gates-test"
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

cat > "$MEMORY_DIR/open_questions.md" <<'MD'
---
type: open_questions
created: 2026-05-29T00:00:00Z
last_iteration: 0
---
- [x] answered
MD

rm -f "$DONE_FILE"
AGENTMILL_VERIFIER_COMMAND="true" AGENTMILL_CODER_OPEN_QUESTIONS_MAX=0 completion_gate_evaluate coder_verified
assert_gate false "done=false;verifier=not_run;open_questions=0" "done=true;verifier=pass;open_questions<=0"

touch "$DONE_FILE"
AGENTMILL_VERIFIER_COMMAND="" AGENTMILL_CODER_OPEN_QUESTIONS_MAX=0 completion_gate_evaluate coding_verified
assert_gate false "done=true;verifier=missing;open_questions=0" "done=true;verifier=pass;open_questions<=0"

cat > "$MEMORY_DIR/open_questions.md" <<'MD'
---
type: open_questions
created: 2026-05-29T00:00:00Z
last_iteration: 0
---
- [ ] unresolved verifier question
MD
AGENTMILL_VERIFIER_COMMAND="true" AGENTMILL_CODER_OPEN_QUESTIONS_MAX=0 completion_gate_evaluate coder_verified
assert_gate false "done=true;verifier=pass;open_questions=1" "done=true;verifier=pass;open_questions<=0"

cat > "$MEMORY_DIR/open_questions.md" <<'MD'
---
type: open_questions
created: 2026-05-29T00:00:00Z
last_iteration: 0
---
- [x] resolved
MD
AGENTMILL_VERIFIER_COMMAND="false" AGENTMILL_CODER_OPEN_QUESTIONS_MAX=0 completion_gate_evaluate coder_verified
assert_gate false "done=true;verifier=fail;open_questions=0" "done=true;verifier=pass;open_questions<=0"

AGENTMILL_VERIFIER_COMMAND="true" AGENTMILL_CODER_OPEN_QUESTIONS_MAX=0 completion_gate_evaluate coder_verified
assert_gate true "done=true;verifier=pass;open_questions=0" "done=true;verifier=pass;open_questions<=0"
[[ -f "$LOG_DIR/completion-verifier-gate-iter1.log" ]]

repo="$TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name "Test User"
printf 'one\ntwo\nthree\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m init
base="$(git -C "$repo" rev-parse HEAD)"

(
    cd "$repo"
    printf 'one\nthree\n' > file.txt
    AGENTMILL_BASE_SHA="$base" \
    AGENTMILL_VERIFIER_COMMAND="true" \
    AGENTMILL_REFACTOR_LOC_TARGET=-1 \
    AGENTMILL_REFACTOR_LOC_TOLERANCE=0 \
        completion_gate_evaluate refactor_verified
    assert_gate true "done=true;verifier=pass;loc_delta=-1" "done=true;verifier=pass;loc_delta>=-1;loc_delta<=-1"
)

(
    cd "$repo"
    printf 'one\ntwo\nthree\n' > file.txt
    AGENTMILL_BASE_SHA="$base" \
    AGENTMILL_VERIFIER_COMMAND="true" \
    AGENTMILL_REFACTOR_LOC_TARGET=-1 \
    AGENTMILL_REFACTOR_LOC_TOLERANCE=0 \
        completion_gate_evaluate refactor_verified
    assert_gate false "done=true;verifier=pass;loc_delta=0" "done=true;verifier=pass;loc_delta>=-1;loc_delta<=-1"
)

(
    cd "$repo"
    printf 'one\ntwo\nthree\nfour\n' > file.txt
    AGENTMILL_BASE_SHA="$base" \
    AGENTMILL_VERIFIER_COMMAND="true" \
    AGENTMILL_REFACTOR_LOC_TARGET= \
    AGENTMILL_REFACTOR_MAX_LOC_DELTA=0 \
        completion_gate_evaluate refactor_verified
    assert_gate false "done=true;verifier=pass;loc_delta=1" "done=true;verifier=pass;loc_delta<=0"
)

echo "PASS test_completion_gates"
