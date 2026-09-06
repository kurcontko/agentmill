#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
mkdir -p "$TASK_TMP/bin" "$TASK_TMP/repo" "$TASK_TMP/home"
git -C "$TASK_TMP/repo" init -q
printf 'Finish the bounded task\n' > "$TASK_TMP/repo/MILL.md"
git -C "$TASK_TMP/repo" add MILL.md
git -C "$TASK_TMP/repo" -c user.name=test -c user.email=test@example.com commit -qm baseline
printf 'Work on the task\n' > "$TASK_TMP/prompt"
printf 'Review the task\n' > "$TASK_TMP/review"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "${1:-}" != --help ]] || exit 0' \
    'role=worker; [[ "$*" != *--disallowedTools* ]] || role=reviewer' \
    'cap=none; previous=""; for arg in "$@"; do [[ "$previous" != --max-budget-usd ]] || cap="$arg"; previous="$arg"; done' \
    'printf "%s:%s\n" "$role" "$cap" >> "$LAUNCHES"' \
    '[[ "${FAIL_WORKER:-false}" != true ]] || exit 1' \
    'cost="\"total_cost_usd\":0.4,"; [[ "${UNKNOWN_COST:-false}" != true ]] || cost=""' \
    'reply="\"done\":true,\"summary\":\"done\",\"blocked\":false"' \
    '[[ "$role" != reviewer ]] || reply="\"verdict\":\"PASS\",\"findings\":\"checked\""' \
    'printf '\''{"type":"result","subtype":"success","is_error":false,%s"num_turns":3,"structured_output":{%s}}\n'\'' "$cost" "$reply"' \
    > "$TASK_TMP/bin/claude"
chmod +x "$TASK_TMP/bin/claude"

run_case() {
    local name="$1" expected="$2" actual=0
    shift 2
    HOME="$TASK_TMP/home" PATH="$TASK_TMP/bin:$PATH" ANTHROPIC_API_KEY=test \
        REPO_DIR="$TASK_TMP/repo" LOG_DIR="$TASK_TMP/$name" \
        PROMPT_FILE="$TASK_TMP/prompt" EVALUATOR_FILE="$TASK_TMP/review" \
        _AGENTMILL_TEST_UNSANDBOXED_EVALUATOR=true CHECK_CMD=true \
        MAX_ITERATIONS=2 LOOP_DELAY=0 ERROR_BACKOFF=0 SHUTDOWN_GRACE=0 \
        LAUNCHES="$TASK_TMP/$name-launches" "$@" bash "$ROOT/loop.sh" >"$TASK_TMP/$name-output" 2>&1 || actual=$?
    [[ "$actual" -eq "$expected" ]] || { cat "$TASK_TMP/$name-output"; echo "FAIL: $name got $actual, expected $expected"; exit 1; }
}

run_case reserve 0 env EVALUATOR=true MAX_TOTAL_BUDGET_USD=1 REVIEW_RESERVE_USD=0.5
grep -qx 'worker:0.5' "$TASK_TMP/reserve-launches"
grep -qx 'reviewer:0.6' "$TASK_TMP/reserve-launches"
jq -e '.roles.worker.sessions == 1 and .roles.reviewer.sessions == 1 and .unknown_sessions == 0' \
    "$TASK_TMP/reserve/latest/accounting.json" >/dev/null
run_case insufficient 2 env EVALUATOR=true MAX_TOTAL_BUDGET_USD=0.5 REVIEW_RESERVE_USD=0.5
[[ ! -e "$TASK_TMP/insufficient-launches" ]]
run_case unknown 3 env EVALUATOR=true MAX_TOTAL_BUDGET_USD=1 UNKNOWN_COST=true
[[ "$(wc -l < "$TASK_TMP/unknown-launches")" -eq 1 ]]
jq -e '.completion == "blocked" and .stop_reason == "cost_unknown" and .accounting.total_cost_usd == null' \
    "$TASK_TMP/unknown/latest/outcome.json" >/dev/null

started=$SECONDS
run_case total_setup 2 env MAX_DURATION=1 SETUP_CMD='trap "" TERM; sleep 30 & wait'
[[ "$((SECONDS - started))" -lt 8 ]]
[[ ! -e "$TASK_TMP/total_setup-launches" ]]
jq -e '.stop_reason == "duration_limit" and .iterations == 0' "$TASK_TMP/total_setup/latest/outcome.json" >/dev/null
[[ -f "$TASK_TMP/total_setup/latest/setup.json" ]]
run_case backoff 2 env MAX_DURATION=1 ERROR_BACKOFF=30 MAX_ERRORS=0 FAIL_WORKER=true
jq -e '.stop_reason == "duration_limit"' "$TASK_TMP/backoff/latest/outcome.json" >/dev/null

if timeout --kill-after=1 1 true >/dev/null 2>&1; then
    started=$SECONDS
    run_case setup_timeout 1 env MAX_DURATION=30 SETUP_TIMEOUT=1 SETUP_CMD='trap "" TERM; sleep 30 & wait'
    [[ "$((SECONDS - started))" -lt 8 ]]
    [[ ! -e "$TASK_TMP/setup_timeout-launches" ]]
    jq -e '.stop_reason == "setup_failed" and .iterations == 0' "$TASK_TMP/setup_timeout/latest/outcome.json" >/dev/null
    jq -e '.exit_code != 0' "$TASK_TMP/setup_timeout/latest/setup.json" >/dev/null
else
    echo 'SKIP: independent setup timeout requires GNU timeout (validated in CI)'
fi
echo 'PASS: role allowances, unknown usage, setup and total-run deadlines'
