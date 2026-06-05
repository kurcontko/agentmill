#!/usr/bin/env bash

# Append-only, lock-guarded, per-topic .md files in a shared memory/ directory.
# Safe for multi-agent concurrent writes. Uses flock (Linux) or mkdir (macOS/portable).
MEMORY_DIR="${MEMORY_DIR:-/workspace/memory}"

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

memory_read() {
    local topic="$1" lines="${2:-50}"
    local file="$MEMORY_DIR/${topic}.md"
    [[ -f "$file" ]] || { echo "(no memory for topic: $topic)"; return 0; }
    tail -n "$lines" "$file"
}

memory_list() {
    memory_init
    find "$MEMORY_DIR" -name '*.md' -exec basename {} .md \; 2>/dev/null | sort
}

memory_search() {
    memory_init
    grep -rl "$1" "$MEMORY_DIR"/*.md 2>/dev/null | while read -r f; do
        echo "=== $(basename "$f" .md) ==="
        grep -n "$1" "$f"
    done
}

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

failed_approaches_append() {
    local summary="$1" reason="${2:-no reason given}"
    memory_write failed_approaches "$(printf -- '- **%s**\n  reason: %s' "$summary" "$reason")"
}

CLAIMS_FILE="${CLAIMS_FILE:-${MEMORY_DIR:-/workspace/memory}/in_progress.md}"

claim_task() {
    local task="$1" agent="${2:-${AGENT_ID:-unknown}}"
    local lock="${CLAIMS_FILE}.lock"
    memory_init
    [[ -f "$CLAIMS_FILE" ]] || printf '# In-progress task claims\n\n' > "$CLAIMS_FILE"
    if _lock_acquire "$lock" 5; then
        if grep -qF "	${task}" "$CLAIMS_FILE" 2>/dev/null; then
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
        grep -vF "	${task}" "$CLAIMS_FILE" > "$tmp" || true
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

RESULTS_LOG="${RESULTS_LOG:-/workspace/logs/results.tsv}"

results_log_init() {
    mkdir -p "$(dirname "$RESULTS_LOG")"
    [[ -f "$RESULTS_LOG" ]] || printf 'iteration\tagent\ttimestamp\tfiles_changed\tcommits\tstatus\tdescription\n' > "$RESULTS_LOG"
}

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
