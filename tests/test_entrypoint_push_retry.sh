#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

extract_function() {
    local func_name="$1"
    local file="$2"
    sed -n "/^${func_name}()/,/^}/p" "$REPO_ROOT/$file"
    return 0
}

test_push_failure_is_retryable_matches_only_sync_failures() {
    eval "$(extract_function push_failure_is_retryable entrypoint-common.sh)"

    push_failure_is_retryable '!	refs/heads/agent-1:refs/heads/agent-1	[rejected] (fetch first)'
    push_failure_is_retryable 'error: failed to push some refs to origin
hint: Updates were rejected because the tip of your current branch is behind
! [rejected]        agent-1 -> agent-1 (non-fast-forward)'

    if push_failure_is_retryable '!	refs/heads/agent-1:refs/heads/agent-1	[remote rejected] (pre-receive hook declined)'; then
        echo "classified pre-receive rejection as retryable" >&2
        return 1
    fi
}

test_push_failure_is_retryable_matches_only_sync_failures

echo "PASS test_entrypoint_push_retry"
