#!/usr/bin/env bash
set -euo pipefail
# Smoke tests for the mill CLI with a stubbed `docker`. No network, no docker.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

make_env() {  # sandbox holding its own copy of mill, so MILL_DIR is disposable
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin" "$TMP/a/api" "$TMP/b/api"
    cp "$ROOT/mill" "$TMP/mill"
    cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
exit 0
STUB
    chmod +x "$TMP/bin/docker"
    for r in "$TMP/a/api" "$TMP/b/api"; do
        git -C "$r" init -q
        git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    done
    export DOCKER_LOG="$TMP/docker.log"
    : > "$DOCKER_LOG"
}

mill() { PATH="$TMP/bin:$PATH" bash "$TMP/mill" "$@"; }
run_line() { grep '^run --rm --name' "$DOCKER_LOG" | tail -1; }

# --- 1: .env is read whole (no trailing newline) and the caller's env wins ---
make_env
printf 'ANTHROPIC_API_KEY=fromfile\nGIT_EMAIL=fromfile' > "$TMP/.env"   # deliberately unterminated
mill run "$TMP/a/api" >/dev/null || fail "mill run exited nonzero"
run_line | grep -q -- '-e GIT_EMAIL=fromfile' || fail "unterminated last .env line was dropped"
: > "$DOCKER_LOG"
GIT_EMAIL=fromcaller ANTHROPIC_API_KEY=fromcaller mill run "$TMP/a/api" >/dev/null \
    || fail "mill exited nonzero when a .env var was already set in the environment"
run_line | grep -q -- '-e GIT_EMAIL=fromcaller' || fail "caller env did not override .env"
run_line | grep -q -- '-e ANTHROPIC_API_KEY=fromcaller' || fail "caller-only value not forwarded to docker"
rm -rf "$TMP"
echo "PASS: .env parsing and caller-env forwarding"

# --- 2: unknown flags are rejected, not silently swallowed ---
make_env
if mill run "$TMP/a/api" --iteration 5 >/dev/null 2>"$TMP/err"; then
    fail "typo'd flag was accepted"
fi
grep -q "unknown option" "$TMP/err" || { cat "$TMP/err"; fail "expected an unknown-option error"; }
rm -rf "$TMP"
echo "PASS: unknown options are rejected"

# --- 3: repos sharing a basename get distinct containers and log dirs ---
make_env
mill run "$TMP/a/api" >/dev/null
name_a="$(run_line | sed 's/.*--name \([^ ]*\).*/\1/')"
: > "$DOCKER_LOG"
mill run "$TMP/b/api" >/dev/null
name_b="$(run_line | sed 's/.*--name \([^ ]*\).*/\1/')"
[[ "$name_a" != "$name_b" ]] || fail "same-basename repos collide on container name: $name_a"
run_line | grep -q -- "-v $TMP/logs/$name_b:/workspace/logs" || fail "log dir is not per-container"
rm -rf "$TMP"
echo "PASS: distinct container and log dir per checkout"

# --- 4: a linked worktree also mounts the main repo's git dir at its host path ---
make_env
git -C "$TMP/a/api" worktree add -q "$TMP/a/api-b" -b agent-b
mill run "$TMP/a/api-b" >/dev/null
common="$(sed -n 's/^gitdir: *//p' "$TMP/a/api-b/.git")"   # exactly what git will dereference
common="${common%/worktrees/*}"
run_line | grep -q -- "-v $common:$common" || { run_line; fail "worktree git dir not mounted"; }
# ...and every recorded worktree .git file, so `git worktree prune` inside sees them.
wt_git="$(head -1 "$common"/worktrees/*/gitdir)"
run_line | grep -q -- "-v $wt_git:$wt_git:ro" || { run_line; fail "worktree .git file not mounted"; }
rm -rf "$TMP"
echo "PASS: linked worktrees mount their git dir"

# --- 5: .env values: inline comments, quotes, whitespace; host-only keys stay home ---
make_env
cat > "$TMP/.env" <<'ENV'
ANTHROPIC_API_KEY=sk-test   
MODEL=opus   # Claude model
SETUP_CMD="uv sync"
CHECK_CMD='pytest -q # not a comment'
PATH=/nowhere
AGENTMILL_IMAGE=custom-image
ENV
mill run "$TMP/a/api" >/dev/null || fail "mill run exited nonzero"
run_line | grep -q -- '-e ANTHROPIC_API_KEY=sk-test -e' || { run_line; fail "trailing whitespace kept"; }
run_line | grep -q -- '-e MODEL=opus -e' || { run_line; fail "inline comment kept"; }
run_line | grep -q -- '-e SETUP_CMD=uv sync -e' || { run_line; fail "double quotes kept"; }
run_line | grep -q -- '-e CHECK_CMD=pytest -q # not a comment -v' || { run_line; fail "single quotes mishandled"; }
run_line | grep -q -- '-e PATH=' && fail "PATH from .env forwarded to the container"
run_line | grep -q -- ' custom-image$' || { run_line; fail "AGENTMILL_IMAGE from .env ignored"; }
rm -rf "$TMP"
echo "PASS: .env quoting, comments, and host-only keys"

# --- 6: mill stop <repo> stops that checkout only ---
make_env
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
[[ "$*" == "ps -aq --filter label=agentmill" ]] && printf 'aaa\nbbb\n'
exit 0
STUB
mill stop "$TMP/a/api" >/dev/null || fail "mill stop exited nonzero"
grep -q '^rm -f agentmill-api-' "$DOCKER_LOG" || { cat "$DOCKER_LOG"; fail "checkout container not removed"; }
grep -q '^rm -f aaa' "$DOCKER_LOG" && fail "other containers were removed"
grep -q '^network rm' "$DOCKER_LOG" && fail "network removed while other agents run"
: > "$DOCKER_LOG"
mill stop >/dev/null || fail "mill stop (all) exited nonzero"
grep -q '^rm -f aaa' "$DOCKER_LOG" || { cat "$DOCKER_LOG"; fail "mill stop did not stop everything"; }
rm -rf "$TMP"
echo "PASS: mill stop is per-checkout with a repo, global without"

echo "OK: all mill smoke tests passed"
