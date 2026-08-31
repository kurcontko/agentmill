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
for key in ANTHROPIC_API_KEY GIT_EMAIL MODEL SETUP_CMD CHECK_CMD GITHUB_TOKEN \
    CUSTOM_FLAG CUSTOM_CRLF MAX_TURNS MIN_TURNS MAX_BUDGET_USD \
    MAX_TOTAL_BUDGET_USD DONE_CMD EVALUATOR CLAUDE_BARE METRIC_CMD \
    METRIC_DIRECTION HTTP_PROXY HTTPS_PROXY NO_PROXY NODE_EXTRA_CA_CERTS \
    http_proxy https_proxy no_proxy DOCKER_HOST BASH_ENV LD_PRELOAD; do
    printf '%s=%s\n' "$key" "${!key-}" >> "$DOCKER_ENV_LOG"
done
previous=
for arg in "$@"; do
    if [[ "$previous" == --env-file ]]; then
        printf 'ENV_FILE=%s\n' "$arg" >> "$DOCKER_FILE_ENV_LOG"
        permissions="$(LC_ALL=C ls -l "$arg")"
        printf 'ENV_MODE=%s\n' "${permissions%% *}" >> "$DOCKER_FILE_ENV_LOG"
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf 'ENV:%s\n' "$line" >> "$DOCKER_FILE_ENV_LOG"
        done < "$arg"
    fi
    previous="$arg"
done
[[ "${DOCKER_FAIL_RUN:-}" == true && "${1:-}" == run ]] && exit 7
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
    export DOCKER_FILE_ENV_LOG="$TMP/docker-file-env.log"
    : > "$DOCKER_LOG"
    : > "$DOCKER_ENV_LOG"
    : > "$DOCKER_FILE_ENV_LOG"
}

mill() { PATH="$TMP/bin:$PATH" bash "$TMP/mill" "$@"; }
mill_in() { local d="$1"; shift; (cd "$d" && mill "$@"); }
run_line() { grep '^run --rm --name' "$DOCKER_LOG" | tail -1; }
assert_bare_key() {
    local key="$1"
    run_line | grep -q -- "-e $key " || { run_line; fail "$key was not forwarded by name"; }
    if run_line | grep -q -- "-e $key="; then
        run_line
        fail "$key was forwarded as KEY=value in docker argv"
    fi
}
assert_client_env_value() {
    grep -Fqx -- "$1=$2" "$DOCKER_ENV_LOG" || {
        grep -F -- "$1=" "$DOCKER_ENV_LOG" | tail -3
        fail "$1 did not reach the Docker client with the expected caller value"
    }
}
assert_file_env_value() {
    grep -Fqx -- "ENV:$1=$2" "$DOCKER_FILE_ENV_LOG" || {
        grep -F -- "ENV:$1=" "$DOCKER_FILE_ENV_LOG" | tail -3
        fail "$1 did not reach the private Docker env file with the expected value"
    }
}
assert_file_key() {
    grep -Fq -- "ENV:$1=" "$DOCKER_FILE_ENV_LOG" \
        || fail "$1 was not represented in the private Docker env file"
    if run_line | grep -q -- "-e $1"; then
        run_line
        fail "file-provided $1 entered docker argv instead of --env-file"
    fi
}
assert_env_file_private_and_cleaned() {
    local file mode
    file="$(grep '^ENV_FILE=' "$DOCKER_FILE_ENV_LOG" | tail -1 | cut -d= -f2-)"
    [[ -n "$file" ]] || fail "docker run received no private env file"
    mode="$(grep '^ENV_MODE=' "$DOCKER_FILE_ENV_LOG" | tail -1)"
    [[ "$mode" == 'ENV_MODE=-rw-------' ]] \
        || { cat "$DOCKER_FILE_ENV_LOG"; fail "Docker env file was not mode 0600"; }
    [[ ! -e "$file" ]] || fail "Docker env file was not cleaned up: $file"
}
assert_not_forwarded() {
    if run_line | grep -q -- "-e $1"; then
        run_line
        fail "host-managed $1 was forwarded to the container"
    fi
    if grep -Fq -- "ENV:$1=" "$DOCKER_FILE_ENV_LOG"; then
        cat "$DOCKER_FILE_ENV_LOG"
        fail "host-managed $1 was written to the Docker env file"
    fi
}

# --- 1: config file is read whole (no trailing newline) and the caller's env wins ---
make_env
printf 'ANTHROPIC_API_KEY=fromfile\nGIT_EMAIL=fromfile' > "$TMP/config"   # deliberately unterminated
mill -C "$TMP/a/api" run >/dev/null || fail "mill run exited nonzero"
assert_file_key GIT_EMAIL
assert_file_key ANTHROPIC_API_KEY
run_line | grep -q -- '--label agentmill.stop-timeout=60' || { run_line; fail "resolved stop timeout not recorded as a label"; }
assert_file_env_value GIT_EMAIL fromfile
assert_file_env_value ANTHROPIC_API_KEY fromfile
assert_env_file_private_and_cleaned
: > "$DOCKER_LOG"
: > "$DOCKER_ENV_LOG"
: > "$DOCKER_FILE_ENV_LOG"
GIT_EMAIL=fromcaller ANTHROPIC_API_KEY=fromcaller mill -C "$TMP/a/api" run >/dev/null \
    || fail "mill exited nonzero when a the config file var was already set in the environment"
assert_bare_key GIT_EMAIL
assert_bare_key ANTHROPIC_API_KEY
assert_client_env_value GIT_EMAIL fromcaller
assert_client_env_value ANTHROPIC_API_KEY fromcaller
if grep -Eq '^ENV:(GIT_EMAIL|ANTHROPIC_API_KEY)=' "$DOCKER_FILE_ENV_LOG"; then
    cat "$DOCKER_FILE_ENV_LOG"
    fail "caller override was also copied from the lower-precedence config file"
fi
grep -q '^ENV_FILE=' "$DOCKER_FILE_ENV_LOG" \
    && { cat "$DOCKER_FILE_ENV_LOG"; fail "an empty private env file was created"; }
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
run_line | grep -Eq -- "-v [^ ]+:$wt_git:ro" || { run_line; fail "worktree .git file not mounted"; }
run_line | grep -Fq -- "-v $wt_git:$wt_git:ro" \
    && { run_line; fail "mutable worktree .git path was used as its own bind source"; }
canonical_wt="$(cd -P "$TMP/a/api-b" && pwd)"
run_line | grep -q -- "-v $canonical_wt:$canonical_wt" || { run_line; fail "worktree relocated in container"; }
run_line | grep -q -- '-v [^ ]*:/workspace/repo' && { run_line; fail "worktree was relocated to /workspace/repo"; }
grep -q '^gitdir: \.\.' "$TMP/a/api-b/vendor/sub/.git" \
    || fail "fixture did not create the relative submodule gitdir under review"
# Starting from the main checkout must protect linked siblings too. Its .git is
# a directory, which used to make worktree_mount return before adding these.
: > "$DOCKER_LOG"
mill -C "$TMP/a/api" run >/dev/null
sibling_git="$(cd -P "$TMP/a/api-b" && pwd)/.git"
run_line | grep -Fq -- "-v $common:$common" \
    || { run_line; fail "main checkout did not pin its common git directory"; }
run_line | grep -Eq -- "-v [^ ]+:$sibling_git:ro" \
    || { run_line; fail "main checkout did not mount its sibling worktree's .git file"; }
run_line | grep -Fq -- "-v $sibling_git:$sibling_git:ro" \
    && { run_line; fail "main checkout mounted a worker-mutable gitfile source"; }

# Common git metadata is writable in the container. A forged sibling record
# must not turn an arbitrary existing host file into a bind mount on the next
# run; only a `.git` file that points back to this exact entry is accepted.
mkdir -p "$TMP/victim" "$common/worktrees/poison"
printf 'host-only secret\n' > "$TMP/victim/.git"
printf '%s\n' "$TMP/victim/.git" > "$common/worktrees/poison/gitdir"
: > "$DOCKER_LOG"
mill -C "$TMP/a/api" run >/dev/null 2>"$TMP/poison.err"
grep -q 'ignoring malformed worktree metadata' "$TMP/poison.err" \
    || { cat "$TMP/poison.err"; fail "poisoned worktree record was not rejected"; }
if run_line | grep -Fq -- "$TMP/victim/.git"; then
    run_line
    fail "poisoned worktree metadata exposed an arbitrary host file"
fi
rm -rf "$TMP"
echo "PASS: main and linked worktrees preserve sibling and submodule git paths"

# --- 6: config file values: inline comments, quotes, whitespace; host-only keys stay home ---
make_env
export BASH_ENV_MARKER="$TMP/bash-env-sourced"
# shellcheck disable=SC2016 # literal payload: it must expand only if wrongly sourced
printf '%s\n' 'printf "sourced\n" > "$BASH_ENV_MARKER"' > "$TMP/bash-env-poison"
cat > "$TMP/config" <<ENV
ANTHROPIC_API_KEY=sk-test   
MODEL=opus   # Claude model
SETUP_CMD="uv sync"
CHECK_CMD='pytest -q # not a comment'
GITHUB_TOKEN=gh-secret
DOCKER_HOST=tcp://must-not-control-host.example:2375
BASH_ENV=$TMP/bash-env-poison
LD_PRELOAD=/tmp/agentmill-must-not-load.so
TAR_OPTIONS=--checkpoint=1
PATH=/nowhere
AGENTMILL_IMAGE=custom-image
LOG_DIR=/tmp/poison-log
PROMPT_FILE=/tmp/poison-prompt
EVALUATOR_FILE=/tmp/poison-evaluator
MISSION_FILE=/tmp/poison-mission
ENV
(
    unset DOCKER_HOST BASH_ENV LD_PRELOAD
    mill -C "$TMP/a/api" run >/dev/null
) || fail "mill run exited nonzero"
for key in ANTHROPIC_API_KEY MODEL SETUP_CMD CHECK_CMD GITHUB_TOKEN DOCKER_HOST; do
    assert_file_key "$key"
done
assert_file_env_value ANTHROPIC_API_KEY sk-test
assert_file_env_value MODEL opus
assert_file_env_value SETUP_CMD 'uv sync'
assert_file_env_value CHECK_CMD 'pytest -q # not a comment'
assert_file_env_value GITHUB_TOKEN gh-secret
assert_file_env_value DOCKER_HOST tcp://must-not-control-host.example:2375
for key in DOCKER_HOST BASH_ENV LD_PRELOAD; do
    grep -Fqx -- "$key=" "$DOCKER_ENV_LOG" || {
        grep -F -- "$key=" "$DOCKER_ENV_LOG" | tail -3
        fail "config-file $key contaminated the host Docker client environment"
    }
done
assert_not_forwarded BASH_ENV
assert_not_forwarded LD_PRELOAD
assert_not_forwarded TAR_OPTIONS
[[ ! -e "$BASH_ENV_MARKER" ]] || fail "config-file BASH_ENV was sourced by the host Docker stub"
for secret in sk-test gh-secret 'uv sync' 'pytest -q # not a comment' \
    must-not-control-host.example bash-env-poison agentmill-must-not-load.so; do
    if run_line | grep -Fq -- "$secret"; then
        run_line
        fail "config-file value exposed in docker argv: $secret"
    fi
done
for key in PATH LOG_DIR PROMPT_FILE EVALUATOR_FILE MISSION_FILE; do
    assert_not_forwarded "$key"
done
assert_env_file_private_and_cleaned
run_line | grep -q -- ' custom-image$' || { run_line; fail "AGENTMILL_IMAGE from the config file ignored"; }
: > "$DOCKER_LOG"
: > "$DOCKER_ENV_LOG"
: > "$DOCKER_FILE_ENV_LOG"
GITHUB_TOKEN=trusted-caller-override mill -C "$TMP/a/api" run >/dev/null \
    || fail "trusted user-config key did not accept a caller override"
assert_bare_key GITHUB_TOKEN
assert_client_env_value GITHUB_TOKEN trusted-caller-override
grep -Fq 'ENV:GITHUB_TOKEN=' "$DOCKER_FILE_ENV_LOG" \
    && { cat "$DOCKER_FILE_ENV_LOG"; fail "overridden user-config secret remained in env file"; }
unset BASH_ENV_MARKER
rm -rf "$TMP"
echo "PASS: config values use a private env file without affecting the host Docker client"

# --- 6b: proxy and custom-CA settings are inherited in both common casings ---
make_env
HTTP_PROXY=http://upper-http.example HTTPS_PROXY=http://upper-https.example \
NO_PROXY=localhost,127.0.0.1 NODE_EXTRA_CA_CERTS=/tmp/agentmill-ca.pem \
http_proxy=http://lower-http.example https_proxy=http://lower-https.example \
no_proxy=internal.example mill -C "$TMP/a/api" run >/dev/null \
    || fail "mill run with proxy settings exited nonzero"
for key in HTTP_PROXY HTTPS_PROXY NO_PROXY NODE_EXTRA_CA_CERTS http_proxy https_proxy no_proxy; do
    assert_bare_key "$key"
done
assert_client_env_value HTTP_PROXY http://upper-http.example
assert_client_env_value HTTPS_PROXY http://upper-https.example
assert_client_env_value NO_PROXY localhost,127.0.0.1
assert_client_env_value NODE_EXTRA_CA_CERTS /tmp/agentmill-ca.pem
assert_client_env_value http_proxy http://lower-http.example
assert_client_env_value https_proxy http://lower-https.example
assert_client_env_value no_proxy internal.example
for value in upper-http.example upper-https.example agentmill-ca.pem lower-http.example lower-https.example internal.example; do
    if run_line | grep -Fq -- "$value"; then
        run_line
        fail "proxy/TLS value exposed in docker argv: $value"
    fi
done
rm -rf "$TMP"
echo "PASS: proxy and custom-CA settings reach the container without argv exposure"

# --- 6c: private env files are removed after detach, shell, and Docker failure ---
make_env
printf 'GITHUB_TOKEN=cleanup-secret\n' > "$TMP/config"
mill -C "$TMP/a/api" run -d >/dev/null || fail "detached mill run exited nonzero"
assert_file_env_value GITHUB_TOKEN cleanup-secret
assert_env_file_private_and_cleaned

: > "$DOCKER_LOG"
: > "$DOCKER_FILE_ENV_LOG"
mill -C "$TMP/a/api" shell >/dev/null || fail "mill shell exited nonzero"
grep -q '^run --rm -it --entrypoint bash ' "$DOCKER_LOG" \
    || { cat "$DOCKER_LOG"; fail "interactive shell did not reach docker run"; }
assert_file_env_value GITHUB_TOKEN cleanup-secret
assert_env_file_private_and_cleaned

: > "$DOCKER_LOG"
: > "$DOCKER_FILE_ENV_LOG"
if DOCKER_FAIL_RUN=true mill -C "$TMP/a/api" run >/dev/null 2>"$TMP/err"; then
    fail "mill hid the Docker run failure"
fi
assert_file_env_value GITHUB_TOKEN cleanup-secret
assert_env_file_private_and_cleaned

# A foreground interrupt must unlink the secret file immediately, even while
# the Docker client is still alive and ignoring TERM.
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" != run ]]; then exit 0; fi
previous=
for arg in "$@"; do
    if [[ "$previous" == --env-file ]]; then printf '%s\n' "$arg" > "$SIGNAL_ENV_PATH"; fi
    previous="$arg"
done
printf '%s\n' "$$" > "$SIGNAL_DOCKER_PID"
trap '' HUP INT TERM
while :; do sleep 30; done
STUB
chmod +x "$TMP/bin/docker"
set -m
SIGNAL_ENV_PATH="$TMP/signal-env-path" SIGNAL_DOCKER_PID="$TMP/signal-docker-pid" \
    PATH="$TMP/bin:$PATH" bash "$TMP/mill" -C "$TMP/a/api" run >/dev/null 2>&1 &
mill_pid=$!
for _ in $(seq 1 100); do [[ -s "$TMP/signal-env-path" ]] && break; sleep 0.05; done
[[ -s "$TMP/signal-env-path" ]] || fail "blocking Docker client never received the env file"
signal_env_file="$(cat "$TMP/signal-env-path")"
[[ -f "$signal_env_file" ]] || fail "private env file disappeared before the signal test"
kill -TERM -- "-$mill_pid" 2>/dev/null || kill -TERM "$mill_pid" 2>/dev/null || true
for _ in $(seq 1 100); do [[ ! -e "$signal_env_file" ]] && break; sleep 0.05; done
[[ ! -e "$signal_env_file" ]] || fail "signal left the private Docker env file behind"
kill -KILL -- "-$mill_pid" 2>/dev/null || true
wait "$mill_pid" 2>/dev/null || true
set +m
rm -rf "$TMP"
echo "PASS: private Docker env files are always cleaned up"

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
printf 'EVALUATOR=true\n' > "$TMP/config"
if mill -C "$TMP/a/api" run --dind >"$TMP/out" 2>"$TMP/err"; then
    fail "mill combined the evaluator with privileged DinD"
fi
grep -q 'EVALUATOR=true cannot be combined with --dind' "$TMP/err" \
    || { cat "$TMP/err"; fail "missing evaluator/DinD isolation error"; }
[[ ! -s "$DOCKER_LOG" ]] || { cat "$DOCKER_LOG"; fail "evaluator/DinD rejection reached Docker"; }
: > "$TMP/config"
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
printf 'DOCKER_HOST=tcp://lower-precedence.example:2375\n' > "$TMP/config"
mill -C "$TMP/a/api" run --dind >"$TMP/out" || { cat "$TMP/out"; fail "ready dind was rejected"; }
[[ "$(cat "$DIND_COUNT")" -eq 3 ]] || fail "mill did not poll dind readiness"
ready_line="$(grep -n '^exec agentmill-dind docker -H tcp://127.0.0.1:2375 info$' "$DOCKER_LOG" | tail -1 | cut -d: -f1)"
agent_line="$(grep -n '^run --rm --name agentmill-api-' "$DOCKER_LOG" | cut -d: -f1)"
[[ "$ready_line" -lt "$agent_line" ]] || fail "agent container started before dind was ready"
case "$(grep '^run --rm --name agentmill-api-' "$DOCKER_LOG")" in
    *--env-file*'-e DOCKER_HOST=tcp://agentmill-dind:2375'*) ;;
    *) cat "$DOCKER_LOG"; fail "DinD DOCKER_HOST did not follow the lower-precedence env file" ;;
esac

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
host_secret_probe: repository-placeholder
empty_one:
log_dir: /tmp/poison-log
prompt_file: /tmp/poison-prompt
evaluator_file: /tmp/poison-evaluator
mission_file: /tmp/poison-mission
---
# Mission
MD
HOST_SECRET_PROBE=host-only-value mill -C "$TMP/a/api" run >/dev/null \
    || fail "mill run with frontmatter failed"
for key in CHECK_CMD MODEL CUSTOM_FLAG HOST_SECRET_PROBE; do assert_file_key "$key"; done
assert_file_env_value CHECK_CMD 'pytest -q'
assert_file_env_value MODEL sonnet
assert_file_env_value CUSTOM_FLAG yes
assert_file_env_value HOST_SECRET_PROBE repository-placeholder
! grep -Fq 'host-only-value' "$DOCKER_FILE_ENV_LOG" \
    || { cat "$DOCKER_FILE_ENV_LOG"; fail "frontmatter selected an unrelated host secret"; }
run_line | grep -q -- '-e EMPTY_ONE' && { run_line; fail "empty frontmatter value forwarded"; }
for key in LOG_DIR PROMPT_FILE EVALUATOR_FILE MISSION_FILE; do assert_not_forwarded "$key"; done
: > "$DOCKER_LOG"
: > "$DOCKER_ENV_LOG"
: > "$DOCKER_FILE_ENV_LOG"
mill -C "$TMP/a/api" run --model from-flag >/dev/null
assert_file_env_value MODEL sonnet
env_path="$(grep '^ENV_FILE=' "$DOCKER_FILE_ENV_LOG" | tail -1 | cut -d= -f2-)"
case "$(run_line)" in
    *"--env-file $env_path"*"-e MODEL=from-flag"*) ;;
    *) run_line; fail "the private env file was ordered after a higher-precedence flag" ;;
esac

: > "$DOCKER_LOG"
: > "$DOCKER_ENV_LOG"
: > "$DOCKER_FILE_ENV_LOG"
MODEL=from-env mill -C "$TMP/a/api" run >/dev/null
assert_bare_key MODEL
assert_client_env_value MODEL from-env
grep -Fq 'ENV:MODEL=' "$DOCKER_FILE_ENV_LOG" \
    && { cat "$DOCKER_FILE_ENV_LOG"; fail "config/frontmatter MODEL survived a caller override"; }
rm "$TMP/b/api/MILL.md"
if mill -C "$TMP/b/api" run >/dev/null 2>"$TMP/err"; then fail "mill ran without MILL.md"; fi
grep -q 'no MILL.md' "$TMP/err" || { cat "$TMP/err"; fail "expected a missing-MILL.md error"; }
rm -rf "$TMP"
echo "PASS: MILL.md frontmatter and precedence"

# --- 10b: CRLF fences parse, while an unclosed fence fails before forwarding ---
make_env
printf '%s\r\n' \
    '---' \
    'check_cmd: "pytest -q"' \
    'custom_crlf: works' \
    '---' \
    '# Mission' \
    'Body: this is mission text' > "$TMP/a/api/MILL.md"
mill -C "$TMP/a/api" run >/dev/null || fail "CRLF frontmatter was rejected"
assert_file_key CHECK_CMD
assert_file_key CUSTOM_CRLF
assert_file_env_value CHECK_CMD 'pytest -q'
assert_file_env_value CUSTOM_CRLF works

cat > "$TMP/a/api/MILL.md" <<'MD'
---
model: staged-only
# Mission
body_setting: must-never-be-config
MD
: > "$DOCKER_LOG"
if mill -C "$TMP/a/api" run >/dev/null 2>"$TMP/err"; then
    fail "MILL.md with unclosed frontmatter was accepted"
fi
grep -q 'unclosed frontmatter' "$TMP/err" \
    || { cat "$TMP/err"; fail "missing unclosed-frontmatter diagnostic"; }
if grep -q '^run --rm --name' "$DOCKER_LOG"; then
    cat "$DOCKER_LOG"
    fail "docker started after unclosed frontmatter"
fi
rm -rf "$TMP"
echo "PASS: CRLF and unclosed MILL.md frontmatter are handled safely"

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
    key="${kv%%=*}" value="${kv#*=}"
    assert_file_key "$key"
    assert_file_env_value "$key" "$value"
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
    key="${kv%%=*}" value="${kv#*=}"
    assert_file_key "$key"
    assert_file_env_value "$key" "$value"
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
    key="${kv%%=*}" value="${kv#*=}"
    assert_file_key "$key"
    assert_file_env_value "$key" "$value"
done
rm -rf "$TMP"
echo "PASS: METRIC_CMD and METRIC_DIRECTION reach the container"

echo "OK: all mill smoke tests passed"
