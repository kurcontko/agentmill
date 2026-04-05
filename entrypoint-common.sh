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

# --- Shared markdown memory layer ---
# Append-only, lock-guarded, per-topic .md files in a shared memory/ directory.
# Safe for multi-agent concurrent writes. Uses flock (Linux) or mkdir (macOS/portable).

MEMORY_DIR="${MEMORY_DIR:-/workspace/memory}"

# Portable exclusive lock: flock if available, mkdir fallback
_lock_acquire() {
    local lockpath="$1" timeout="${2:-5}" i=0
    if command -v flock >/dev/null 2>&1; then
        exec 200>"$lockpath"
        flock -x -w "$timeout" 200
        return $?
    fi
    # mkdir-based fallback (atomic on POSIX)
    while ! mkdir "$lockpath.d" 2>/dev/null; do
        i=$((i + 1))
        [[ "$i" -ge "$((timeout * 10))" ]] && return 1
        sleep 0.1
    done
}

_lock_release() {
    local lockpath="$1"
    if command -v flock >/dev/null 2>&1; then
        exec 200>&-
    else
        rmdir "$lockpath.d" 2>/dev/null || true
    fi
}

memory_init() {
    mkdir -p "$MEMORY_DIR"
}

# memory_write <topic> <content> [agent_id]
# Appends a timestamped entry to memory/<topic>.md under exclusive lock.
memory_write() {
    local topic="$1" content="$2" agent="${3:-${AGENT_ID:-unknown}}"
    local file="$MEMORY_DIR/${topic}.md"
    local lock="$MEMORY_DIR/.${topic}.lock"
    memory_init

    if _lock_acquire "$lock" 5; then
        printf '\n---\nagent: %s\ntimestamp: %s\n---\n%s\n' \
            "$agent" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$content" >> "$file"
        _lock_release "$lock"
    else
        log "WARN: memory lock timeout for $topic"
        return 1
    fi
}

# memory_read <topic> [tail_lines]
# Reads memory/<topic>.md (no lock needed for reads).
memory_read() {
    local topic="$1" lines="${2:-50}"
    local file="$MEMORY_DIR/${topic}.md"
    [[ -f "$file" ]] || { echo "(no memory for topic: $topic)"; return 0; }
    tail -n "$lines" "$file"
}

# memory_list — show all topics
memory_list() {
    memory_init
    find "$MEMORY_DIR" -name '*.md' -exec basename {} .md \; 2>/dev/null | sort
}

# memory_search <pattern> — grep across all memory files
memory_search() {
    memory_init
    grep -rl "$1" "$MEMORY_DIR"/*.md 2>/dev/null | while read -r f; do
        echo "=== $(basename "$f" .md) ==="
        grep -n "$1" "$f"
    done
}

# --- Iteration log (Karpathy autoresearch pattern) ---
# Append-only TSV: iteration | agent | timestamp | files_changed | commits | status | description
RESULTS_LOG="${RESULTS_LOG:-/workspace/logs/results.tsv}"

results_log_init() {
    mkdir -p "$(dirname "$RESULTS_LOG")"
    [[ -f "$RESULTS_LOG" ]] || printf 'iteration\tagent\ttimestamp\tfiles_changed\tcommits\tstatus\tdescription\n' > "$RESULTS_LOG"
}

# results_log_append <iteration> <agent> <files_changed> <commits> <status> <description>
results_log_append() {
    local iter="$1" agent="$2" files="$3" commits="$4" status="$5" desc="$6"
    local lock="${RESULTS_LOG}.lock"
    results_log_init
    if _lock_acquire "$lock" 5; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$iter" "$agent" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$files" "$commits" "$status" "$desc" >> "$RESULTS_LOG"
        _lock_release "$lock"
    else
        log "WARN: results log lock timeout"
    fi
}
