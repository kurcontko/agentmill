#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
repo="$TMPDIR/repo"
docker_log="$TMPDIR/docker.log"
mkdir -p "$harness/memory" "$repo/memory" "$TMPDIR/bin"
cp "$REPO_ROOT/mill" "$REPO_ROOT/docker-compose.yml" "$harness/"
chmod +x "$harness/mill"

git init -q "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m base

cat > "$harness/.env" <<EOF_ENV
REPO_PATH=$repo
ANTHROPIC_API_KEY=sk-ant-abc#def123
HASH_TOKEN=abc#def
INLINE_COMMENT=abc # comment
QUOTED_HASH="quoted#value # kept" # comment
EOF_ENV

cat > "$harness/memory/sources.md" <<'MD'
harness memory
MD
cat > "$repo/memory/sources.md" <<'MD'
repo memory
MD

cat > "$TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
    exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
    {
        printf 'cmd=%s\n' "$*"
        printf 'PROMPT_FILE=%s\n' "${PROMPT_FILE:-}"
        printf 'AUTO_COMMIT=%s\n' "${AUTO_COMMIT:-}"
        printf 'MODEL=%s\n' "${MODEL:-}"
        printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY:-}"
        printf 'HASH_TOKEN=%s\n' "${HASH_TOKEN:-}"
        printf 'INLINE_COMMENT=%s\n' "${INLINE_COMMENT:-}"
        printf 'QUOTED_HASH=%s\n' "${QUOTED_HASH:-}"
    } >> "${DOCKER_LOG:?}"
    exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
SH
chmod +x "$TMPDIR/bin/docker"

run_mill() {
    env \
        -u ANTHROPIC_API_KEY \
        -u HASH_TOKEN \
        -u INLINE_COMMENT \
        -u QUOTED_HASH \
        DOCKER_LOG="$docker_log" \
        PATH="$TMPDIR/bin:$PATH" \
        "$harness/mill" "$@"
}

# shellcheck disable=SC2016
grep -q 'PROMPT_FILE: ${PROMPT_FILE:-/prompts/PROMPT.md}' "$REPO_ROOT/docker-compose.yml"
# shellcheck disable=SC2016
grep -q 'AUTO_COMMIT: ${AUTO_COMMIT:-}' "$REPO_ROOT/docker-compose.yml"

run_mill run "$repo" --prompt /prompts/custom.md --auto-commit off
grep -Fx 'PROMPT_FILE=/prompts/custom.md' "$docker_log"
grep -Fx 'AUTO_COMMIT=off' "$docker_log"
grep -Fx 'ANTHROPIC_API_KEY=sk-ant-abc#def123' "$docker_log"
grep -Fx 'HASH_TOKEN=abc#def' "$docker_log"
grep -Fx 'INLINE_COMMENT=abc' "$docker_log"
grep -Fx 'QUOTED_HASH=quoted#value # kept' "$docker_log"

run_mill multi "$repo" --model opus
grep -q 'cmd=.* up agent-1 agent-2 agent-3' "$docker_log"
grep -Fx 'MODEL=opus' "$docker_log"

memory_output="$(run_mill memory sources)"
[[ "$memory_output" == *"harness memory"* ]]
[[ "$memory_output" != *"repo memory"* ]]

echo "PASS test_review_fixes_cli"
