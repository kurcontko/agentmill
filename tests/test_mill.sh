#!/usr/bin/env bash
set -euo pipefail
# Smoke tests for the mill CLI with a stubbed `docker`. No network, no docker.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

make_env() {  # sandbox holding its own copy of mill, so MILL_DIR is disposable
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin" "$TMP/a/api" "$TMP/b/api"
    cp "$ROOT/mill" "$ROOT/.env.example" "$TMP/"
    cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY:-}" >> "$DOCKER_ENV_LOG"
exit 0
STUB
    chmod +x "$TMP/bin/docker"
    for r in "$TMP/a/api" "$TMP/b/api"; do
        git -C "$r" init -q
        printf '# Mission\n\nbuild it\n' > "$r/MILL.md"
        git -C "$r" add MILL.md
        git -C "$r" -c user.email=t@t -c user.name=t commit -qm init
    done
    export AGENTMILL_CONFIG="$TMP/config"   # the user-level config file
    export DOCKER_LOG="$TMP/docker.log"
    export DOCKER_ENV_LOG="$TMP/docker-env.log"
    : > "$DOCKER_LOG"
    : > "$DOCKER_ENV_LOG"
}

mill() { PATH="$TMP/bin:$PATH" bash "$TMP/mill" "$@"; }
mill_in() { local d="$1"; shift; (cd "$d" && mill "$@"); }
run_line() { grep '^run --rm --name' "$DOCKER_LOG" | tail -1; }

# --- 1: config file is read whole (no trailing newline) and the caller's env wins ---
make_env
printf 'ANTHROPIC_API_KEY=fromfile\nGIT_EMAIL=fromfile' > "$TMP/config"   # deliberately unterminated
mill -C "$TMP/a/api" run >/dev/null || fail "mill run exited nonzero"
run_line | grep -q -- '-e GIT_EMAIL=fromfile' || fail "unterminated last the config file line was dropped"
run_line | grep -q -- '-e ANTHROPIC_API_KEY' || fail "API key name was not forwarded"
run_line | grep -q -- '--label agentmill.stop-timeout=60' || { run_line; fail "resolved stop timeout not recorded as a label"; }
run_line | grep -q -- '-e ANTHROPIC_API_KEY=' && fail "API key value leaked into docker argv"
grep -q '^ANTHROPIC_API_KEY=fromfile$' "$DOCKER_ENV_LOG" || fail "the config file API key was not exported to docker"
: > "$DOCKER_LOG"
: > "$DOCKER_ENV_LOG"
GIT_EMAIL=fromcaller ANTHROPIC_API_KEY=fromcaller mill -C "$TMP/a/api" run >/dev/null \
    || fail "mill exited nonzero when a the config file var was already set in the environment"
run_line | grep -q -- '-e GIT_EMAIL=fromcaller' || fail "caller env did not override the config file"
run_line | grep -q -- '-e ANTHROPIC_API_KEY=' && fail "caller API key leaked into docker argv"
grep -q '^ANTHROPIC_API_KEY=fromcaller$' "$DOCKER_ENV_LOG" || fail "caller-only value not forwarded to docker"
rm -rf "$TMP"
echo "PASS: config file parsing and credential-safe caller-env forwarding"

# --- 2: unknown flags are rejected, not silently swallowed ---
make_env
if mill -C "$TMP/a/api" run --iteration 5 >/dev/null 2>"$TMP/err"; then
    fail "typo'd flag was accepted"
fi
grep -q "unknown option" "$TMP/err" || { cat "$TMP/err"; fail "expected an unknown-option error"; }
rm -rf "$TMP"
echo "PASS: unknown options are rejected"

# --- 3: repos sharing a basename get distinct containers and log dirs ---
make_env
mill -C "$TMP/a/api" run >/dev/null
name_a="$(run_line | sed 's/.*--name \([^ ]*\).*/\1/')"
: > "$DOCKER_LOG"
mill -C "$TMP/b/api" run >/dev/null
name_b="$(run_line | sed 's/.*--name \([^ ]*\).*/\1/')"
[[ "$name_a" != "$name_b" ]] || fail "same-basename repos collide on container name: $name_a"
run_line | grep -q -- "-v $TMP/logs/$name_b:/workspace/logs" || fail "log dir is not per-container"
rm -rf "$TMP"
echo "PASS: distinct container and log dir per checkout"

# --- 4: aliases of one checkout get the same container identity and mount ---
make_env
ln -s "$TMP/a/api" "$TMP/api-link"
mill -C "$TMP/a/../a/api/" run >/dev/null
name_real="$(run_line | sed 's/.*--name \([^ ]*\).*/\1/')"
: > "$DOCKER_LOG"
mill -C "$TMP/api-link" run >/dev/null
name_link="$(run_line | sed 's/.*--name \([^ ]*\).*/\1/')"
[[ "$name_real" == "$name_link" ]] || fail "path aliases bypassed the checkout identity: $name_real != $name_link"
canonical_repo="$(cd -P "$TMP/a/api" && pwd)"
run_line | grep -q -- "-v $canonical_repo:$canonical_repo" \
    || { run_line; fail "checkout was not mounted at its canonical host path"; }
rm -rf "$TMP"
echo "PASS: checkout paths are canonicalized before naming and mounting"

# --- 5: a linked worktree keeps initialized submodule gitdir paths valid ---
make_env
mkdir -p "$TMP/sub-origin"
git -C "$TMP/sub-origin" init -q
echo baseline > "$TMP/sub-origin/tracked.txt"
git -C "$TMP/sub-origin" add tracked.txt
git -C "$TMP/sub-origin" -c user.email=t@t -c user.name=t commit -qm init
git -c protocol.file.allow=always -C "$TMP/a/api" submodule add -q \
    "$TMP/sub-origin" vendor/sub
git -C "$TMP/a/api" -c user.email=t@t -c user.name=t commit -qam submodule
git -C "$TMP/a/api" worktree add -q "$TMP/a/api-b" -b agent-b
git -c protocol.file.allow=always -C "$TMP/a/api-b" submodule update -q --init
mill -C "$TMP/a/api-b" run >/dev/null
common="$(sed -n 's/^gitdir: *//p' "$TMP/a/api-b/.git")"   # exactly what git will dereference
common="${common%/worktrees/*}"
run_line | grep -q -- "-v $common:$common" || { run_line; fail "worktree git dir not mounted"; }
# ...and every recorded worktree .git file, so `git worktree prune` inside sees them.
wt_git="$(head -1 "$common"/worktrees/*/gitdir)"
run_line | grep -q -- "-v $wt_git:$wt_git:ro" || { run_line; fail "worktree .git file not mounted"; }
canonical_wt="$(cd -P "$TMP/a/api-b" && pwd)"
run_line | grep -q -- "-v $canonical_wt:$canonical_wt" || { run_line; fail "worktree relocated in container"; }
run_line | grep -q -- '-v [^ ]*:/workspace/repo' && { run_line; fail "worktree was relocated to /workspace/repo"; }
grep -q '^gitdir: \.\.' "$TMP/a/api-b/vendor/sub/.git" \
    || fail "fixture did not create the relative submodule gitdir under review"
rm -rf "$TMP"
echo "PASS: linked worktrees preserve initialized submodule paths"

# --- 6: config file values: inline comments, quotes, whitespace; host-only keys stay home ---
make_env
cat > "$TMP/config" <<'ENV'
ANTHROPIC_API_KEY=sk-test   
MODEL=opus   # Claude model
SETUP_CMD="uv sync"
CHECK_CMD='pytest -q # not a comment'
PATH=/nowhere
AGENTMILL_IMAGE=custom-image
ENV
mill -C "$TMP/a/api" run >/dev/null || fail "mill run exited nonzero"
run_line | grep -q -- '-e ANTHROPIC_API_KEY -e' || { run_line; fail "API key name missing"; }
run_line | grep -q -- 'sk-test' && { run_line; fail "API key value exposed in docker argv"; }
grep -q '^ANTHROPIC_API_KEY=sk-test$' "$DOCKER_ENV_LOG" || fail "trailing whitespace kept in API key"
run_line | grep -q -- '-e MODEL=opus -e' || { run_line; fail "inline comment kept"; }
run_line | grep -q -- '-e SETUP_CMD=uv sync -e' || { run_line; fail "double quotes kept"; }
run_line | grep -q -- '-e CHECK_CMD=pytest -q # not a comment -e REPO_DIR=' || { run_line; fail "single quotes mishandled"; }
run_line | grep -q -- '-e PATH=' && fail "PATH from the config file forwarded to the container"
run_line | grep -q -- ' custom-image$' || { run_line; fail "AGENTMILL_IMAGE from the config file ignored"; }
rm -rf "$TMP"
echo "PASS: config file quoting, comments, and host-only keys"

# --- 7: mill stop sends TERM and waits before removing containers ---
make_env
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
[[ "$*" == "ps -aq --filter label=agentmill" ]] && printf 'aaa\nbbb\n'
[[ "$*" == "ps -q --filter label=agentmill" ]] && printf 'aaa\nbbb\n'
[[ "$*" == inspect*agentmill-api-* ]] && printf '330\n'
exit 0
STUB
mill -C "$TMP/a/api" stop >/dev/null || fail "mill stop exited nonzero"
grep -q '^stop --time 330 agentmill-api-' "$DOCKER_LOG" || { cat "$DOCKER_LOG"; fail "stop-timeout label not honored"; }
grep -q '^rm agentmill-api-' "$DOCKER_LOG" || { cat "$DOCKER_LOG"; fail "checkout container not removed after stop"; }
stop_line="$(grep -n '^stop --time 330 agentmill-api-' "$DOCKER_LOG" | cut -d: -f1)"
rm_line="$(grep -n '^rm agentmill-api-' "$DOCKER_LOG" | cut -d: -f1)"
[[ "$stop_line" -lt "$rm_line" ]] || fail "checkout was removed before graceful stop completed"
grep -q '^stop --time 60 aaa' "$DOCKER_LOG" && fail "other containers were stopped"
grep -q '^network rm' "$DOCKER_LOG" && fail "network removed while other agents run"
: > "$DOCKER_LOG"
mill stop --all >/dev/null || fail "mill stop --all exited nonzero"
grep -q '^stop --time 60 aaa' "$DOCKER_LOG" || { cat "$DOCKER_LOG"; fail "mill stop did not gracefully stop everything"; }
grep -q '^rm aaa' "$DOCKER_LOG" || { cat "$DOCKER_LOG"; fail "mill stop did not remove stopped containers"; }
rm -rf "$TMP"
echo "PASS: mill stop is graceful and per-checkout with a repo, global without"

# --- 8: DinD is polled to readiness, with a bounded failure path ---
make_env
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$*" in
    "network inspect agentmill"|"container inspect agentmill-dind") exit 1 ;;
    "exec agentmill-dind docker -H tcp://127.0.0.1:2375 info")
        count=0
        [[ -f "$DIND_COUNT" ]] && count="$(cat "$DIND_COUNT")"
        count=$((count + 1))
        printf '%s' "$count" > "$DIND_COUNT"
        [[ "$count" -ge 3 ]]
        exit
        ;;
esac
exit 0
STUB
cat > "$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/docker" "$TMP/bin/sleep"
export DIND_COUNT="$TMP/dind-count"
mill -C "$TMP/a/api" run --dind >"$TMP/out" || { cat "$TMP/out"; fail "ready dind was rejected"; }
[[ "$(cat "$DIND_COUNT")" -eq 3 ]] || fail "mill did not poll dind readiness"
ready_line="$(grep -n '^exec agentmill-dind docker -H tcp://127.0.0.1:2375 info$' "$DOCKER_LOG" | tail -1 | cut -d: -f1)"
agent_line="$(grep -n '^run --rm --name agentmill-api-' "$DOCKER_LOG" | cut -d: -f1)"
[[ "$ready_line" -lt "$agent_line" ]] || fail "agent container started before dind was ready"

: > "$DOCKER_LOG"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$*" in
    "network inspect agentmill"|"container inspect agentmill-dind"|"exec agentmill-dind docker -H tcp://127.0.0.1:2375 info") exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/docker"
if DIND_READY_TIMEOUT=0 mill -C "$TMP/a/api" run --dind >"$TMP/out" 2>"$TMP/err"; then
    fail "mill started the agent when dind never became ready"
fi
grep -q 'did not become ready within 0s' "$TMP/err" \
    || { cat "$TMP/err"; fail "missing bounded dind readiness error"; }
grep -q '^run --rm --name agentmill-api-' "$DOCKER_LOG" \
    && fail "agent container started after dind readiness failure"
rm -rf "$TMP"
echo "PASS: dind readiness is bounded and precedes the agent"

# --- 9: the checkout is the cwd (any subdirectory); -C overrides; outside a repo fails ---
make_env
mkdir -p "$TMP/a/api/src/deep"
mill_in "$TMP/a/api/src/deep" run >/dev/null || fail "mill run from a subdirectory failed"
canonical="$(cd -P "$TMP/a/api" && pwd)"
run_line | grep -q -- "-e REPO_DIR=$canonical " || { run_line; fail "cwd was not resolved to the repo root"; }
: > "$DOCKER_LOG"
mill_in "$TMP/a/api" -C "$TMP/b/api" run >/dev/null || fail "mill -C failed"
run_line | grep -q -- "-e REPO_DIR=$(cd -P "$TMP/b/api" && pwd) " || { run_line; fail "-C was ignored"; }
: > "$DOCKER_LOG"
mkdir -p "$TMP/norepo"
if mill_in "$TMP/norepo" run >/dev/null 2>"$TMP/err"; then fail "mill ran outside a git repo"; fi
grep -q 'not inside a git repository' "$TMP/err" || { cat "$TMP/err"; fail "expected a not-a-repo error"; }
if mill -C "$TMP/a/api" run "$TMP/b/api" >/dev/null 2>"$TMP/err"; then fail "positional repo was accepted"; fi
rm -rf "$TMP"
echo "PASS: checkout resolves from cwd or -C"

# --- 10: MILL.md frontmatter is forwarded; env beats it; it beats the config file; missing MILL.md refused ---
make_env
printf 'CHECK_CMD=from-config\nMODEL=from-config\n' > "$TMP/config"
cat > "$TMP/a/api/MILL.md" <<'MD'
---
check_cmd: "pytest -q"   # the ratchet
model: sonnet
custom_flag: yes
empty_one:
---
# Mission
MD
mill -C "$TMP/a/api" run >/dev/null || fail "mill run with frontmatter failed"
run_line | grep -q -- '-e CHECK_CMD=pytest -q ' || { run_line; fail "frontmatter check_cmd not forwarded"; }
run_line | grep -q -- '-e MODEL=sonnet ' || { run_line; fail "MILL.md did not override the config file"; }
run_line | grep -q -- '-e CUSTOM_FLAG=yes ' || { run_line; fail "custom frontmatter key not forwarded"; }
run_line | grep -q -- '-e EMPTY_ONE' && { run_line; fail "empty frontmatter value forwarded"; }
: > "$DOCKER_LOG"
MODEL=from-env mill -C "$TMP/a/api" run >/dev/null
run_line | grep -q -- '-e MODEL=from-env ' || { run_line; fail "environment did not beat MILL.md"; }
rm "$TMP/b/api/MILL.md"
if mill -C "$TMP/b/api" run >/dev/null 2>"$TMP/err"; then fail "mill ran without MILL.md"; fi
grep -q 'no MILL.md' "$TMP/err" || { cat "$TMP/err"; fail "expected a missing-MILL.md error"; }
rm -rf "$TMP"
echo "PASS: MILL.md frontmatter and precedence"

# --- 11: mill init writes MILL.md + config once; logs are per checkout; symlinked mill finds MILL_DIR ---
make_env
rm "$TMP/b/api/MILL.md"
mill -C "$TMP/b/api" init >/dev/null || fail "mill init failed"
[[ -f "$TMP/b/api/MILL.md" ]] || fail "init did not write MILL.md"
[[ -f "$TMP/config" ]] || fail "init did not create the config file"
grep -q ANTHROPIC_API_KEY "$TMP/config" || fail "config file not seeded from .env.example"
mill -C "$TMP/b/api" init | grep -q 'already exists' || fail "init overwrote MILL.md"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
[[ "$1" == ps ]] && echo cid
exit 0
STUB
mill -C "$TMP/a/api" logs >/dev/null || fail "mill logs failed"
grep -q '^logs -f agentmill-api-' "$DOCKER_LOG" || { cat "$DOCKER_LOG"; fail "logs did not target the checkout's container"; }
mkdir -p "$TMP/bin2"; ln -s "$TMP/mill" "$TMP/bin2/mill"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
STUB
: > "$DOCKER_LOG"
(cd "$TMP/a/api" && PATH="$TMP/bin:$PATH" bash "$TMP/bin2/mill" run >/dev/null) || fail "symlinked mill failed"
run_line | grep -q -- "-v $TMP/prompts:/prompts:ro" || { run_line; fail "symlinked mill lost MILL_DIR"; }
rm -rf "$TMP"
echo "PASS: init, per-checkout logs, symlink-safe MILL_DIR"

# --- 12: budget/turn caps are forwarded to the container ---
make_env
cat > "$TMP/config" <<'ENV'
MAX_TURNS=12
MIN_TURNS=3
MAX_BUDGET_USD=1.50
MAX_TOTAL_BUDGET_USD=20
ENV
mill -C "$TMP/a/api" run >/dev/null || fail "mill run exited nonzero"
for kv in 'MAX_TURNS=12' 'MIN_TURNS=3' 'MAX_BUDGET_USD=1.50' 'MAX_TOTAL_BUDGET_USD=20'; do
    run_line | grep -q -- "-e $kv " || { run_line; fail "$kv not forwarded to the container"; }
done
rm -rf "$TMP"
echo "PASS: budget and turn caps reach the container"

# --- 12b: completion-gate and hygiene keys reach the container ---
make_env
cat > "$TMP/config" <<'ENV'
DONE_CMD=pytest -q
EVALUATOR=true
CLAUDE_BARE=true
ENV
mill -C "$TMP/a/api" run >/dev/null || fail "mill run exited nonzero"
for kv in 'DONE_CMD=pytest -q' 'EVALUATOR=true' 'CLAUDE_BARE=true'; do
    run_line | grep -q -- "-e $kv " || { run_line; fail "$kv not forwarded to the container"; }
done
rm -rf "$TMP"
echo "PASS: DONE_CMD, EVALUATOR, and CLAUDE_BARE reach the container"

# --- 13: mill logs shows summaries, --raw the event stream, --results a table ---
make_env
mill -C "$TMP/a/api" run >/dev/null
name="$(run_line | sed 's/.*--name \([^ ]*\).*/\1/')"
logs="$TMP/logs/$name"
printf '{"iter":1,"agent":"claude","status":"kept","commits":2,"head":"abc1234","ts":"t","subtype":"success","cost_usd":0.42,"duration_s":83,"turns":7}\n' \
    > "$logs/results.jsonl"
printf 'raw event stream\n' > "$logs/iter-1-abc1234.log"
printf 'iteration: 1\nstatus: kept\n' > "$logs/iter-1-abc1234.summary"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
exit 0
STUB
chmod +x "$TMP/bin/docker"
mill -C "$TMP/a/api" logs > "$TMP/out" || { cat "$TMP/out"; fail "mill logs (summaries) failed"; }
grep -q '=== iter-1-abc1234.summary ===' "$TMP/out" || { cat "$TMP/out"; fail "summaries not shown"; }
grep -q '^status: kept$' "$TMP/out" || { cat "$TMP/out"; fail "summary body not shown"; }
if command -v jq >/dev/null; then
    mill -C "$TMP/a/api" logs --results > "$TMP/out" || { cat "$TMP/out"; fail "mill logs --results failed"; }
    grep -q '^ITER ' "$TMP/out" || { cat "$TMP/out"; fail "results table has no header"; }
    grep -q '^1 *kept *2 *[$]0.42 *7 *83s$' "$TMP/out" || { cat "$TMP/out"; fail "results row malformed"; }
fi
# --raw ends in `tail -f`; job control gives it its own group to terminate.
set -m
PATH="$TMP/bin:$PATH" bash "$TMP/mill" -C "$TMP/a/api" logs --raw > "$TMP/out" 2>&1 &
raw_pid=$!
for _ in $(seq 1 50); do grep -q 'raw event stream' "$TMP/out" && break; sleep 0.1; done
kill -TERM -- "-$raw_pid" 2>/dev/null || kill "$raw_pid" 2>/dev/null || true
wait "$raw_pid" 2>/dev/null || true
set +m
grep -q '=== iter-1-abc1234.log ===' "$TMP/out" || { cat "$TMP/out"; fail "--raw did not tail the event log"; }
grep -q 'raw event stream' "$TMP/out" || { cat "$TMP/out"; fail "--raw showed no log content"; }
if mill -C "$TMP/a/api" logs --bogus >/dev/null 2>"$TMP/err"; then fail "unknown logs option accepted"; fi
grep -q 'unknown option' "$TMP/err" || { cat "$TMP/err"; fail "expected an unknown-option error"; }
rm -rf "$TMP"
echo "PASS: mill logs summaries, --raw, and --results"

# --- 14: operator steering — mill stop --soft and mill steer ---
make_env
mill -C "$TMP/a/api" stop --soft > "$TMP/out" || { cat "$TMP/out"; fail "mill stop --soft failed"; }
grep -q 'Will stop after the current iteration.' "$TMP/out" || { cat "$TMP/out"; fail "no soft-stop message"; }
[[ -f "$TMP/a/api/.mill/STOP" ]] || fail "mill stop --soft did not write .mill/STOP"
[[ ! -s "$DOCKER_LOG" ]] || { cat "$DOCKER_LOG"; fail "mill stop --soft talked to docker"; }
mill -C "$TMP/a/api" steer "focus on the parser" >/dev/null || fail "mill steer failed"
grep -qx 'focus on the parser' "$TMP/a/api/.mill/STEER.md" \
    || { cat "$TMP/a/api/.mill/STEER.md"; fail "steer text not written"; }
mill -C "$TMP/a/api" steer > "$TMP/out" || fail "mill steer (read) failed"
grep -qx 'focus on the parser' "$TMP/out" || { cat "$TMP/out"; fail "pending steer not printed"; }
printf 'from stdin\n' | mill -C "$TMP/a/api" steer - >/dev/null || fail "mill steer - failed"
grep -qx 'from stdin' "$TMP/a/api/.mill/STEER.md" || fail "stdin steer not written"
rm "$TMP/a/api/.mill/STEER.md"
mill -C "$TMP/a/api" steer > "$TMP/out" || fail "mill steer with no pending file failed"
grep -q 'No pending steer.' "$TMP/out" || { cat "$TMP/out"; fail "expected a no-pending-steer message"; }
[[ ! -s "$DOCKER_LOG" ]] || { cat "$DOCKER_LOG"; fail "steering commands talked to docker"; }
# `mill run` creates the drop-box in the checkout so steering works before a run.
rm -rf "$TMP/a/api/.mill"
mill -C "$TMP/a/api" run >/dev/null || fail "mill run exited nonzero"
[[ -d "$TMP/a/api/.mill" ]] || fail "mill run did not create the drop-box"
rm -rf "$TMP"
echo "PASS: mill stop --soft and mill steer drive .mill/ without docker"

# --- 15: metric ratchet keys reach the container ---
make_env
cat > "$TMP/config" <<'ENV'
METRIC_CMD=python3 bench.py
METRIC_DIRECTION=max
ENV
mill -C "$TMP/a/api" run >/dev/null || fail "mill run exited nonzero"
for kv in 'METRIC_CMD=python3 bench.py' 'METRIC_DIRECTION=max'; do
    run_line | grep -q -- "-e $kv " || { run_line; fail "$kv not forwarded to the container"; }
done
rm -rf "$TMP"
echo "PASS: METRIC_CMD and METRIC_DIRECTION reach the container"

echo "OK: all mill smoke tests passed"
