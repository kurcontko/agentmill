#!/usr/bin/env bash

require_auth() {
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        log "Auth: using ANTHROPIC_API_KEY"
    elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        log "Auth: using CLAUDE_CODE_OAUTH_TOKEN (subscription)"
        if [[ ! -f "$HOME/.claude.json" ]]; then
            printf '%s\n' '{"hasCompletedOnboarding":true}' > "$HOME/.claude.json"
        fi
    else
        log "ERROR: No auth configured."
        log "  Option 1: Set ANTHROPIC_API_KEY env var (API credits)"
        log "  Option 2: Set CLAUDE_CODE_OAUTH_TOKEN env var (subscription, from 'claude setup-token')"
        exit 1
    fi
}

merge_host_claude_config() {
    /setup-claude-config.sh
}

configure_git_identity() {
    local git_user="$1"
    local git_email="$2"
    local suffix="${3:-}"
    local git_name="$git_user"

    if [[ -n "$suffix" ]]; then
        git_name="${git_user}-${suffix}"
    fi

    git config --global user.name "$git_name"
    git config --global user.email "$git_email"
}

prepare_repo_environment() {
    local repo_dir="$1"

    log "Preparing repo environment..."
    # shellcheck disable=SC1091
    . /setup-repo-env.sh "$repo_dir"
    log "Repo environment ready."
}

backup_project_settings() {
    SETTINGS_LOCAL_PATH="${1:-.claude/settings.local.json}"
    SETTINGS_BACKUP_FILE=""
    SETTINGS_BACKUP_EXISTS=false

    mkdir -p "$(dirname "$SETTINGS_LOCAL_PATH")"

    if [[ -f "$SETTINGS_LOCAL_PATH" ]]; then
        SETTINGS_BACKUP_FILE="$(mktemp)"
        cp "$SETTINGS_LOCAL_PATH" "$SETTINGS_BACKUP_FILE"
        SETTINGS_BACKUP_EXISTS=true
    fi
}

write_project_settings() {
    if [[ -z "${SETTINGS_LOCAL_PATH:-}" ]]; then
        echo "SETTINGS_LOCAL_PATH is not set; call backup_project_settings first" >&2
        return 1
    fi

    printf '%s\n' "$1" > "$SETTINGS_LOCAL_PATH"
}

autonomous_settings_json() {
    printf '%s\n' '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit","mcp__*"],"defaultMode":"bypassPermissions"}}'
}

# Start a background process that polls for the done sentinel file.
# When found, it either signals a target PID or the current process group.
start_sentinel_watcher() {
    local target_pid="$1"
    local signal_mode="${2:-pid}"
    local poll_interval="${3:-1}"
    local done_file="${DONE_FILE:-/tmp/.agentmill-done}"
    local signal_flag_file="${SENTINEL_SIGNAL_FLAG_FILE:-/tmp/.agentmill-sentinel-signal}"

    (
        while kill -0 "$target_pid" 2>/dev/null; do
            if [[ -f "$done_file" ]]; then
                sleep 2  # let Claude finish writing
                case "$signal_mode" in
                    pid)
                        kill -TERM "$target_pid" 2>/dev/null || true
                        ;;
                    process_group)
                        : > "$signal_flag_file"
                        kill -TERM 0 2>/dev/null || true
                        ;;
                    *)
                        echo "Unknown sentinel watcher mode: $signal_mode" >&2
                        ;;
                esac
                break
            fi
            sleep "$poll_interval"
        done
    ) &
    SENTINEL_WATCHER_PID=$!
}

stop_sentinel_watcher() {
    if [[ -n "${SENTINEL_WATCHER_PID:-}" ]]; then
        kill "$SENTINEL_WATCHER_PID" 2>/dev/null || true
        wait "$SENTINEL_WATCHER_PID" 2>/dev/null || true
        unset SENTINEL_WATCHER_PID
    fi
}

push_failure_is_retryable() {
    case "$1" in
        *"[rejected]"*" (fetch first)"*|*"[rejected]"*" (non-fast-forward)"*|*"non-fast-forward"*)
            return 0
            ;;
    esac

    return 1
}

restore_project_settings() {
    if [[ -z "${SETTINGS_LOCAL_PATH:-}" ]]; then
        return 0
    fi

    if [[ "${SETTINGS_BACKUP_EXISTS:-false}" == "true" ]] && [[ -n "${SETTINGS_BACKUP_FILE:-}" ]] && [[ -f "$SETTINGS_BACKUP_FILE" ]]; then
        cp "$SETTINGS_BACKUP_FILE" "$SETTINGS_LOCAL_PATH"
    else
        rm -f "$SETTINGS_LOCAL_PATH"
    fi

    if [[ -n "${SETTINGS_BACKUP_FILE:-}" ]]; then
        rm -f "$SETTINGS_BACKUP_FILE"
    fi

    unset SETTINGS_LOCAL_PATH SETTINGS_BACKUP_FILE SETTINGS_BACKUP_EXISTS
}
