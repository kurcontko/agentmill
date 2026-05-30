#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
repo="$TMPDIR/repo"
explicit_repo="$TMPDIR/explicit-repo"
docker_log="$TMPDIR/docker.log"
mkdir -p "$harness/logs" "$TMPDIR/bin"
cp "$REPO_ROOT/mill" "$REPO_ROOT/docker-compose.yml" "$harness/"
chmod +x "$harness/mill"

make_repo() {
    local path="$1"
    git init -q -b main "$path"
    git -C "$path" config user.name Test
    git -C "$path" config user.email test@example.com
    printf 'base\n' > "$path/README.md"
    git -C "$path" add README.md
    git -C "$path" commit -q -m base
}

make_repo "$repo"
make_repo "$explicit_repo"
printf 'REPO_PATH=%s\nAGENTMILL_PROFILE_LEVEL=trusted\n' "$repo" > "$harness/.env"

cat > "$TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
    exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
    printf '%s :: %s\n' "${REPO_PATH:-}" "$*" >> "${DOCKER_LOG:?}"
    exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
SH
chmod +x "$TMPDIR/bin/docker"

run_mill() {
    DOCKER_LOG="$docker_log" PATH="$TMPDIR/bin:$PATH" "$harness/mill" "$@"
}

help_output="$(run_mill run --help)"
[[ "$help_output" == *"mill run   [repo]"* ]] || {
    echo "expected run help to show optional repo" >&2
    exit 1
}

run_mill run --iterations 1
run_mill exec
run_mill watch
run_mill shell
run_mill multi
run_mill multi 2
run_mill run "$explicit_repo" --iterations 1

grep -Fx "$repo :: compose -f $harness/docker-compose.yml up headless" "$docker_log"
grep -Fx "$repo :: compose -f $harness/docker-compose.yml run --rm headless" "$docker_log"
grep -Fx "$repo :: compose -f $harness/docker-compose.yml run watch" "$docker_log"
grep -Fx "$repo :: compose -f $harness/docker-compose.yml run interactive" "$docker_log"
grep -Fx "$repo :: compose -f $harness/docker-compose.yml up agent-1 agent-2 agent-3" "$docker_log"
grep -Fx "$repo :: compose -f $harness/docker-compose.yml up agent-1 agent-2" "$docker_log"
grep -Fx "$explicit_repo :: compose -f $harness/docker-compose.yml up headless" "$docker_log"

echo "PASS test_mill_repo_path_env"
