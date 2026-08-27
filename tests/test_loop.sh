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

run_loop() {
    HOME="$TMP/home" PATH="$TMP/bin:$PATH" ANTHROPIC_API_KEY=test \
    REPO_DIR="$TMP/repo" LOG_DIR="$TMP/logs" PROMPT_FILE="$TMP/prompt.md" \
    LOOP_DELAY=0 ERROR_BACKOFF=0 "$@" bash "$ROOT/loop.sh" >"$TMP/out.log" 2>&1 \
        || { cat "$TMP/out.log"; fail "loop.sh exited nonzero"; }
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

echo "OK: all loop.sh smoke tests passed"
