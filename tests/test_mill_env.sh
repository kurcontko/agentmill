#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
repo="$TMPDIR/repo"
docker_log="$TMPDIR/docker.log"
mkdir -p "$harness/logs" "$TMPDIR/bin"
cp "$REPO_ROOT/mill" "$REPO_ROOT/docker-compose.yml" "$harness/"
chmod +x "$harness/mill"

git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m base

cat > "$harness/.env" <<EOF_ENV
# full-line comments are ignored
  # indented full-line comments are ignored
REPO_PATH=$repo
AGENTMILL_PROFILE_LEVEL=trusted
ANTHROPIC_API_KEY=sk-ant-abc#def123
HASH_TOKEN=abc#def
INLINE_COMMENT=abc # this is a comment
QUOTED_HASH="quoted#value # kept" # this is a comment
SINGLE_HASH='single#value # kept' # this is a comment
EOF_ENV

cat > "$TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
    exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
    {
        printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY:-}"
        printf 'HASH_TOKEN=%s\n' "${HASH_TOKEN:-}"
        printf 'INLINE_COMMENT=%s\n' "${INLINE_COMMENT:-}"
        printf 'QUOTED_HASH=%s\n' "${QUOTED_HASH:-}"
        printf 'SINGLE_HASH=%s\n' "${SINGLE_HASH:-}"
    } > "${DOCKER_LOG:?}"
    exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
SH
chmod +x "$TMPDIR/bin/docker"

env \
    -u ANTHROPIC_API_KEY \
    -u HASH_TOKEN \
    -u INLINE_COMMENT \
    -u QUOTED_HASH \
    -u SINGLE_HASH \
    -u REPO_PATH \
    -u AGENTMILL_PROFILE_LEVEL \
    -u AGENTMILL_WORKSPACE_MODE \
    -u AGENTMILL_ALLOW_DIRECT_HOST_REPO \
    DOCKER_LOG="$docker_log" \
    PATH="$TMPDIR/bin:$PATH" \
    "$harness/mill" run --iterations 1

grep -Fx 'ANTHROPIC_API_KEY=sk-ant-abc#def123' "$docker_log"
grep -Fx 'HASH_TOKEN=abc#def' "$docker_log"
grep -Fx 'INLINE_COMMENT=abc' "$docker_log"
grep -Fx 'QUOTED_HASH=quoted#value # kept' "$docker_log"
grep -Fx 'SINGLE_HASH=single#value # kept' "$docker_log"

echo "PASS test_mill_env"
