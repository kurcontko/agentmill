#!/usr/bin/env bash

LOG_DIR="${LOG_DIR:-/workspace/logs}"
mkdir -p "$LOG_DIR"

log() {
    local id="${AGENT_ID:-tui}"
    local msg
    msg="[agentmill:${id} $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent-${id}.log"
}

require_auth() {
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        log "Auth: using ANTHROPIC_API_KEY"
    elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        log "Auth: using CLAUDE_CODE_OAUTH_TOKEN (subscription)"
        [[ -f "$HOME/.claude.json" ]] || printf '%s\n' '{"hasCompletedOnboarding":true}' > "$HOME/.claude.json"
    else
        log "ERROR: No auth. Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN."
        exit 1
    fi
}

merge_host_claude_config() { /setup-claude-config.sh; }

configure_git_identity() {
    local name="${1}${3:+-$3}"
    git config --global user.name "$name"
    git config --global user.email "$2"
}

prepare_repo_environment() {
    log "Preparing repo environment..."
    # shellcheck disable=SC1091
    . /setup-repo-env.sh "$1"
    log "Repo environment ready."
}

# --- Project settings backup/restore ---
backup_project_settings() {
    SETTINGS_LOCAL_PATH="${1:-.claude/settings.local.json}"
    SETTINGS_BACKUP_FILE="" SETTINGS_BACKUP_EXISTS=false
    mkdir -p "$(dirname "$SETTINGS_LOCAL_PATH")"
    if [[ -f "$SETTINGS_LOCAL_PATH" ]]; then
        SETTINGS_BACKUP_FILE="$(mktemp)"
        cp "$SETTINGS_LOCAL_PATH" "$SETTINGS_BACKUP_FILE"
        SETTINGS_BACKUP_EXISTS=true
    fi
}

write_project_settings() {
    [[ -n "${SETTINGS_LOCAL_PATH:-}" ]] || { echo "call backup_project_settings first" >&2; return 1; }
    printf '%s\n' "$1" > "$SETTINGS_LOCAL_PATH"
}

restore_project_settings() {
    [[ -n "${SETTINGS_LOCAL_PATH:-}" ]] || return 0
    if [[ "${SETTINGS_BACKUP_EXISTS:-false}" == "true" && -f "${SETTINGS_BACKUP_FILE:-}" ]]; then
        cp "$SETTINGS_BACKUP_FILE" "$SETTINGS_LOCAL_PATH"
    else
        rm -f "$SETTINGS_LOCAL_PATH"
    fi
    rm -f "${SETTINGS_BACKUP_FILE:-}"
    unset SETTINGS_LOCAL_PATH SETTINGS_BACKUP_FILE SETTINGS_BACKUP_EXISTS
}

autonomous_settings_json() {
    printf '%s\n' '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit","mcp__*"],"defaultMode":"bypassPermissions"}}'
}

# --- Sentinel watcher: polls done file, signals target on completion ---
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

push_failure_is_retryable() {
    case "$1" in
        *"[rejected]"*" (fetch first)"*|*"[rejected]"*" (non-fast-forward)"*|*"non-fast-forward"*) return 0 ;;
    esac
    return 1
}
