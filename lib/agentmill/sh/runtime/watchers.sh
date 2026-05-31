#!/usr/bin/env bash

start_sentinel_watcher() {
    local target_pid="$1" mode="${2:-pid}" interval="${3:-1}"
    local done_file="${DONE_FILE:-/tmp/.agentmill-done}"
    local flag_file="${SENTINEL_SIGNAL_FLAG_FILE:-/tmp/.agentmill-sentinel-signal}"
    (
        while kill -0 "$target_pid" 2>/dev/null; do
            if [[ -f "$done_file" ]]; then
                sleep 2
                if [[ "$mode" == "process_group" ]]; then
                    : > "$flag_file"
                    kill -TERM 0 2>/dev/null || true
                else
                    kill -TERM "$target_pid" 2>/dev/null || true
                fi
                break
            fi
            sleep "$interval"
        done
    ) &
    SENTINEL_WATCHER_PID=$!
}

stop_sentinel_watcher() {
    [[ -n "${SENTINEL_WATCHER_PID:-}" ]] || return 0
    kill "$SENTINEL_WATCHER_PID" 2>/dev/null || true
    wait "$SENTINEL_WATCHER_PID" 2>/dev/null || true
    unset SENTINEL_WATCHER_PID
}
