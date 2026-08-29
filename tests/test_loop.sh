#!/usr/bin/env bash
set -euo pipefail
# Smoke tests for loop.sh with a stubbed `claude` CLI. No network, no docker.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }

make_env() {  # fresh sandbox: stub bin, repo with one commit, prompt
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin" "$TMP/repo" "$TMP/logs" "$TMP/home"
    git -C "$TMP/repo" init -q
    printf -- '---\ncheck_cmd: true\n---\nbuild the widget\n' > "$TMP/repo/MILL.md"
    git -C "$TMP/repo" add MILL.md
    git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -qm init
    echo "do the thing" > "$TMP/prompt.md"
}

run_loop_raw() {  # returns loop.sh's exit code; output in $TMP/out.log
    HOME="$TMP/home" PATH="$TMP/bin:$PATH" ANTHROPIC_API_KEY=test \
    REPO_DIR="$TMP/repo" LOG_DIR="$TMP/logs" PROMPT_FILE="$TMP/prompt.md" \
    LOOP_DELAY=0 ERROR_BACKOFF=0 "$@" bash "$ROOT/loop.sh" >"$TMP/out.log" 2>&1
}

run_loop() {
    run_loop_raw "$@" || { cat "$TMP/out.log"; fail "loop.sh exited nonzero"; }
}

# --- 1: agent commits, signals done promise → loop stops with 'kept' ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo change >> stub.txt
git add -A && git commit -qm "agent: stub work"
printf '{"type":"result","is_error":false,"result":"all done. TASK_COMPLETE"}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=5
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected done-promise stop"; }
[[ "$(git -C "$TMP/repo" rev-list --count HEAD)" -eq 2 ]] || fail "expected exactly one agent commit"
grep -q '"status":"kept"' "$TMP/logs/results.jsonl" || fail "results.jsonl missing kept status"
rm -rf "$TMP"
echo "PASS: done promise stops the loop, work kept"

# --- 2: CHECK_CMD fails → iteration reverted, no-progress stop ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo change >> stub.txt
git add -A && git commit -qm "agent: bad work"
printf '{"type":"result","is_error":false,"result":"made changes"}\n'
STUB
chmod +x "$TMP/bin/claude"
head_before="$(git -C "$TMP/repo" rev-parse HEAD)"
run_loop env MAX_ITERATIONS=10 MAX_NOOPS=2 CHECK_CMD=false
grep -q "consecutive no-progress" "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected no-progress stop"; }
[[ "$(git -C "$TMP/repo" rev-parse HEAD)" == "$head_before" ]] || fail "reverted iteration left commits behind"
grep -q '"status":"reverted"' "$TMP/logs/results.jsonl" || fail "results.jsonl missing reverted status"
rm -rf "$TMP"
echo "PASS: failing CHECK_CMD reverts the iteration (ratchet)"

# --- 3: agent keeps failing → error stop with backoff bounded by MAX_ERRORS=1 ---
make_env
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
run_loop env MAX_ERRORS=1
grep -q "1 consecutive errors" "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected error stop"; }
grep -q '"status":"error"' "$TMP/logs/results.jsonl" || fail "results.jsonl missing error status"
rm -rf "$TMP"
echo "PASS: consecutive errors stop the loop"

# --- 4: agent errors out leaving a broken tree → ratchet still reverts it ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo junk >> broken.txt
exit 1
STUB
chmod +x "$TMP/bin/claude"
head_before="$(git -C "$TMP/repo" rev-parse HEAD)"
run_loop env MAX_ITERATIONS=1 MAX_ERRORS=5 CHECK_CMD=false
[[ "$(git -C "$TMP/repo" rev-parse HEAD)" == "$head_before" ]] || fail "errored iteration was not reverted"
[[ -e "$TMP/repo/broken.txt" ]] && fail "revert left the agent's file behind"
grep -q '"status":"reverted"' "$TMP/logs/results.jsonl" || fail "expected reverted status after agent error"
rm -rf "$TMP"
echo "PASS: a failed/timed-out iteration is checked and reverted too"

# --- 5: MAX_ERRORS=0 / MAX_NOOPS=0 mean unbounded, not 'stop immediately' ---
make_env
printf '#!/usr/bin/env bash
exit 1
' > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
run_loop env MAX_ERRORS=0 MAX_NOOPS=0 MAX_ITERATIONS=2
grep -q "max iterations" "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected max-iterations stop"; }
[[ "$(wc -l < "$TMP/logs/results.jsonl")" -eq 2 ]] || fail "0 limits stopped the loop early"
rm -rf "$TMP"
echo "PASS: MAX_ERRORS=0 / MAX_NOOPS=0 are unbounded"

# --- 6: a dirty worktree is refused (a revert would discard the user's edits) ---
make_env
printf '#!/usr/bin/env bash
exit 0
' > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
echo "mine" > "$TMP/repo/uncommitted.txt"
if run_loop_raw env MAX_ITERATIONS=1; then fail "loop started on a dirty repo"; fi
grep -q "uncommitted changes" "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected a dirty-repo refusal"; }
[[ -f "$TMP/repo/uncommitted.txt" ]] || fail "refusal destroyed the user's file"
git -C "$TMP/repo" add -A
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q -m "mine"
run_loop env MAX_ITERATIONS=1
rm -rf "$TMP"
echo "PASS: dirty worktree refused, clean one runs"

# --- 7: the framework prompt rides in claude's system prompt, the mission in the turn ---
make_env
printf '# Task
do the thing
' > "$TMP/prompt.md"
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
sys="" prev=""
for a in "$@"; do
    [[ "$prev" == --append-system-prompt ]] && sys="$a"
    prev="$a"
done
grep -q '^# Task$' <<<"$sys" || { echo "framework prompt not in the system prompt" >&2; exit 3; }
grep -q '^</loop-context>$' <<<"$2" || { echo "preamble not terminated" >&2; exit 3; }
grep -q '# Task' <<<"$2" && { echo "framework prompt duplicated in the user turn" >&2; exit 3; }
grep -q -- '--no-session-persistence' <<<"$*" || { echo "session persistence not disabled" >&2; exit 3; }
grep -q -- '--bare' <<<"$*" && { echo "--bare passed without CLAUDE_BARE" >&2; exit 3; }
grep -q -- '--json-schema' <<<"$*" || { echo "no output schema requested" >&2; exit 3; }
printf '{"type":"result","is_error":false,"result":"ok TASK_COMPLETE"}
'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=1
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" || { cat "$TMP/out.log"; fail "prompt was malformed"; }
# CLAUDE_BARE is opt-in because --bare also skips CLAUDE.md and hook discovery.
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
grep -q -- '--bare' <<<"$*" || { echo "CLAUDE_BARE did not reach the CLI" >&2; exit 3; }
printf '{"type":"result","is_error":false,"result":"ok TASK_COMPLETE"}
'
STUB
run_loop env MAX_ITERATIONS=1 CLAUDE_BARE=true
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" || { cat "$TMP/out.log"; fail "CLAUDE_BARE not forwarded"; }
rm -rf "$TMP"
echo "PASS: framework prompt is a system prompt; hygiene flags reach the CLI"

# --- 8: codex's last-message file is truncated, so it cannot replay a stale one ---
make_env
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo change >> stub.txt
git add -A && git commit -qm "agent: stub work"
exit 0
STUB
chmod +x "$TMP/bin/codex"
echo "TASK_COMPLETE" > "$TMP/logs/.codex-last-msg"
run_loop env AGENT=codex OPENAI_API_KEY=test MAX_ITERATIONS=2
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" && fail "stale last-message file stopped the loop"
grep -q "max iterations" "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected max-iterations stop"; }
rm -rf "$TMP"
echo "PASS: stale codex last-message is not mistaken for completion"

# --- 9: the loop runs in a linked worktree (its .git is a file, not a dir) ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo change >> stub.txt
git add -A && git commit -qm "agent: stub work"
printf '{"type":"result","is_error":false,"result":"done TASK_COMPLETE"}\n'
STUB
chmod +x "$TMP/bin/claude"
git -C "$TMP/repo" worktree add -q "$TMP/wt" -b agent-b
run_loop env MAX_ITERATIONS=1 REPO_DIR="$TMP/wt"
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" || { cat "$TMP/out.log"; fail "loop failed inside a worktree"; }
[[ "$(git -C "$TMP/wt" rev-list --count HEAD)" -eq 2 ]] || fail "worktree commit missing"
rm -rf "$TMP"
echo "PASS: the loop works in a linked worktree"

# --- 10: git identity comes from the environment, not the repo's .git/config ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo change >> stub.txt
git add -A && git commit -qm "agent: stub work"
printf '{"type":"result","is_error":false,"result":"done TASK_COMPLETE"}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=1 GIT_USER=looper GIT_EMAIL=looper@x
[[ "$(git -C "$TMP/repo" log -1 --format=%an)" == looper ]] || fail "agent commit not authored by GIT_USER"
git -C "$TMP/repo" config --local user.name >/dev/null && fail "identity was written to the repo's config"
rm -rf "$TMP"
echo "PASS: git identity is not persisted in the host repo"

# --- 11: TERM mid-session reaches the agent, the loop waits for it, no new session ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
trap 'echo signalled > got-term; git add -A; git commit -qm "agent: on term"; exit 0' TERM
echo started > started
sleep 30 & wait $!
STUB
chmod +x "$TMP/bin/claude"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" ANTHROPIC_API_KEY=test \
    REPO_DIR="$TMP/repo" LOG_DIR="$TMP/logs" PROMPT_FILE="$TMP/prompt.md" \
    LOOP_DELAY=0 SHUTDOWN_GRACE=10 bash "$ROOT/loop.sh" >"$TMP/out.log" 2>&1 &
loop_pid=$!
for _ in $(seq 1 50); do [[ -f "$TMP/repo/started" ]] && break; sleep 0.1; done
[[ -f "$TMP/repo/started" ]] || { cat "$TMP/out.log"; fail "agent never started"; }
term_started="$(date +%s)"
kill -TERM "$loop_pid"
wait "$loop_pid" || { cat "$TMP/out.log"; fail "loop.sh exited nonzero after TERM"; }
term_elapsed=$(( $(date +%s) - term_started ))
[[ "$term_elapsed" -lt 5 ]] \
    || { cat "$TMP/out.log"; fail "agent process group took ${term_elapsed}s to stop after TERM"; }
[[ -f "$TMP/repo/got-term" ]] || { cat "$TMP/out.log"; fail "agent CLI did not receive TERM"; }
grep -q "shutdown signal" "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected shutdown stop"; }
[[ "$(wc -l < "$TMP/logs/results.jsonl")" -eq 1 ]] || fail "a new session started after the signal"
grep -q '"status":"kept"' "$TMP/logs/results.jsonl" || fail "the agent's own commit on TERM was not kept"
rm -rf "$TMP"
echo "PASS: TERM stops the agent gracefully and the loop waits for it"

# --- 12: a signal during the inter-iteration sleep does not start another session ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","is_error":false,"result":"nothing to do"}\n'
STUB
chmod +x "$TMP/bin/claude"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" ANTHROPIC_API_KEY=test \
    REPO_DIR="$TMP/repo" LOG_DIR="$TMP/logs" PROMPT_FILE="$TMP/prompt.md" \
    LOOP_DELAY=30 MAX_NOOPS=0 bash "$ROOT/loop.sh" >"$TMP/out.log" 2>&1 &
loop_pid=$!
for _ in $(seq 1 50); do [[ -f "$TMP/logs/results.jsonl" ]] && break; sleep 0.1; done
sleep 0.5
kill -TERM "$loop_pid"
wait "$loop_pid" || { cat "$TMP/out.log"; fail "loop.sh exited nonzero after TERM in sleep"; }
[[ "$(wc -l < "$TMP/logs/results.jsonl")" -eq 1 ]] || fail "signal during sleep started another session"
rm -rf "$TMP"
echo "PASS: a signal during the sleep stops the loop immediately"

# --- 13: the error backoff is capped and never overflows with MAX_ERRORS=0 ---
make_env
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
run_loop env MAX_ERRORS=0 MAX_ITERATIONS=70 ERROR_BACKOFF=1 MAX_BACKOFF=0
[[ "$(wc -l < "$TMP/logs/results.jsonl")" -eq 70 ]] || { cat "$TMP/out.log"; fail "backoff arithmetic broke the loop"; }
rm -rf "$TMP"
echo "PASS: error backoff is capped by MAX_BACKOFF"

# --- 14: every per-iteration timeout has a hard-kill escalation deadline ---
make_env
cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TIMEOUT_LOG"
case "${1:-}" in
    --kill-after=*) shift ;;
    -k) shift 2 ;;
esac
shift # duration
exec "$@"
STUB
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","is_error":false,"result":"done TASK_COMPLETE"}\n'
STUB
chmod +x "$TMP/bin/timeout" "$TMP/bin/claude"
export TIMEOUT_LOG="$TMP/timeout.log"
run_loop env MAX_ITERATIONS=1 ITER_TIMEOUT=99 SHUTDOWN_GRACE=7
grep -q '^--kill-after=7 99 claude ' "$TIMEOUT_LOG" \
    || { cat "$TIMEOUT_LOG"; fail "agent timeout has no hard-kill deadline"; }
rm -rf "$TMP"
echo "PASS: iteration timeout escalates to SIGKILL after a deadline"

# Behavioral check when GNU timeout is available on the host: both an
# uncooperative CLI and its descendant must be gone before the loop continues.
if timeout --kill-after=1 1 true >/dev/null 2>&1; then
    make_env
    cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
trap '' TERM
(trap '' TERM; sleep 8) &
wait
STUB
    chmod +x "$TMP/bin/claude"
    timeout_started="$(date +%s)"
    run_loop env ITER_TIMEOUT=1 SHUTDOWN_GRACE=1 MAX_ITERATIONS=1 MAX_ERRORS=5
    timeout_elapsed=$(( $(date +%s) - timeout_started ))
    [[ "$timeout_elapsed" -lt 5 ]] \
        || { cat "$TMP/out.log"; fail "timeout left a TERM-ignoring descendant alive for ${timeout_elapsed}s"; }
    rm -rf "$TMP"
    echo "PASS: iteration timeout kills TERM-ignoring descendants"
fi

# --- 15: an unreadable repository status fails closed ---
make_env
real_git_bin="$(command -v git)"
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == status ]]; then
    echo "stub: repository status unreadable" >&2
    exit 42
fi
exec "$REAL_GIT_BIN" "$@"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/git" "$TMP/bin/claude"
if run_loop_raw env REAL_GIT_BIN="$real_git_bin" MAX_ITERATIONS=1; then
    fail "loop treated a failed git status as a clean checkout"
fi
grep -q 'stub: repository status unreadable' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "git status error was hidden"; }
grep -q 'could not read repository status' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "loop did not fail closed on status error"; }
rm -rf "$TMP"
echo "PASS: repository status errors are fatal"

# --- 16: rollback restores and cleans initialized submodules recursively ---
make_env
mkdir -p "$TMP/nested-origin" "$TMP/sub-origin"
git -C "$TMP/nested-origin" init -q
echo nested-baseline > "$TMP/nested-origin/nested.txt"
git -C "$TMP/nested-origin" add nested.txt
git -C "$TMP/nested-origin" -c user.email=t@t -c user.name=t commit -qm init

git -C "$TMP/sub-origin" init -q
echo sub-baseline > "$TMP/sub-origin/sub.txt"
git -C "$TMP/sub-origin" add sub.txt
git -C "$TMP/sub-origin" -c user.email=t@t -c user.name=t commit -qm init
git -c protocol.file.allow=always -C "$TMP/sub-origin" submodule add -q \
    "$TMP/nested-origin" nested
git -C "$TMP/sub-origin" -c user.email=t@t -c user.name=t commit -qam nested

git -c protocol.file.allow=always -C "$TMP/repo" submodule add -q \
    "$TMP/sub-origin" deps/sub
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -qam submodule
git -c protocol.file.allow=always -C "$TMP/repo" submodule update -q --init --recursive
head_before="$(git -C "$TMP/repo" rev-parse HEAD)"
sub_before="$(git -C "$TMP/repo/deps/sub" rev-parse HEAD)"
nested_before="$(git -C "$TMP/repo/deps/sub/nested" rev-parse HEAD)"

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo nested-broken > deps/sub/nested/nested.txt
git -C deps/sub/nested add nested.txt
git -C deps/sub/nested commit -qm "agent: bad nested change"
git -C deps/sub add nested
git -C deps/sub commit -qm "agent: bad submodule change"
git add deps/sub
git commit -qm "agent: bad superproject change"
printf '{"type":"result","is_error":false,"result":"made changes"}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=1 \
    CHECK_CMD='echo check-junk > deps/sub/nested/untracked.txt; false'
[[ "$(git -C "$TMP/repo" rev-parse HEAD)" == "$head_before" ]] \
    || fail "rollback left the superproject at the iteration commit"
[[ "$(git -C "$TMP/repo/deps/sub" rev-parse HEAD)" == "$sub_before" ]] \
    || fail "rollback did not restore the first-level submodule"
[[ "$(git -C "$TMP/repo/deps/sub/nested" rev-parse HEAD)" == "$nested_before" ]] \
    || fail "rollback did not restore the nested submodule"
grep -q '^nested-baseline$' "$TMP/repo/deps/sub/nested/nested.txt" \
    || fail "rollback left tracked nested-submodule changes"
[[ ! -e "$TMP/repo/deps/sub/nested/untracked.txt" ]] \
    || fail "rollback left untracked nested-submodule files"
[[ -z "$(git -C "$TMP/repo" status --porcelain --untracked-files=all)" ]] \
    || fail "rollback left the recursive checkout dirty"
rm -rf "$TMP"
echo "PASS: rollback restores and cleans submodules recursively"

# --- MILL.md: body (not frontmatter) reaches the agent; edits are re-read and logged ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$2" > "$PROMPT_DUMP"
grep -q 'check_cmd' "$PROMPT_DUMP" && { echo "frontmatter leaked into prompt" >&2; exit 3; }
grep -q '^build the widget$' "$PROMPT_DUMP" || { echo "mission body missing" >&2; exit 3; }
if ! grep -q 'second mission' "$PROMPT_DUMP"; then
    echo "second mission" >> MILL.md
    git add -A && git commit -qm "agent: edit mission"
fi
printf '{"type":"result","is_error":false,"result":"ok"}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env PROMPT_DUMP="$TMP/prompt-dump" MAX_ITERATIONS=2
grep -q 'MILL.md changed since the last iteration' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "mission edit was not noticed"; }
grep -q '<mission>' "$TMP/prompt-dump" || fail "mission block missing from prompt"
rm -rf "$TMP"
echo "PASS: MILL.md body is spliced into the prompt and re-read each iteration"

# --- missing MILL.md is fatal ---
make_env
git -C "$TMP/repo" rm -q MILL.md && git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -qm "drop mission"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
run_loop_raw env MAX_ITERATIONS=1 && fail "loop started without MILL.md"
grep -q 'no mission file' "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected missing-mission error"; }
rm -rf "$TMP"
echo "PASS: missing MILL.md is refused"

# --- 17: a result event marking failure is an error even when the CLI exits 0 ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo change >> stub.txt
git add -A && git commit -qm "agent: half-finished work"
printf '{"type":"result","subtype":"error_during_execution","is_error":true,'
printf '"result":"crashed but TASK_COMPLETE","total_cost_usd":0.25,"num_turns":4,'
printf '"duration_ms":1200,"usage":{"input_tokens":100,"output_tokens":20}}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=1 MAX_ERRORS=5
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" && { cat "$TMP/out.log"; fail "done promise honored on an errored session"; }
grep -q "agent reported an error (error_during_execution" "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "is_error:true with exit 0 was not treated as an error"; }
grep -q '"status":"error"' "$TMP/logs/results.jsonl" || fail "results.jsonl missing error status"
grep -q '"subtype":"error_during_execution"' "$TMP/logs/results.jsonl" || fail "subtype not recorded"
grep -q '"cost_usd":0.25' "$TMP/logs/results.jsonl" || { cat "$TMP/logs/results.jsonl"; fail "cost not recorded"; }
grep -q '"turns":4' "$TMP/logs/results.jsonl" || fail "turns not recorded"
grep -q '"tokens_in":100,"tokens_out":20' "$TMP/logs/results.jsonl" || fail "token counts not recorded"
grep -q '"duration_s":' "$TMP/logs/results.jsonl" || fail "wall-clock duration not recorded"
rm -rf "$TMP"
echo "PASS: a failed result event beats exit 0 and blocks the done promise"

# --- 18: error_* subtypes count as failures even with is_error:false ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo change >> stub.txt
git add -A && git commit -qm "agent: ran out of turns"
printf '{"type":"result","subtype":"error_max_turns","is_error":false,"result":"ran out","num_turns":9}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ERRORS=1
grep -q "1 consecutive errors" "$TMP/out.log" || { cat "$TMP/out.log"; fail "error_max_turns did not stop the loop"; }
grep -q '"subtype":"error_max_turns"' "$TMP/logs/results.jsonl" || fail "subtype not recorded"
rm -rf "$TMP"
echo "PASS: an error_* subtype is a failed iteration"

# --- 19: session costs accumulate and MAX_TOTAL_BUDGET_USD stops the loop ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo change >> "stub-$RANDOM.txt"
git add -A && git commit -qm "agent: paid work"
printf '{"type":"result","subtype":"success","is_error":false,"result":"more to do",'
printf '"total_cost_usd":0.6,"num_turns":5}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=10 MAX_TOTAL_BUDGET_USD=1
grep -q 'budget exhausted ([$]1.20 of [$]1.00)' "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected a budget stop"; }
[[ "$(wc -l < "$TMP/logs/results.jsonl")" -eq 2 ]] || fail "budget stop came at the wrong iteration"
grep -q 'total [$]1.20' "$TMP/out.log" || { cat "$TMP/out.log"; fail "cumulative cost missing from the iteration line"; }
grep -q 'total cost: [$]1.20 across 2 iterations' "$TMP/out.log" || fail "final cost summary missing"
rm -rf "$TMP"
echo "PASS: costs accumulate and MAX_TOTAL_BUDGET_USD stops the loop"

# --- 20: MAX_TURNS / MAX_BUDGET_USD reach the claude CLI ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
printf '{"type":"result","subtype":"success","is_error":false,"result":"done TASK_COMPLETE","num_turns":3}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=1 MAX_TURNS=7 MAX_BUDGET_USD=2.50 ARGV_LOG="$TMP/argv.log"
grep -q -- '--max-turns 7' "$TMP/argv.log" || { cat "$TMP/argv.log"; fail "MAX_TURNS not forwarded"; }
grep -q -- '--max-budget-usd 2.50' "$TMP/argv.log" || { cat "$TMP/argv.log"; fail "MAX_BUDGET_USD not forwarded"; }
rm -rf "$TMP"
echo "PASS: turn and budget caps are forwarded to the CLI"

# --- 21: a quick, empty-handed session is an error, not a no-op (health check) ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","is_error":false,"result":"nothing to do","num_turns":1}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ERRORS=1 MAX_NOOPS=5
grep -q 'agent produced no work in 1 turns' "$TMP/out.log" || { cat "$TMP/out.log"; fail "health check did not fire"; }
grep -q "1 consecutive errors" "$TMP/out.log" || { cat "$TMP/out.log"; fail "health check did not count as an error"; }
grep -q '"status":"error"' "$TMP/logs/results.jsonl" || fail "health-check iteration not recorded as an error"
: > "$TMP/logs/results.jsonl"
run_loop env MAX_ITERATIONS=2 MAX_NOOPS=5 MIN_TURNS=0
grep -q '"status":"noop"' "$TMP/logs/results.jsonl" || { cat "$TMP/out.log"; fail "MIN_TURNS=0 did not disable the health check"; }
rm -rf "$TMP"
echo "PASS: MIN_TURNS catches an agent that does nothing"

# --- 22: every iteration leaves a human-readable summary next to its log ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo change >> stub.txt
git add -A && git commit -qm "agent: summarized work"
printf '{"type":"result","subtype":"success","is_error":false,'
printf '"result":"wrote stub.txt. TASK_COMPLETE","total_cost_usd":0.42,"num_turns":7}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=1
summary="$(echo "$TMP"/logs/iter-1-*.summary)"
[[ -f "$summary" ]] || { ls "$TMP/logs"; fail "no summary file written"; }
grep -q '^status: kept$' "$summary" || { cat "$summary"; fail "summary missing status"; }
grep -q '^subtype: success$' "$summary" || { cat "$summary"; fail "summary missing subtype"; }
grep -q '^cost_usd: 0.42$' "$summary" || { cat "$summary"; fail "summary missing cost"; }
grep -q '^turns: 7$' "$summary" || { cat "$summary"; fail "summary missing turns"; }
grep -q 'agent: summarized work' "$summary" || { cat "$summary"; fail "summary missing the commit list"; }
grep -q 'stub.txt' "$summary" || { cat "$summary"; fail "summary missing the diffstat"; }
grep -q 'wrote stub.txt. TASK_COMPLETE' "$summary" || { cat "$summary"; fail "summary missing the final message"; }
rm -rf "$TMP"
echo "PASS: each iteration writes a summary file"

# --- 23: codex JSONL events give turns, tokens, and failures ---
make_env
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done
echo change >> stub.txt
git add -A && git commit -qm "agent: codex work"
printf '{"type":"item.completed","item":{"type":"command_execution"}}\n'
printf '{"type":"item.completed","item":{"type":"agent_message"}}\n'
if [[ -f "$TMP_FAIL" ]]; then
    printf '{"type":"error","message":"stream broke"}\n'
else
    printf '{"type":"turn.completed","usage":{"input_tokens":900,"cached_input_tokens":100,"output_tokens":50}}\n'
    printf 'done TASK_COMPLETE\n' > "$out"
fi
STUB
chmod +x "$TMP/bin/codex"
run_loop env AGENT=codex OPENAI_API_KEY=test MAX_ITERATIONS=1 TMP_FAIL="$TMP/nope"
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" || { cat "$TMP/out.log"; fail "codex done promise ignored"; }
grep -q '"subtype":"success"' "$TMP/logs/results.jsonl" || { cat "$TMP/logs/results.jsonl"; fail "codex subtype missing"; }
grep -q '"turns":2' "$TMP/logs/results.jsonl" || { cat "$TMP/logs/results.jsonl"; fail "codex turns miscounted"; }
grep -q '"tokens_in":900,"tokens_out":50' "$TMP/logs/results.jsonl" || fail "codex usage missing"
: > "$TMP/logs/results.jsonl"
touch "$TMP/fail"
run_loop env AGENT=codex OPENAI_API_KEY=test MAX_ERRORS=1 TMP_FAIL="$TMP/fail"
grep -q "1 consecutive errors" "$TMP/out.log" || { cat "$TMP/out.log"; fail "codex error event ignored"; }
rm -rf "$TMP"
echo "PASS: codex event stream yields turns, tokens, and errors"

# --- 24: the structured final message drives completion, not a substring ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
echo change >> stub.txt
git add -A && git commit -qm "agent: structured work"
printf '{"type":"result","subtype":"success","is_error":false,"result":"raw json",'
printf '"structured_output":{"done":true,"summary":"shipped the widget","blocked":false},'
printf '"num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=5
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" || { cat "$TMP/out.log"; fail "done:true did not stop the loop"; }
grep -q '"done":true,"blocked":false' "$TMP/logs/results.jsonl" \
    || { cat "$TMP/logs/results.jsonl"; fail "done/blocked not recorded"; }
grep -q 'shipped the widget' "$(echo "$TMP"/logs/iter-1-*.summary)" \
    || fail "summary field did not become the final message"
rm -rf "$TMP"

# done:false wins over a DONE_PROMISE that happens to sit in the summary.
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
echo change >> "stub-$RANDOM.txt"
git add -A && git commit -qm "agent: partial work"
printf '{"type":"result","subtype":"success","is_error":false,"result":"raw",'
printf '"structured_output":{"done":false,"summary":"still going. TASK_COMPLETE","blocked":false},'
printf '"num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=2
grep -q "signaled" "$TMP/out.log" && { cat "$TMP/out.log"; fail "done:false was overridden by the fallback substring"; }
grep -q "max iterations" "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected max-iterations stop"; }
grep -q '"done":false' "$TMP/logs/results.jsonl" || fail "done:false not recorded"
rm -rf "$TMP"

# blocked:true makes no progress, whatever it committed: it counts as a noop.
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
echo change >> "stub-$RANDOM.txt"
git add -A && git commit -qm "agent: stuck"
printf '{"type":"result","subtype":"success","is_error":false,"result":"raw",'
printf '"structured_output":{"done":false,"summary":"need credentials","blocked":true},'
printf '"num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=10 MAX_NOOPS=2
grep -q "agent reports blocked" "$TMP/out.log" || { cat "$TMP/out.log"; fail "blocked was not logged"; }
grep -q "2 consecutive no-progress" "$TMP/out.log" || { cat "$TMP/out.log"; fail "blocked did not count toward MAX_NOOPS"; }
[[ "$(wc -l < "$TMP/logs/results.jsonl")" -eq 2 ]] || fail "blocked stop came at the wrong iteration"
grep -q '"blocked":true' "$TMP/logs/results.jsonl" || fail "blocked not recorded"
rm -rf "$TMP"
echo "PASS: structured done/summary/blocked drive the loop, plain text still works"

# --- 25: DONE_CMD is the completion verifier, and it fails closed ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
echo change >> "stub-$RANDOM.txt"
git add -A && git commit -qm "agent: claims done"
printf '{"type":"result","subtype":"success","is_error":false,"result":"raw",'
printf '"structured_output":{"done":true,"summary":"finished","blocked":false},"num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=2 DONE_CMD='echo two tests still red; false'
grep -q "agent claimed done but DONE_CMD failed — continuing" "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "DONE_CMD failure did not reject the claim"; }
grep -q "max iterations" "$TMP/out.log" || { cat "$TMP/out.log"; fail "rejected claim still stopped the loop"; }
grep -q '^## Verifier failures$' "$TMP/repo/PROGRESS.md" \
    || { cat "$TMP/repo/PROGRESS.md" 2>/dev/null; fail "no verifier-failure section in PROGRESS.md"; }
grep -q '^- iteration 1: DONE_CMD failed: two tests still red' "$TMP/repo/PROGRESS.md" \
    || { cat "$TMP/repo/PROGRESS.md"; fail "verifier output not recorded in PROGRESS.md"; }
grep -q 'verifier rejected completion claim' < <(git -C "$TMP/repo" log --oneline) \
    || fail "the rejection note was not committed"
# ...and a green DONE_CMD lets the very same claim through.
run_loop env MAX_ITERATIONS=2 DONE_CMD=true
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" || { cat "$TMP/out.log"; fail "green DONE_CMD did not honor the claim"; }
rm -rf "$TMP"

# With no DONE_CMD, a done claim still needs CHECK_CMD green on that iteration.
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
printf '{"type":"result","subtype":"success","is_error":false,"result":"raw",'
printf '"structured_output":{"done":true,"summary":"nothing left to do","blocked":false},"num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=2 MAX_NOOPS=0 CHECK_CMD=false
grep -q "agent claimed done but CHECK_CMD failed — continuing" "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "an unverified done claim was honored"; }
grep -q "max iterations" "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected max-iterations stop"; }
rm -rf "$TMP"
echo "PASS: DONE_CMD gates completion and a rejection is written back to the repo"

# --- 26: EVALUATOR reviews the run in a fresh read-only session ---
make_env
printf 'review the work\n' > "$TMP/eval.md"
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
if [[ "$*" == *--disallowedTools* ]]; then          # the reviewer session
    grep -q -- '--permission-mode dontAsk' <<<"$*" || { echo "reviewer may still write" >&2; exit 3; }
    grep -q '^review the work$' <<<"$2" || { echo "evaluator prompt missing" >&2; exit 3; }
    n=0
    [[ -f "$EVAL_COUNT" ]] && n="$(cat "$EVAL_COUNT")"
    n=$((n + 1))
    printf '%s' "$n" > "$EVAL_COUNT"
    printf '{"type":"result","subtype":"success","is_error":false,"result":"raw",'
    if [[ "$n" -ge 2 ]]; then
        printf '"structured_output":{"verdict":"PASS","findings":"green"},'
    else
        printf '"structured_output":{"verdict":"NEEDS_WORK","findings":"- [ ] widget.py is a stub"},'
    fi
    printf '"total_cost_usd":0.05,"num_turns":3}\n'
    exit 0
fi
echo change >> "stub-$RANDOM.txt"
git add -A && git commit -qm "agent: claims done"
printf '{"type":"result","subtype":"success","is_error":false,"result":"raw",'
printf '"structured_output":{"done":true,"summary":"finished","blocked":false},'
printf '"total_cost_usd":0.10,"num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=5 EVALUATOR=true EVALUATOR_FILE="$TMP/eval.md" EVAL_COUNT="$TMP/eval-count"
grep -q 'evaluator: NEEDS_WORK' "$TMP/out.log" || { cat "$TMP/out.log"; fail "evaluator verdict not logged"; }
grep -q 'agent signaled done, evaluator PASS' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "a PASS verdict did not stop the loop"; }
[[ "$(wc -l < "$TMP/logs/results.jsonl")" -eq 2 ]] || { cat "$TMP/out.log"; fail "expected exactly two iterations"; }
grep -q '^## Evaluator findings (iteration 1)$' "$TMP/repo/PROGRESS.md" \
    || { cat "$TMP/repo/PROGRESS.md"; fail "findings not written to PROGRESS.md"; }
grep -q 'widget.py is a stub' "$TMP/repo/PROGRESS.md" || fail "findings body missing"
grep -q 'evaluator: needs work' < <(git -C "$TMP/repo" log --oneline) \
    || fail "findings were not committed"
[[ -f "$(echo "$TMP"/logs/iter-1-*.eval.log)" ]] || { ls "$TMP/logs"; fail "no evaluator session log"; }
grep -q 'total cost: [$]0.30 across 2 iterations' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "evaluator cost missing from the total"; }
rm -rf "$TMP"
echo "PASS: the evaluator gates completion and its findings come back as a commit"

# --- 27: the initializer block appears only while PROGRESS.md is missing ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
if [[ -f PROGRESS.md ]]; then printf '%s' "$2" > "$PROMPT_DUMP.after"
else printf '%s' "$2" > "$PROMPT_DUMP.first"; printf 'notes\n' > PROGRESS.md; fi
echo change >> "stub-$RANDOM.txt"
git add -A && git commit -qm "agent: work"
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=2 PROMPT_DUMP="$TMP/dump"
grep -q 'initializer session (no PROGRESS.md)' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "initializer session not logged"; }
grep -q '^<initializer>$' "$TMP/dump.first" || { cat "$TMP/dump.first"; fail "no initializer block on the first session"; }
grep -q 'EXIT' "$TMP/dump.first" || fail "initializer does not tell the agent to exit"
grep -q '<initializer>' "$TMP/dump.after" && { cat "$TMP/dump.after"; fail "initializer block survived PROGRESS.md"; }
rm -rf "$TMP"
echo "PASS: the first session is an initializer, later ones are not"

# --- 28: codex gets a strict schema file, --ephemeral, and returns JSON ---
make_env
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
out="" schema="" prev=""
for a in "$@"; do
    [[ "$prev" == -o ]] && out="$a"
    [[ "$prev" == --output-schema ]] && schema="$a"
    prev="$a"
done
[[ -f "$schema" ]] || { echo "no schema file at '$schema'" >&2; exit 3; }
grep -q '"additionalProperties":false' "$schema" || { echo "schema not strict" >&2; exit 3; }
grep -q '"required":\["done","summary","blocked"\]' "$schema" || { echo "blocked not required" >&2; exit 3; }
grep -q '^</loop-context>$' <<<"$2" || { echo "preamble missing" >&2; exit 3; }
grep -q '^do the thing$' <<<"$2" || { echo "framework prompt missing from codex turn" >&2; exit 3; }
echo change >> stub.txt
git add -A && git commit -qm "agent: codex structured work"
printf '{"type":"item.completed","item":{"type":"agent_message"}}\n'
printf '{"type":"item.completed","item":{"type":"command_execution"}}\n'
printf '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}\n'
printf '{"done":true,"summary":"codex finished the widget","blocked":false}\n' > "$out"
STUB
chmod +x "$TMP/bin/codex"
run_loop env AGENT=codex OPENAI_API_KEY=test MAX_ITERATIONS=2 ARGV_LOG="$TMP/argv.log"
grep -q -- '--ephemeral' "$TMP/argv.log" || { cat "$TMP/argv.log"; fail "--ephemeral not passed to codex"; }
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" || { cat "$TMP/out.log"; fail "codex structured done ignored"; }
grep -q '"done":true,"blocked":false' "$TMP/logs/results.jsonl" || fail "codex done/blocked not recorded"
grep -q 'codex finished the widget' "$(echo "$TMP"/logs/iter-1-*.summary)" \
    || fail "codex summary did not become the final message"
rm -rf "$TMP"
echo "PASS: codex gets a strict output schema and an ephemeral session"

# --- 29: .mill/STOP present at start → not a single session runs ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
touch "$RAN_MARKER"
printf '{"type":"result","is_error":false,"result":"ran"}\n'
STUB
chmod +x "$TMP/bin/claude"
mkdir -p "$TMP/repo/.mill"
: > "$TMP/repo/.mill/STOP"
run_loop env MAX_ITERATIONS=3 RAN_MARKER="$TMP/ran"
grep -q 'stop file present — finishing after this iteration' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "stop file was not noticed"; }
grep -q 'loop finished after 0 iterations: stop file' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "expected a stop-file stop with no iterations"; }
[[ ! -e "$TMP/ran" ]] || fail "a session started despite the stop file"
[[ ! -s "$TMP/logs/results.jsonl" ]] || { cat "$TMP/logs/results.jsonl"; fail "an iteration was recorded"; }
[[ ! -e "$TMP/repo/.mill/STOP" ]] || fail "the stop file was not consumed on exit"
[[ -z "$(git -C "$TMP/repo" status --porcelain --untracked-files=all)" ]] \
    || { git -C "$TMP/repo" status --short; fail ".mill/ is visible to git"; }
grep -qxF '.mill/' "$TMP/repo/.git/info/exclude" || fail ".mill/ was not excluded"
# The exclude append is idempotent: a second run must not add a second line.
run_loop env MAX_ITERATIONS=1
[[ "$(grep -cxF '.mill/' "$TMP/repo/.git/info/exclude")" -eq 1 ]] \
    || { cat "$TMP/repo/.git/info/exclude"; fail "exclude entry appended twice"; }
rm -rf "$TMP"
echo "PASS: .mill/STOP prevents any session and is git-excluded"

# --- 30: a stop file dropped mid-session finishes that iteration, then stops ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
mkdir -p .mill && : > .mill/STOP
echo change >> stub.txt
git add -A && git commit -qm "agent: work then brake"
printf '{"type":"result","subtype":"success","is_error":false,"result":"more later","num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=5
[[ "$(wc -l < "$TMP/logs/results.jsonl")" -eq 1 ]] \
    || { cat "$TMP/out.log"; fail "a second session started after the stop file"; }
grep -q '"status":"kept"' "$TMP/logs/results.jsonl" || fail "the braked iteration was not kept"
grep -q 'loop finished after 1 iterations: stop file' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "expected a stop-file stop reason"; }
[[ ! -e "$TMP/repo/.mill/STOP" ]] || fail "the stop file was not consumed on exit"
rm -rf "$TMP"
echo "PASS: a mid-session stop file finishes the iteration and stops"

# --- 31: .mill/STEER.md is a one-shot instruction, and survives a revert ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
n=1
[[ -f "$COUNT" ]] && n=$(( $(cat "$COUNT") + 1 ))
printf '%s' "$n" > "$COUNT"
printf '%s' "$2" > "$PROMPT_DUMP.$n"
echo change >> "stub-$n.txt"
git add -A && git commit -qm "agent: work $n"
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
mkdir -p "$TMP/repo/.mill"
printf 'drop everything and fix the flaky test\nsecond line\n' > "$TMP/repo/.mill/STEER.md"
run_loop env MAX_ITERATIONS=2 COUNT="$TMP/count" PROMPT_DUMP="$TMP/dump"
grep -q 'steer: drop everything and fix the flaky test' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "steer was not logged"; }
grep -q '^<operator-steer>$' "$TMP/dump.1" || { cat "$TMP/dump.1"; fail "steer not injected into the prompt"; }
grep -q 'drop everything and fix the flaky test' "$TMP/dump.1" || fail "steer body missing"
grep -q 'second line' "$TMP/dump.1" || fail "steer truncated to its first line"
grep -q 'overrides the mission' "$TMP/dump.1" || { cat "$TMP/dump.1"; fail "steer not framed as an override"; }
grep -q 'operator-steer' "$TMP/dump.2" && { cat "$TMP/dump.2"; fail "steer was not one-shot"; }
[[ ! -e "$TMP/repo/.mill/STEER.md" ]] || fail "the steer file was not consumed"
head -1 "$TMP/logs/results.jsonl" | grep -q '"steered":true' \
    || { cat "$TMP/logs/results.jsonl"; fail "steered flag not recorded"; }
tail -1 "$TMP/logs/results.jsonl" | grep -q '"steered":true' \
    && fail "the second iteration was still marked steered"
rm -rf "$TMP"

# A reverting iteration must not take the operator's drop-box with it.
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo change >> stub.txt
git add -A && git commit -qm "agent: bad work"
printf '{"type":"result","is_error":false,"result":"made changes","num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
mkdir -p "$TMP/repo/.mill"
printf 'still pending\n' > "$TMP/repo/.mill/STEER.md.next"
run_loop env MAX_ITERATIONS=1 MAX_NOOPS=0 CHECK_CMD=false
grep -q '"status":"reverted"' "$TMP/logs/results.jsonl" || fail "iteration was not reverted"
[[ -f "$TMP/repo/.mill/STEER.md.next" ]] || fail "the revert deleted the .mill drop-box"
rm -rf "$TMP"
echo "PASS: STEER.md is one-shot and .mill/ survives a revert"

# --- 32: METRIC_CMD ratchets on the number, not just the check ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
n=1
[[ -f "$COUNT" ]] && n=$(( $(cat "$COUNT") + 1 ))
printf '%s' "$n" > "$COUNT"
printf '%s' "$2" > "$PROMPT_DUMP.$n"
case "$n" in
    1) printf '0.9\n'  > "$SCORE" ;;
    2) printf '0.95\n' > "$SCORE" ;;
    *) printf '0.8\n'  > "$SCORE" ;;
esac
echo change >> "stub-$n.txt"
git add -A && git commit -qm "agent: attempt $n"
printf '{"type":"result","subtype":"success","is_error":false,"result":"raw",'
printf '"structured_output":{"done":false,"summary":"attempt %s\\tof three","blocked":false},' "$n"
printf '"num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
printf '1.0\n' > "$TMP/score"
head_before="$(git -C "$TMP/repo" rev-parse HEAD)"
run_loop env MAX_ITERATIONS=3 MAX_NOOPS=0 COUNT="$TMP/count" PROMPT_DUMP="$TMP/dump" \
    SCORE="$TMP/score" METRIC_CMD="cat $TMP/score"
grep -q 'baseline metric: 1.0' "$TMP/out.log" || { cat "$TMP/out.log"; fail "no baseline metric"; }
grep -q 'iteration 1: kept (metric 0.9 → best 1.0)' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "an improvement was not kept"; }
grep -q 'metric 0.95 not better than 0.9 — reverting' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "a regression was not reverted"; }
grep -q 'iteration 3: kept (metric 0.8 → best 0.9)' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "the third improvement was not kept"; }
[[ "$(git -C "$TMP/repo" rev-list --count "$head_before..HEAD" 2>/dev/null)" -eq 2 ]] \
    || { git -C "$TMP/repo" log --oneline; fail "expected exactly two surviving iterations"; }
sed -n 1p "$TMP/logs/results.jsonl" | grep -q '"metric":0.9,"best":0.9' \
    || { cat "$TMP/logs/results.jsonl"; fail "iteration 1 metric/best not recorded"; }
sed -n 2p "$TMP/logs/results.jsonl" | grep -q '"status":"reverted".*"metric":0.95,"best":0.9' \
    || { cat "$TMP/logs/results.jsonl"; fail "the reverted iteration kept the old best"; }
sed -n 3p "$TMP/logs/results.jsonl" | grep -q '"metric":0.8,"best":0.8' \
    || { cat "$TMP/logs/results.jsonl"; fail "iteration 3 metric/best not recorded"; }
[[ "$(head -1 "$TMP/logs/metrics.tsv")" == "$(printf 'iter\tsha\tmetric\tbest\tstatus\tsummary')" ]] \
    || { head -1 "$TMP/logs/metrics.tsv"; fail "metrics.tsv header malformed"; }
[[ "$(wc -l < "$TMP/logs/metrics.tsv")" -eq 4 ]] || { cat "$TMP/logs/metrics.tsv"; fail "expected 3 metric rows"; }
awk -F'\t' 'NR == 3 && ($3 != "0.95" || $4 != "0.9" || $5 != "reverted") { exit 1 }' "$TMP/logs/metrics.tsv" \
    || { cat "$TMP/logs/metrics.tsv"; fail "reverted row wrong"; }
awk -F'\t' 'NR == 4 && $6 != "attempt 3of three" { exit 1 }' "$TMP/logs/metrics.tsv" \
    || { cat "$TMP/logs/metrics.tsv"; fail "summary column not tab-stripped"; }
grep -q 'Current best METRIC: 1.0 (min)' "$TMP/dump.1" || { cat "$TMP/dump.1"; fail "baseline missing from the preamble"; }
grep -q 'Current best METRIC: 0.9 (min)' "$TMP/dump.2" || { cat "$TMP/dump.2"; fail "best missing from the preamble"; }
grep -q 'Current best METRIC: 0.9 (min)' "$TMP/dump.3" || { cat "$TMP/dump.3"; fail "a reverted iteration moved the best"; }
rm -rf "$TMP"
echo "PASS: METRIC_CMD keeps only strict improvements and logs the ledger"

# --- 33: METRIC_DIRECTION=max flips the keep rule ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
printf '0.9\n' > "$SCORE"
echo change >> "stub-$RANDOM.txt"
git add -A && git commit -qm "agent: lower score"
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
printf '1.0\n' > "$TMP/score"
head_before="$(git -C "$TMP/repo" rev-parse HEAD)"
run_loop env MAX_ITERATIONS=1 MAX_NOOPS=0 SCORE="$TMP/score" \
    METRIC_CMD="cat $TMP/score" METRIC_DIRECTION=max
grep -q 'metric 0.9 not better than 1.0 — reverting' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "max direction kept a lower score"; }
[[ "$(git -C "$TMP/repo" rev-parse HEAD)" == "$head_before" ]] || fail "the regression was not reverted"
# ...and the same number is an improvement under min.
: > "$TMP/logs/results.jsonl"
printf '1.0\n' > "$TMP/score"
run_loop env MAX_ITERATIONS=1 MAX_NOOPS=0 SCORE="$TMP/score" METRIC_CMD="cat $TMP/score"
grep -q 'iteration 1: kept (metric 0.9 → best 1.0)' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "min direction rejected a lower score"; }
rm -rf "$TMP"
echo "PASS: METRIC_DIRECTION picks which way is better"

# --- 34: an unreadable metric reverts, and a failing baseline is fatal ---
make_env
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --help ]] && exit 0
printf 'benchmark crashed\n' > "$SCORE"
echo change >> "stub-$RANDOM.txt"
git add -A && git commit -qm "agent: broke the benchmark"
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","num_turns":4}\n'
STUB
chmod +x "$TMP/bin/claude"
printf '1.0\n' > "$TMP/score"
head_before="$(git -C "$TMP/repo" rev-parse HEAD)"
run_loop env MAX_ITERATIONS=1 MAX_NOOPS=0 SCORE="$TMP/score" METRIC_CMD="cat $TMP/score"
grep -q 'metric unparseable — reverting' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "a non-numeric metric was accepted"; }
[[ "$(git -C "$TMP/repo" rev-parse HEAD)" == "$head_before" ]] || fail "unparseable metric was not reverted"
grep -q '"metric":null,"best":1.0' "$TMP/logs/results.jsonl" \
    || { cat "$TMP/logs/results.jsonl"; fail "unparseable metric not recorded as null"; }
# No baseline, no ratchet: refuse to start rather than keep everything.
if run_loop_raw env MAX_ITERATIONS=1 METRIC_CMD=false; then fail "loop ran without a metric baseline"; fi
grep -q 'no baseline number' "$TMP/out.log" || { cat "$TMP/out.log"; fail "expected a fatal baseline error"; }
if run_loop_raw env MAX_ITERATIONS=1 METRIC_CMD=true METRIC_DIRECTION=sideways; then
    fail "an invalid METRIC_DIRECTION was accepted"
fi
grep -q 'METRIC_DIRECTION must be min or max' "$TMP/out.log" \
    || { cat "$TMP/out.log"; fail "expected a direction validation error"; }
rm -rf "$TMP"
echo "PASS: unparseable metrics revert and a missing baseline is fatal"

echo "OK: all loop.sh smoke tests passed"
