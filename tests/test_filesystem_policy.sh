#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

grep -q 'read_only: ${AGENTMILL_READ_ONLY_ROOTFS:-true}' "$REPO_ROOT/docker-compose.yml"
grep -q '/tmp:rw,nosuid,nodev,mode=1777' "$REPO_ROOT/docker-compose.yml"
grep -q '/home/agent:rw,nosuid,nodev,uid=1000,gid=1000,mode=700' "$REPO_ROOT/docker-compose.yml"
grep -q '/workspace:rw,nosuid,nodev,uid=1000,gid=1000,mode=755' "$REPO_ROOT/docker-compose.yml"
grep -q './logs:/workspace/logs' "$REPO_ROOT/docker-compose.yml"
grep -q './memory:/workspace/memory' "$REPO_ROOT/docker-compose.yml"
grep -q '${REPO_PATH:?Set REPO_PATH in .env}:/workspace/repo' "$REPO_ROOT/docker-compose.yml"
grep -q '${REPO_PATH:?Set REPO_PATH in .env}:/workspace/upstream:ro' "$REPO_ROOT/docker-compose.yml"
grep -q 'AGENTMILL_READ_ONLY_ROOTFS=true' "$REPO_ROOT/.env.example"
grep -q 'AGENTMILL_WRITE_ROOTS:' "$REPO_ROOT/docker-compose.yml"
grep -q 'AGENTMILL_WRITE_ROOTS=' "$REPO_ROOT/.env.example"
grep -q 'AGENTMILL_WRITE_ROOT_SANDBOX:' "$REPO_ROOT/docker-compose.yml"
grep -q 'AGENTMILL_WRITE_ROOT_SANDBOX=auto' "$REPO_ROOT/.env.example"
grep -q 'AGENTMILL_BWRAP_COMMAND:' "$REPO_ROOT/docker-compose.yml"
grep -q 'AGENTMILL_BWRAP_COMMAND=bwrap' "$REPO_ROOT/.env.example"
grep -q 'bubblewrap' "$REPO_ROOT/Dockerfile"

rendered="$TMPDIR/agentmill-compose.yml"
REPO_PATH="$REPO_ROOT" docker compose -f "$REPO_ROOT/docker-compose.yml" config > "$rendered"
grep -q 'read_only: true' "$rendered"
grep -q '/tmp:rw,nosuid,nodev,mode=1777' "$rendered"
grep -q '/home/agent:rw,nosuid,nodev,uid=1000,gid=1000,mode=700' "$rendered"
grep -q '/workspace:rw,nosuid,nodev,uid=1000,gid=1000,mode=755' "$rendered"

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="fs"
export ITERATION=1
export AGENTMILL_RUN_ID="filesystem-policy-test"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

repo="$TMPDIR/repo"
mkdir -p "$repo/src" "$repo/docs"
git -C "$repo" init -q
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'ok\n' > "$repo/src/ok.txt"
printf 'doc\n' > "$repo/docs/readme.md"
git -C "$repo" add .
git -C "$repo" commit -q -m init

(
    cd "$repo"
    printf 'changed\n' > src/ok.txt
    AGENTMILL_PROFILE_LEVEL=standard AGENTMILL_WRITE_ROOTS=src enforce_write_root_policy
)

(
    cd "$repo"
    printf 'changed\n' > docs/readme.md
    set +e
    AGENTMILL_PROFILE_LEVEL=standard AGENTMILL_WRITE_ROOTS=src enforce_write_root_policy
    denied_rc=$?
    set -e
    [[ "$denied_rc" -ne 0 ]] || { echo "expected write root denial" >&2; exit 1; }
)

sandbox_repo="$TMPDIR/sandbox-repo"
mkdir -p "$sandbox_repo/src"
cat > "$TMPDIR/bwrap-fail" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMPDIR/bwrap-fail"
set +e
AGENTMILL_CLIENT=opencode \
AGENTMILL_PROFILE_LEVEL=standard \
AGENTMILL_WRITE_ROOTS=src \
AGENTMILL_BWRAP_COMMAND="$TMPDIR/bwrap-fail" \
REPO_DIR="$sandbox_repo" \
    client_run_with_write_root_sandbox "$sandbox_repo" true
sandbox_rc=$?
set -e
[[ "$sandbox_rc" -ne 0 ]] || { echo "expected unavailable bwrap sandbox to fail" >&2; exit 1; }

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
allowed = [event for event in events if event["type"] == "policy.allowed"]
denied = [event for event in events if event["type"] == "policy.denied"]
assert any(event["payload"]["reason"] == "write_roots_enforced" for event in allowed), events
violation = next(event["payload"] for event in denied if event["payload"]["reason"] == "write_root_violation")
assert violation["profile"] == "standard", violation
assert violation["write_roots"] == "src", violation
assert "docs/readme.md" in violation["files"], violation
assert any(event["payload"]["reason"] == "write_root_filesystem_sandbox_unavailable" for event in denied), events
PY

grep -q 'enforce_write_root_policy' "$REPO_ROOT/entrypoint.sh"
grep -q 'enforce_write_root_policy' "$REPO_ROOT/entrypoint-tui.sh"

echo "PASS test_filesystem_policy"
