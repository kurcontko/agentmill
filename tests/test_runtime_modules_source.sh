#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export AGENT_ID="module-test"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

for func in \
    log log_warn resolve_model log_claude_version require_auth \
    backup_project_settings restore_project_settings start_sentinel_watcher \
    push_failure_is_retryable memory_write memory_read results_log_append
do
    declare -F "$func" >/dev/null || {
        echo "missing runtime function: $func" >&2
        exit 1
    }
done

[[ "$(resolve_model opus)" == "claude-opus-4-7" ]]
push_failure_is_retryable '[rejected] (non-fast-forward)'

echo "PASS test_runtime_modules_source"
