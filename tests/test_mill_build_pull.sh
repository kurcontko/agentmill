#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
mkdir -p "$harness" "$TMPDIR/bin"
cp "$REPO_ROOT/mill" "$REPO_ROOT/Dockerfile" "$harness/"
chmod +x "$harness/mill"

cat > "$TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${DOCKER_LOG:?}"

case "${1:-}" in
    pull)
        [[ "${DOCKER_PULL_FAIL:-false}" == true ]] && exit 1
        exit 0
        ;;
    tag|build)
        exit 0
        ;;
esac

echo "unexpected docker invocation: $*" >&2
exit 1
SH
chmod +x "$TMPDIR/bin/docker"

log="$TMPDIR/docker.log"
PATH="$TMPDIR/bin:$PATH" DOCKER_LOG="$log" "$harness/mill" build --pull --platform linux/arm64
grep -Fx 'pull --platform linux/arm64 ghcr.io/kurcontko/agentmill:latest' "$log"
grep -Fx 'tag ghcr.io/kurcontko/agentmill:latest agentmill:latest' "$log"
if grep -q '^build ' "$log"; then
    echo "expected successful pull to skip local build" >&2
    exit 1
fi

: > "$log"
PATH="$TMPDIR/bin:$PATH" DOCKER_LOG="$log" DOCKER_PULL_FAIL=true "$harness/mill" build --pull
grep -Fx 'pull ghcr.io/kurcontko/agentmill:latest' "$log"
grep -Fx "build -t agentmill:latest $harness" "$log"

: > "$log"
PATH="$TMPDIR/bin:$PATH" DOCKER_LOG="$log" AGENTMILL_PREBUILT_IMAGE=ghcr.io/acme/agentmill:v1 AGENTMILL_IMAGE=agentmill:test "$harness/mill" build --pull
grep -Fx 'pull ghcr.io/acme/agentmill:v1' "$log"
grep -Fx 'tag ghcr.io/acme/agentmill:v1 agentmill:test' "$log"

echo "PASS test_mill_build_pull"
