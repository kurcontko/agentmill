#!/usr/bin/env bash
set -euo pipefail

# — Configuration ————————————————————————————————
AGENT_ID="${AGENT_ID:-1}"
AGENT_BRANCH="${AGENT_BRANCH:-}"  # empty = auto-detect per mode
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
MODEL="${MODEL:-sonnet}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"  # 0 = infinite
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
LOOP_DELAY="${LOOP_DELAY:-5}"  # seconds between iterations

# — State ————————————————————————————————————————
ITERATION=0
SHUTTING_DOWN=false
MULTI_AGENT=false
REPO_DIR="/workspace/repo"
SETTINGS_LOCAL=""
SETTINGS_BACKUP=""

# — Logging helper ———————————————————————————————
LOG_FORMAT="${LOG_FORMAT:-text}"  # text or json
LOG_MAX_SIZE="${LOG_MAX_SIZE:-10485760}"  # 10MB default
LOG_MAX_FILES="${LOG_MAX_FILES:-5}"  # keep 5 rotated logs
mkdir -p "$LOG_DIR"

rotate_log() {
    local logfile="$LOG_DIR/agent-${AGENT_ID}.log"
    if [[ ! -f "$logfile" ]]; then
        return
    fi
    local size
    size="$(stat -c%s "$logfile" 2>/dev/null || stat -f%z "$logfile" 2>/dev/null || echo 0)"
    if [[ "$size" -ge "$LOG_MAX_SIZE" ]]; then
        # Rotate: remove oldest, shift others
        local i=$((LOG_MAX_FILES - 1))
        while [[ "$i" -gt 0 ]]; do
            local prev=$((i - 1))
            [[ -f "${logfile}.${prev}" ]] && mv "${logfile}.${prev}" "${logfile}.${i}"
            i=$((i - 1))
        done
        mv "$logfile" "${logfile}.0"
    fi
}

log() {
    local timestamp level msg logfile
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    logfile="$LOG_DIR/agent-${AGENT_ID}.log"

    # Parse optional log level: log "WARN: message" or log "message" (defaults to INFO)
    local all_args="$*"
    if [[ "$all_args" =~ ^(ERROR|WARN|INFO|DEBUG):[[:space:]]*(.*) ]]; then
        level="${BASH_REMATCH[1]}"
        msg="${BASH_REMATCH[2]}"
    else
        level="INFO"
        msg="$all_args"
    fi

    if [[ "$LOG_FORMAT" = "json" ]]; then
        local json_msg
        json_msg="$(jq -nc \
            --arg ts "$timestamp" \
            --arg level "$level" \
            --arg agent "$AGENT_ID" \
            --arg msg "$msg" \
            '{"timestamp":$ts,"level":$level,"agent":$agent,"message":$msg}')"
        echo "$json_msg"
        echo "$json_msg" >> "$logfile"
    else
        msg="[agentmill:agent-${AGENT_ID} ${timestamp}] ${level}: $msg"
        echo "$msg"
        echo "$msg" >> "$logfile"
    fi

    rotate_log
}

# — Graceful shutdown ————————————————————————————
cleanup() {
    log "Received shutdown signal. Finishing current session..."
    SHUTTING_DOWN=true
}
trap cleanup SIGTERM SIGINT

# — Auth check ———————————————————————————————————
check_auth() {
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        log "Auth: using ANTHROPIC_API_KEY"
    elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        log "Auth: using CLAUDE_CODE_OAUTH_TOKEN (subscription)"
        if [[ ! -f "$HOME/.claude.json" ]]; then
            echo '{"hasCompletedOnboarding":true}' > "$HOME/.claude.json"
        fi
    else
        log "ERROR: No auth configured. Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN."
        exit 1
    fi
}

# — Workspace setup ——————————————————————————————
# Three modes, auto-detected:
#
#   1. Single agent (default)
#      Mount: REPO_PATH -> /workspace/repo
#      Agent works directly in the mounted repo.
#
#   2. Multi-agent: independent clones
#      Mount: REPO_PATH -> /workspace/upstream (read-only)
#      Each agent clones into /workspace/repo-$AGENT_ID.
#      Sync via git push/pull to upstream.
#
#   3. Multi-agent: pre-created worktrees
#      Mount: host worktree -> /workspace/repo
#      Host creates worktrees beforehand; each agent gets its own mount.
#      From the agent's perspective, this looks like mode 1.

setup_workspace() {
    local upstream_dir="/workspace/upstream"

    if [[ -d "$upstream_dir/.git" || -f "$upstream_dir/HEAD" ]]; then
        # Mode 2: upstream mounted — clone into isolated workspace
        REPO_DIR="/workspace/repo-${AGENT_ID}"
        : "${AGENT_BRANCH:=agent-${AGENT_ID}}"
        MULTI_AGENT=true

        log "Multi-agent mode: agent-${AGENT_ID} on branch ${AGENT_BRANCH}"

        # Allow pushing to non-bare upstream (agents push to their own branches,
        # not the checked-out branch, so this is safe).
        if ! git -C "$upstream_dir" config receive.denyCurrentBranch updateInstead 2>/dev/null; then
            log "WARN: Could not set receive.denyCurrentBranch on upstream (may be read-only)"
        fi

        if [[ ! -d "$REPO_DIR/.git" ]]; then
            git clone "$upstream_dir" "$REPO_DIR"
            cd "$REPO_DIR"
            git remote set-url origin "$upstream_dir"
        else
            cd "$REPO_DIR"
            git fetch origin
        fi

        # Create or checkout agent branch from upstream's HEAD
        local upstream_head
        upstream_head="$(git -C "$upstream_dir" rev-parse HEAD)"
        if git show-ref --verify --quiet "refs/heads/$AGENT_BRANCH"; then
            git checkout "$AGENT_BRANCH"
            if ! git rebase "$upstream_head" 2>/dev/null; then
                log "WARN: Rebase onto upstream HEAD failed, aborting rebase"
                git rebase --abort
            fi
        else
            git checkout -b "$AGENT_BRANCH" "$upstream_head"
        fi

        log "Repo ready at $REPO_DIR (branch: $(git branch --show-current))"

    elif [[ -d "$REPO_DIR/.git" ]]; then
        # Mode 1 or 3: direct mount (single agent or pre-created worktree)
        MULTI_AGENT=false
        : "${AGENT_BRANCH:=main}"
        cd "$REPO_DIR"
        log "Repo ready at $REPO_DIR (direct mount)"
    else
        log "ERROR: No repo found. Mount to /workspace/repo (single) or /workspace/upstream (multi)."
        exit 1
    fi
}

# — Settings management —————————————————————————
setup_autonomous_settings() {
    SETTINGS_LOCAL=".claude/settings.local.json"
    SETTINGS_BACKUP=""
    mkdir -p .claude

    if [[ -f "$SETTINGS_LOCAL" ]]; then
        SETTINGS_BACKUP="$(cat "$SETTINGS_LOCAL")"
    fi

    # NOSONAR — autonomous agent container requires full tool permissions
    echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit","mcp__*"],"defaultMode":"bypassPermissions"}}' \
        > "$SETTINGS_LOCAL"
}

restore_settings() {
    if [[ -n "$SETTINGS_BACKUP" ]]; then
        if ! echo "$SETTINGS_BACKUP" > "$SETTINGS_LOCAL"; then
            log "WARN: Failed to restore settings.local.json"
        fi
    else
        rm -f "$SETTINGS_LOCAL"
    fi
}
trap 'restore_settings' EXIT

# — Push with retry ———————————————————————————————
push_with_retry() {
    local max_attempts=3
    local attempt=0

    while [[ "$attempt" -lt "$max_attempts" ]]; do
        attempt=$((attempt + 1))
        if git push origin "$AGENT_BRANCH" 2>/dev/null; then
            log "Push succeeded"
            return 0
        fi
        log "Push attempt $attempt/$max_attempts failed, fetching and rebasing..."
        git fetch origin
        if git rebase "origin/$AGENT_BRANCH" 2>/dev/null; then
            continue  # retry push
        else
            git rebase --abort
            log "WARN: Rebase conflict on attempt $attempt, will retry next iteration"
            return 1
        fi
    done
    log "WARN: Push failed after $max_attempts attempts, will retry next iteration"
    return 1
}

# — Run single iteration —————————————————————————
run_iteration() {
    local session_log
    session_log="$LOG_DIR/session_$(date -u '+%Y%m%d_%H%M%S')_iter${ITERATION}.log"

    log "==== Iteration $ITERATION ===="

    if [[ ! -f "$PROMPT_FILE" ]]; then
        log "ERROR: Prompt file not found at $PROMPT_FILE"
        log "Mount your prompt file or set PROMPT_FILE env var."
        exit 1
    fi

    # Run Claude
    log "Running Claude (session log: $session_log)..."
    local prompt_content
    prompt_content="$(cat "$PROMPT_FILE")"

    local claude_exit
    # NOSONAR — dangerously-skip-permissions is required for headless autonomous operation
    set +e
    claude --dangerously-skip-permissions \
        -p "$prompt_content" \
        --model "$MODEL" \
        2>&1 | tee "$session_log"
    claude_exit=$?
    set -e

    if [[ "$claude_exit" -ne 0 ]]; then
        log "WARN: Claude exited with code $claude_exit"
    else
        log "Claude completed successfully"
    fi

    # Commit any changes
    if [[ -n "$(git status --porcelain)" ]]; then
        log "Committing changes..."
        git add -A
        git commit -m "agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
        log "Changes committed."

        if [[ "$MULTI_AGENT" = true ]]; then
            log "Pushing to upstream (branch: $AGENT_BRANCH)..."
            push_with_retry || true
        fi
    else
        log "No changes to commit."
    fi
}

# — Main ——————————————————————————————————————————
main() {
    check_auth
    /setup-claude-config.sh

    git config --global user.name "${GIT_USER}-${AGENT_ID}"
    git config --global user.email "$GIT_EMAIL"

    setup_workspace

    log "Preparing repo environment..."
    . /setup-repo-env.sh "$REPO_DIR"
    log "Repo environment ready."

    setup_autonomous_settings

    log "Starting agent loop (model=$MODEL, max_iterations=$MAX_ITERATIONS)"

    while true; do
        if [[ "$SHUTTING_DOWN" = true ]]; then
            log "Shutdown requested. Exiting loop."
            break
        fi

        ITERATION=$((ITERATION + 1))
        run_iteration

        if [[ "$MAX_ITERATIONS" -gt 0 && "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
            log "Reached max iterations ($MAX_ITERATIONS). Stopping."
            break
        fi

        log "Sleeping ${LOOP_DELAY}s before next iteration..."
        sleep "$LOOP_DELAY"
    done

    log "Agent loop finished after $ITERATION iterations."
}

main "$@"
