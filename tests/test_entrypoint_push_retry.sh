#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT_SH="$REPO_ROOT/entrypoint.sh"

extract_function() {
    local func_name="$1"
    sed -n "/^${func_name}()/,/^}/p" "$ENTRYPOINT_SH"
    return 0
}

test_push_branch_with_retries_stops_after_three_retries() {
    local -a logs=()
    local push_calls=0
    local fetch_calls=0
    local rebase_calls=0
    local abort_calls=0

    log() {
        logs+=("$*")
        return 0
    }

    git() {
        local cmd="$1"
        case "$cmd" in
            push)
                push_calls=$((push_calls + 1))
                return 1
                ;;
            fetch)
                fetch_calls=$((fetch_calls + 1))
                return 0
                ;;
            rebase)
                if [[ "${2:-}" = "--abort" ]]; then
                    abort_calls=$((abort_calls + 1))
                    return 0
                fi
                rebase_calls=$((rebase_calls + 1))
                return 0
                ;;
            *)
                echo "unexpected git invocation: $*" >&2
                return 1
                ;;
        esac
    }

    PUSH_REBASE_MAX_RETRIES=3
    eval "$(extract_function push_branch_with_retries)"

    set +e
    push_branch_with_retries "agent-test"
    local status=$?
    set -e

    [[ "$status" -eq 1 ]]
    [[ "$push_calls" -eq 4 ]]
    [[ "$fetch_calls" -eq 3 ]]
    [[ "$rebase_calls" -eq 3 ]]
    [[ "$abort_calls" -eq 0 ]]
    printf '%s\n' "${logs[@]}" | grep -Fx 'ERROR: push failed after 3 retries' >/dev/null
}

test_push_branch_with_retries_aborts_on_rebase_conflict() {
    local -a logs=()
    local push_calls=0
    local fetch_calls=0
    local rebase_calls=0
    local abort_calls=0

    log() {
        logs+=("$*")
        return 0
    }

    git() {
        local cmd="$1"
        case "$cmd" in
            push)
                push_calls=$((push_calls + 1))
                return 1
                ;;
            fetch)
                fetch_calls=$((fetch_calls + 1))
                return 0
                ;;
            rebase)
                if [[ "${2:-}" = "--abort" ]]; then
                    abort_calls=$((abort_calls + 1))
                    return 0
                fi
                rebase_calls=$((rebase_calls + 1))
                return 1
                ;;
            *)
                echo "unexpected git invocation: $*" >&2
                return 1
                ;;
        esac
    }

    PUSH_REBASE_MAX_RETRIES=3
    eval "$(extract_function push_branch_with_retries)"

    set +e
    push_branch_with_retries "agent-test"
    local status=$?
    set -e

    [[ "$status" -eq 1 ]]
    [[ "$push_calls" -eq 1 ]]
    [[ "$fetch_calls" -eq 1 ]]
    [[ "$rebase_calls" -eq 1 ]]
    [[ "$abort_calls" -eq 1 ]]
    printf '%s\n' "${logs[@]}" | grep -Fx 'WARN: Rebase conflict on retry 1/3, will retry next iteration' >/dev/null
}

test_push_branch_with_retries_stops_after_three_retries
test_push_branch_with_retries_aborts_on_rebase_conflict

echo "PASS test_entrypoint_push_retry"
