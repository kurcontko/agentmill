#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export MEMORY_DIR="$TMPDIR/memory"
export LOG_DIR="$TMPDIR/logs"
export CLAIMS_FILE="$MEMORY_DIR/in_progress.md"
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
[[ "$duplicate_rc" -ne 0 ]] || {
    echo "expected duplicate task claim to fail" >&2
    exit 1
}

release_task "foo"
[[ "$(count_claims_for_task "foo")" -eq 0 ]]
[[ "$(count_claims_for_task "foobar")" -eq 1 ]]

release_task "foobar"
[[ "$(count_claims_for_task "foobar")" -eq 0 ]]

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

echo "PASS test_task_claims"
