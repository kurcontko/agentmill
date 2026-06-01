#!/usr/bin/env bash

LOG_DIR="${LOG_DIR:-/workspace/logs}"
mkdir -p "$LOG_DIR"

log() {
    local msg logfile
    if [[ -n "${AGENT_ID:-}" ]]; then
        msg="[agentmill:agent-${AGENT_ID} $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
        logfile="$LOG_DIR/agent-${AGENT_ID}.log"
    else
        msg="[agentmill $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
        logfile="$LOG_DIR/agent.log"
    fi
    echo "$msg"
    echo "$msg" >> "$logfile"
}

# Greppable error/warn helpers (clax convention): one line, literal ERROR/WARN
# token + reason. Use these so `grep -E '^.*ERROR' logs/agent-*.log` finds every
# real failure regardless of phrasing.
log_error() { log "ERROR $*"; }
log_warn()  { log "WARN $*";  }

json_escape() {
    python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

status_write() {
    local iter="${1:-${ITERATION:-0}}" state="${2:-unknown}" detail="${3:-}" max_iter="${4:-${MAX_ITERATIONS:-0}}"
    local agent="${AGENT_ID:-1}" timestamp path lock
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    path="$LOG_DIR/status-${agent}.json"
    lock="${path}.lock"
    mkdir -p "$LOG_DIR"
    if _lock_acquire "$lock" 5; then
        printf '{"agent":%s,"iteration":%s,"max_iterations":%s,"state":%s,"detail":%s,"timestamp":%s}\n' \
            "$(printf '%s' "$agent" | json_escape)" \
            "$iter" \
            "$max_iter" \
            "$(printf '%s' "$state" | json_escape)" \
            "$(printf '%s' "$detail" | json_escape)" \
            "$(printf '%s' "$timestamp" | json_escape)" > "$path"
        _lock_release "$lock"
    else
        log_warn "status file lock timeout for $agent"
    fi
}

iteration_changed_file_count() {
    local base="${1:-HEAD}" tmp count
    tmp="$(mktemp)"
    if git rev-parse --verify "$base^{commit}" >/dev/null 2>&1; then
        git diff --name-only "$base"..HEAD >> "$tmp" 2>/dev/null || true
    fi
    git status --porcelain 2>/dev/null | sed -E 's/^...//' >> "$tmp" || true
    count="$(sort -u "$tmp" | grep -c . || true)"
    rm -f "$tmp"
    printf '%s' "${count:-0}"
}

require_auth() {
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        log "Auth: using ANTHROPIC_API_KEY"
    elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        log "Auth: using CLAUDE_CODE_OAUTH_TOKEN (subscription)"
        [[ -f "$HOME/.claude.json" ]] || printf '%s\n' '{"hasCompletedOnboarding":true}' > "$HOME/.claude.json"
    else
        log "ERROR: No auth configured."
        log "  Option 1: Set ANTHROPIC_API_KEY env var (API credits)"
        log "  Option 2: Set CLAUDE_CODE_OAUTH_TOKEN env var (subscription, from 'claude setup-token')"
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

# Portable exclusive lock: flock if available, mkdir fallback.
# flock mode uses fd 200, so callers should not hold nested locks in one shell.
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

# memory_clear <topic> — remove a topic file (with lock)
memory_clear() {
    local topic="$1"
    local file="$MEMORY_DIR/${topic}.md"
    local lock="$MEMORY_DIR/.${topic}.lock"
    [[ -f "$file" ]] || { echo "(no memory for topic: $topic)"; return 0; }
    if _lock_acquire "$lock" 5; then
        rm -f "$file"
        _lock_release "$lock"
    else
        log "WARN: memory lock timeout clearing $topic"
        return 1
    fi
}

# --- Standard memory topics (long-running-Claude conventions) ---
# These are plain memory topics, but documented as first-class so prompts can
# rely on them existing. Adopted from smsharma/clax CLAUDE.md.
#
#   failed_approaches.md — dead ends with one-line reason (read at Orient,
#                          prevents re-trying what's already known broken)
#   in_progress.md       — flock-guarded task-claim file for multi-agent
#   open_questions.md    — research worklist
#   contradictions.md    — sources that disagree
#   findings.md          — primary research notes (verbatim quotes)
#   sources.md           — deduplicated URL list
#   decisions.md         — methodology / scope decisions

# failed_approaches_append <one-line-summary> <reason>
# Appends a structured failed-approach entry. Use when an approach is abandoned.
failed_approaches_append() {
    local summary="$1" reason="${2:-no reason given}"
    memory_write failed_approaches "$(printf -- '- **%s**\n  reason: %s' "$summary" "$reason")"
}

# --- Task-claim file (multi-agent coordination) ---
# Single file: one line per active claim, format:
#   <iso-timestamp>\t<agent-id>\t<task-id>
# Atomic via flock; readers can `grep <task-id> in_progress.md` before claiming.

CLAIMS_FILE="${CLAIMS_FILE:-${MEMORY_DIR:-/workspace/memory}/in_progress.md}"

claim_task() {
    local task="$1" agent="${2:-${AGENT_ID:-unknown}}"
    local lock="${CLAIMS_FILE}.lock"
    memory_init
    if _lock_acquire "$lock" 5; then
        [[ -f "$CLAIMS_FILE" ]] || printf '# In-progress task claims\n\n' > "$CLAIMS_FILE"
        if awk -v task="$task" 'BEGIN { FS = sprintf("%c", 9) } NF >= 3 && $NF == task { found = 1; exit } END { exit found ? 0 : 1 }' "$CLAIMS_FILE" 2>/dev/null; then
            _lock_release "$lock"
            log_warn "claim_task: '$task' already claimed"
            return 1
        fi
        printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$task" >> "$CLAIMS_FILE"
        _lock_release "$lock"
    else
        log_warn "claim_task: lock timeout"
        return 1
    fi
}

release_task() {
    local task="$1"
    local lock="${CLAIMS_FILE}.lock"
    [[ -f "$CLAIMS_FILE" ]] || return 0
    if _lock_acquire "$lock" 5; then
        local tmp; tmp="$(mktemp)"
        awk -v task="$task" 'BEGIN { FS = sprintf("%c", 9) } !(NF >= 3 && $NF == task)' "$CLAIMS_FILE" > "$tmp"
        mv "$tmp" "$CLAIMS_FILE"
        _lock_release "$lock"
    else
        log_warn "release_task: lock timeout"
        return 1
    fi
}

list_claims() {
    [[ -f "$CLAIMS_FILE" ]] || { echo "(no active claims)"; return 0; }
    grep -v '^#\|^$' "$CLAIMS_FILE" || true
}

# memory_summary — one-line-per-topic overview (for iteration context)
memory_summary() {
    memory_init
    local file
    for file in "$MEMORY_DIR"/*.md; do
        [[ -f "$file" ]] || continue
        local topic count
        topic="$(basename "$file" .md)"
        count="$(grep -c '^---$' "$file" 2>/dev/null)" || count=0
        count=$(( count / 2 ))
        printf '  [[%s]] (%d entries)\n' "$topic" "$count"
    done
}

# iteration_context — generate context from previous iteration for next run
# Writes to /tmp/.agentmill-iter-context.md
iteration_context() {
    local ctx="/tmp/.agentmill-iter-context.md"
    {
        echo "## Previous Iteration Context"
        echo ""
        echo "### Recent commits"
        git log --oneline -5 2>/dev/null || echo "(none)"
        echo ""
        echo "### Memory topics"
        memory_summary
        echo ""
        if [[ -f "${MEMORY_DIR:-/workspace/memory}/failed_approaches.md" ]]; then
            echo "### Recent failed approaches (do not retry)"
            tail -20 "${MEMORY_DIR:-/workspace/memory}/failed_approaches.md"
            echo ""
        fi
        if [[ -f "$CLAIMS_FILE" ]] && [[ -s "$CLAIMS_FILE" ]]; then
            echo "### Tasks currently claimed by other agents"
            list_claims
            echo ""
        fi
        if [[ -f "$RESULTS_LOG" ]]; then
            echo "### Last result"
            tail -1 "$RESULTS_LOG"
        fi
    } > "$ctx"
    echo "$ctx"
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
