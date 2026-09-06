#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo 'FAIL: jq required'; exit 1; }
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
mkdir -p "$TASK_TMP/bin" "$TASK_TMP/repo" "$TASK_TMP/home"
git -C "$TASK_TMP/repo" init -q
printf 'Fix the widget\n' > "$TASK_TMP/repo/MILL.md"
git -C "$TASK_TMP/repo" add MILL.md
git -C "$TASK_TMP/repo" -c user.name=test -c user.email=test@example.com commit -qm baseline
printf 'Work on the mission\n' > "$TASK_TMP/prompt"
printf 'Review the mission\n' > "$TASK_TMP/review-prompt"
# The same completion claim is deliberately tested against different gates.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "${1:-}" != --help ]] || exit 0' \
    'if [[ "$*" == *--disallowedTools* ]]; then' \
    '  printf '\''{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"NEEDS_WORK","findings":"Missing behavior"},"num_turns":3}\n'\''' \
    'else' \
    '  printf '\''{"type":"result","subtype":"success","is_error":false,"structured_output":{"done":true,"summary":"Done","blocked":false},"num_turns":3}\n'\''' \
    'fi' > "$TASK_TMP/bin/claude"
chmod +x "$TASK_TMP/bin/claude"

check_outcome() {
    local name="$1" expected="$2" completion="$3" reason="$4" actual=0
    shift 4
    mkdir -p "$TASK_TMP/$name"
    HOME="$TASK_TMP/home" PATH="$TASK_TMP/bin:$PATH" ANTHROPIC_API_KEY=test \
        REPO_DIR="$TASK_TMP/repo" LOG_DIR="$TASK_TMP/$name" \
        PROMPT_FILE="$TASK_TMP/prompt" EVALUATOR_FILE="$TASK_TMP/review-prompt" \
        _AGENTMILL_TEST_UNSANDBOXED_EVALUATOR=true \
        MAX_ITERATIONS=1 LOOP_DELAY=0 ERROR_BACKOFF=0 \
        "$@" bash "$ROOT/loop.sh" >"$TASK_TMP/$name/output" 2>&1 || actual=$?
    if [[ "$actual" -ne "$expected" ]]; then
        cat "$TASK_TMP/$name/output"
        echo "FAIL: $name expected $expected, got $actual"
        exit 1
    fi
    jq -e --arg completion "$completion" --arg reason "$reason" --argjson code "$expected" \
        '.schema_version == 1 and .completion == $completion and
         .exit_code == $code and .stop_reason == $reason and (.run_id | length > 0)' \
        "$TASK_TMP/$name/outcome.json" >/dev/null
}

check_outcome verified 0 complete verified_completion env CHECK_CMD=true
jq -e '.agent_claimed_done and .verification.checks == "passed" and
       (.verification.checked_commit | length == 40)' "$TASK_TMP/verified/outcome.json" >/dev/null
check_outcome unchecked 2 incomplete iteration_limit env CHECK_CMD= DONE_CMD=
jq -e '.agent_claimed_done and .verification.checks == "not_run"' \
    "$TASK_TMP/unchecked/outcome.json" >/dev/null
check_outcome rejected 2 incomplete iteration_limit env DONE_CMD=false
jq -e '.agent_claimed_done and (.completion_ok | not) and (.done | not)' \
    "$TASK_TMP/rejected/results.jsonl" >/dev/null
jq -e '.verification.checks == "failed"' "$TASK_TMP/rejected/outcome.json" >/dev/null
check_outcome review 2 incomplete iteration_limit env CHECK_CMD=true EVALUATOR=true
jq -e '.verification.checks == "passed" and .verification.review == "needs_work"' \
    "$TASK_TMP/review/outcome.json" >/dev/null
check_outcome setup 1 failed setup_failed env SETUP_CMD=false
jq -e '.iterations == 0 and (.agent_claimed_done | not)' "$TASK_TMP/setup/outcome.json" >/dev/null
mkdir -p "$TASK_TMP/repo/.mill"
touch "$TASK_TMP/repo/.mill/STOP"
check_outcome stopped 4 cancelled stop_requested env CHECK_CMD=true
echo 'PASS: terminal outcomes distinguish verification, rejection, setup failure, and cancellation'
