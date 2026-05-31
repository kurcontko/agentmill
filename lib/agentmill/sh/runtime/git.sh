#!/usr/bin/env bash

push_failure_is_retryable() {
    case "$1" in
        *"[rejected]"*" (fetch first)"*|*"[rejected]"*" (non-fast-forward)"*|*"non-fast-forward"*) return 0 ;;
    esac
    return 1
}
