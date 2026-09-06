#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
mkdir -p "$TASK_TMP/bin" "$TASK_TMP/repo" "$TASK_TMP/home" "$TASK_TMP/logs"
git -C "$TASK_TMP/repo" init -q
printf 'Repair failing tests\n' > "$TASK_TMP/repo/MILL.md"
printf 'broken\n' > "$TASK_TMP/repo/behavior"
git -C "$TASK_TMP/repo" add MILL.md behavior
git -C "$TASK_TMP/repo" -c user.name=test -c user.email=test@example.com commit -qm baseline
initial_head="$(git -C "$TASK_TMP/repo" rev-parse HEAD)"
printf 'Work on the mission\n' > "$TASK_TMP/prompt"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "${1:-}" != --help ]] || exit 0' \
    'n=1; [[ ! -f "$ATTEMPTS" ]] || n=$(( $(cat "$ATTEMPTS") + 1 ))' \
    'printf "%s" "$n" > "$ATTEMPTS"' \
    'printf "%s" "$2" > "$ATTEMPTS.prompt.$n"' \
    'case "$n" in' \
    '  1) printf "# Progress\nRepair behavior\n" > PROGRESS.md ;;' \
    '  2) printf "still broken\n" > behavior; echo failed-memory >> PROGRESS.md ;;' \
    '  3) printf "fixed\n" > behavior ;;' \
    'esac' \
    '[[ "${MIXED_INITIALIZATION:-false}" != true ]] || echo unverified >> behavior' \
    'git add -A && git commit -qm "attempt $n"' \
    'done_flag=false; [[ "$n" != 3 ]] || done_flag=true' \
    'printf '\''{"type":"result","subtype":"success","is_error":false,"structured_output":{"done":%s,"summary":"Repair attempt","blocked":false},"num_turns":3}\n'\'' "$done_flag"' \
    > "$TASK_TMP/bin/claude"
chmod +x "$TASK_TMP/bin/claude"
actual=0
HOME="$TASK_TMP/home" PATH="$TASK_TMP/bin:$PATH" ANTHROPIC_API_KEY=test \
    REPO_DIR="$TASK_TMP/repo" LOG_DIR="$TASK_TMP/logs" PROMPT_FILE="$TASK_TMP/prompt" \
    MAX_ITERATIONS=3 LOOP_DELAY=0 ERROR_BACKOFF=0 ATTEMPTS="$TASK_TMP/attempts" \
    CHECK_CMD='grep -qx fixed behavior || { echo test_behavior_failed; exit 1; }' \
    bash "$ROOT/loop.sh" >"$TASK_TMP/output" 2>&1 || actual=$?
[[ "$actual" -eq 0 ]] || { cat "$TASK_TMP/output"; echo 'FAIL: repair never completed'; exit 1; }
jq -e --arg head "$initial_head" '.exit_code == 1 and .checked_commit == $head' \
    "$TASK_TMP/logs/latest/baseline.json" >/dev/null
jq -se 'map(.status) == ["kept", "reverted", "kept"]' "$TASK_TMP/logs/latest/results.jsonl" >/dev/null
grep -q test_behavior_failed "$TASK_TMP/attempts.prompt.3"
grep -q 'Previous attempt was rejected' "$TASK_TMP/attempts.prompt.3"
if grep -q failed-memory "$TASK_TMP/repo/PROGRESS.md"; then
    echo 'FAIL: rejected progress file survived rollback'
    exit 1
fi
jq -e '.exit_code == 1 and (.patch | length > 0)' "$TASK_TMP/logs/latest/rejection.json" >/dev/null
echo 'PASS: red baseline initialization advances and rollback preserves failure feedback'

# An initializer that changes code does not qualify for the metadata exception.
git -C "$TASK_TMP/repo" switch --detach -q "$initial_head"
actual=0
HOME="$TASK_TMP/home" PATH="$TASK_TMP/bin:$PATH" ANTHROPIC_API_KEY=test \
    REPO_DIR="$TASK_TMP/repo" LOG_DIR="$TASK_TMP/mixed-logs" PROMPT_FILE="$TASK_TMP/prompt" \
    MAX_ITERATIONS=1 LOOP_DELAY=0 ERROR_BACKOFF=0 ATTEMPTS="$TASK_TMP/mixed-attempts" \
    MIXED_INITIALIZATION=true CHECK_CMD='grep -qx fixed behavior' \
    bash "$ROOT/loop.sh" >"$TASK_TMP/mixed-output" 2>&1 || actual=$?
[[ "$actual" -eq 2 ]] || { cat "$TASK_TMP/mixed-output"; exit 1; }
[[ "$(git -C "$TASK_TMP/repo" rev-parse HEAD)" == "$initial_head" ]]
[[ ! -e "$TASK_TMP/repo/PROGRESS.md" ]]
jq -e '.status == "reverted" and (.completion_ok | not)' "$TASK_TMP/mixed-logs/latest/results.jsonl" >/dev/null
echo 'PASS: mixed planning and implementation cannot bypass a failing check'
