#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

upstream="$TMPDIR/upstream"
worker="$TMPDIR/worker"
target="$TMPDIR/target"

mkdir -p "$upstream"
git -C "$upstream" init -q
git -C "$upstream" config user.name Test
git -C "$upstream" config user.email test@example.com
printf 'base\n' > "$upstream/README.md"
git -C "$upstream" add README.md
git -C "$upstream" commit -q -m base
base="$(git -C "$upstream" rev-parse HEAD)"

git clone -q "$upstream" "$worker"
git -C "$worker" config user.name Test
git -C "$worker" config user.email test@example.com
printf 'changed\n' > "$worker/README.md"
printf 'added\n' > "$worker/added.txt"
git -C "$worker" add README.md added.txt
git -C "$worker" commit -q -m "agent change"

export LOG_DIR="$TMPDIR/harness/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="apply"
export ITERATION="1"
export AGENTMILL_RUN_ID="apply-test"
export AGENTMILL_PROFILE_LEVEL="standard"
export AGENTMILL_WORKSPACE_MODE="readonly-clone"
export AGENT_BRANCH="agent-1"
export REPO_DIR="$worker"
export UPSTREAM_HEAD="$base"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

cd "$worker"
export_readonly_clone_artifacts 1 >/dev/null
artifact="$LOG_DIR/patches/apply-test-apply-iter1"

harness="$TMPDIR/harness"
cp "$REPO_ROOT/mill" "$harness/mill"
chmod +x "$harness/mill"

latest="$("$harness/mill" patches --latest)"
[[ "$latest" == "$artifact" ]]
list_output="$("$harness/mill" patches)"
[[ "$list_output" == *"apply-test-apply-iter1"* ]]
[[ "$list_output" == *"agent-1"* ]]

git clone -q "$upstream" "$target"
git -C "$target" config user.name Test
git -C "$target" config user.email test@example.com

"$REPO_ROOT/mill" apply "$artifact" "$target" --check >/tmp/agentmill-apply-check.out
grep -q "applies cleanly" /tmp/agentmill-apply-check.out
[[ "$(cat "$target/README.md")" == "base" ]]

"$REPO_ROOT/mill" apply "$artifact" "$target" --branch agent-apply >/tmp/agentmill-apply.out
[[ "$(git -C "$target" branch --show-current)" == "agent-apply" ]]
[[ "$(cat "$target/README.md")" == "changed" ]]
[[ "$(cat "$target/added.txt")" == "added" ]]
git -C "$target" log --oneline -1 | grep -q "agent change"

echo "PASS test_mill_apply_patches"
