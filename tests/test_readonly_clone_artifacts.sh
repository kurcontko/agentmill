#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

repo="$TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"

printf 'changed\n' > "$repo/README.md"
printf 'new\n' > "$repo/new.txt"
git -C "$repo" add README.md new.txt
git -C "$repo" commit -q -m change

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="clone"
export ITERATION="3"
export AGENTMILL_RUN_ID="readonly-test"
export AGENTMILL_PROFILE_LEVEL="standard"
export AGENTMILL_WORKSPACE_MODE="readonly-clone"
export AGENT_BRANCH="agent-1"
export REPO_DIR="$repo"
export UPSTREAM_HEAD="$base"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

cd "$repo"
export_readonly_clone_artifacts 3

artifact_dir="$LOG_DIR/patches/readonly-test-clone-iter3"
[[ -d "$artifact_dir" ]]
[[ -f "$artifact_dir/metadata.txt" ]]
[[ -f "$artifact_dir/summary.txt" ]]
find "$artifact_dir" -name '*.patch' -print | grep -q .
grep -q "base=$base" "$artifact_dir/metadata.txt"
grep -q "README.md" "$artifact_dir/summary.txt"

python3 - "$EVENT_LOG" "$artifact_dir" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1])]
event = next(event for event in events if event["type"] == "artifact.created")
assert event["payload"]["kind"] == "readonly_clone_patch"
assert event["payload"]["path"] == sys.argv[2]
assert event["payload"]["branch"] == "agent-1"
PY

echo "PASS test_readonly_clone_artifacts"
