#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export MEMORY_DIR="$TMPDIR/memory"
export LOG_DIR="$TMPDIR/logs"
export CLAIMS_FILE="$MEMORY_DIR/in_progress.md"
export AGENT_ID="test"
export MAX_ITERATIONS=3
export ITERATION=1
mkdir -p "$MEMORY_DIR" "$LOG_DIR"

# shellcheck source=../entrypoint-common.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/entrypoint-common.sh"

count_claims_for_task() {
    awk -v task="$1" 'BEGIN { FS = sprintf("%c", 9) } NF >= 3 && $NF == task { count++ } END { print count + 0 }' "$CLAIMS_FILE"
}

claim_task "foobar" "agent-1"
claim_task "foo" "agent-2"
[[ "$(count_claims_for_task "foobar")" -eq 1 ]]
[[ "$(count_claims_for_task "foo")" -eq 1 ]]

set +e
claim_task "foo" "agent-3" >/dev/null 2>&1
duplicate_rc=$?
set -e
[[ "$duplicate_rc" -ne 0 ]]

release_task "foo"
[[ "$(count_claims_for_task "foo")" -eq 0 ]]
[[ "$(count_claims_for_task "foobar")" -eq 1 ]]

rm -rf "$CLAIMS_FILE" "$CLAIMS_FILE.lock" "$CLAIMS_FILE.lock.d"
pids=()
for i in $(seq 1 20); do
    (
        claim_task "parallel-$i" "agent-$i"
    ) &
    pids+=("$!")
done
for pid in "${pids[@]}"; do
    wait "$pid"
done
[[ "$(awk -v prefix="parallel-" 'BEGIN { FS = sprintf("%c", 9) } NF >= 3 && index($NF, prefix) == 1 { count++ } END { print count + 0 }' "$CLAIMS_FILE")" -eq 20 ]]

repo="$TMPDIR/repo"
git init -q "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/base.txt"
git -C "$repo" add base.txt
git -C "$repo" commit -q -m base
base_sha="$(git -C "$repo" rev-parse HEAD)"
(
    cd "$repo"
    printf 'changed\n' > committed.txt
    git add committed.txt
    git commit -q -m committed
    printf 'untracked\n' > untracked.txt
    [[ "$(iteration_changed_file_count "$base_sha")" -eq 2 ]]
)

status_write 2 running "session:test.log"
python3 - "$LOG_DIR/status-test.json" <<'PY'
import json
import sys

status = json.load(open(sys.argv[1], encoding="utf-8"))
assert status["agent"] == "test", status
assert status["iteration"] == 2, status
assert status["max_iterations"] == 3, status
assert status["state"] == "running", status
assert status["detail"] == "session:test.log", status
PY

grep -q 'ITER_COMMITS_BEFORE=.*git rev-list --count HEAD' "$REPO_ROOT/entrypoint.sh"
grep -q 'ITER_FILES_CHANGED=.*iteration_changed_file_count' "$REPO_ROOT/entrypoint.sh"
grep -q 'CLAUDE_EXIT.*DONE_SIGNALED.*error' "$REPO_ROOT/entrypoint.sh"

echo "PASS test_review_fixes_entrypoint"
