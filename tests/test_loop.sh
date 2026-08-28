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
    git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
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

# --- 7: the prompt file keeps its own line structure after the preamble ---
make_env
printf '# Task
do the thing
' > "$TMP/prompt.md"
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
grep -q '^# Task$' <<<"$2" || { echo "prompt heading not at line start" >&2; exit 3; }
grep -q '^</loop-context>$' <<<"$2" || { echo "preamble not terminated" >&2; exit 3; }
printf '{"type":"result","is_error":false,"result":"ok TASK_COMPLETE"}
'
STUB
chmod +x "$TMP/bin/claude"
run_loop env MAX_ITERATIONS=1
grep -q "signaled TASK_COMPLETE" "$TMP/out.log" || { cat "$TMP/out.log"; fail "prompt was malformed"; }
rm -rf "$TMP"
echo "PASS: preamble and prompt are joined with a blank line"

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

echo "OK: all loop.sh smoke tests passed"
