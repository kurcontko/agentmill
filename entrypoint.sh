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
AUTO_COMMIT="${AUTO_COMMIT:-wip}"  # "off" = no auto-commit, "wip" = safety-net [wip] only, "on" = always commit (legacy)
PUSH_REBASE_MAX_RETRIES="${PUSH_REBASE_MAX_RETRIES:-3}"
DONE_FILE="${DONE_FILE:-/tmp/.agentmill-done}"

# shellcheck source=/entrypoint-common.sh
. /entrypoint-common.sh

# — State ————————————————————————————————————————
ITERATION=0
SHUTTING_DOWN=false

# — Graceful shutdown ————————————————————————————
cleanup() { log "Received shutdown signal. Finishing current session..."; SHUTTING_DOWN=true; }
trap cleanup SIGTERM SIGINT

# LOG_DIR already initialized by entrypoint-common.sh

push_branch_with_retries() {
    local branch="$1" max_retries="${2:-$PUSH_REBASE_MAX_RETRIES}" retry=0 push_output

    log "Pushing to upstream (branch: $branch)..."
    while true; do
        if push_output="$(git push --porcelain origin "$branch" 2>&1)"; then return 0; fi

        if ! push_failure_is_retryable "$push_output"; then
            log "ERROR: git push failed permanently: $push_output"
            return 1
        fi
        [[ "$retry" -lt "$max_retries" ]] || { log "ERROR: push failed after $max_retries retries"; return 1; }

        retry=$((retry + 1))
        log "Push rejected, rebasing and retrying ($retry/$max_retries)..."
        git fetch origin || { log "ERROR: git fetch failed on retry $retry"; return 1; }
        git rebase "origin/$branch" 2>/dev/null || { git rebase --abort 2>/dev/null || true; log "WARN: Rebase conflict on retry $retry"; return 1; }
    done
}

require_auth
merge_host_claude_config
results_log_init
memory_init
configure_git_identity "$GIT_USER" "$GIT_EMAIL" "$AGENT_ID"

# — Workspace setup: auto-detect single/multi-agent/worktree mode —
UPSTREAM_DIR="/workspace/upstream"
REPO_DIR="/workspace/repo"

if [[ -d "$UPSTREAM_DIR/.git" ]] || [[ -f "$UPSTREAM_DIR/HEAD" ]]; then
    # Multi-agent: clone upstream into isolated workspace per agent
    REPO_DIR="/workspace/repo-${AGENT_ID}"
    : "${AGENT_BRANCH:=agent-${AGENT_ID}}"
    MULTI_AGENT=true

    log "Multi-agent mode: agent-${AGENT_ID} on branch ${AGENT_BRANCH}"
    git -C "$UPSTREAM_DIR" config receive.denyCurrentBranch updateInstead 2>/dev/null || true

    if [[ ! -d "$REPO_DIR/.git" ]]; then
        git clone "$UPSTREAM_DIR" "$REPO_DIR"
        cd "$REPO_DIR"
        git remote set-url origin "$UPSTREAM_DIR"
    else
        cd "$REPO_DIR"
        git fetch origin
    fi

    UPSTREAM_HEAD="$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
    if git show-ref --verify --quiet "refs/heads/$AGENT_BRANCH"; then
        git checkout "$AGENT_BRANCH"
        # Fast-forward to upstream if behind
        git rebase "$UPSTREAM_HEAD" 2>/dev/null || git rebase --abort
    else
        git checkout -b "$AGENT_BRANCH" "$UPSTREAM_HEAD"
    fi

    log "Repo ready at $REPO_DIR (branch: $(git branch --show-current))"

elif [[ -d "$REPO_DIR/.git" ]] || [[ -f "$REPO_DIR/.git" ]]; then
    MULTI_AGENT=false
    : "${AGENT_BRANCH:=main}"
    cd "$REPO_DIR"
    log "Repo ready at $REPO_DIR (direct mount)"
else
    log "ERROR: No repo found. Mount to /workspace/repo (single) or /workspace/upstream (multi)."
    exit 1
fi

prepare_repo_environment "$REPO_DIR"

# — Override project settings for autonomous mode ————————
backup_project_settings ".claude/settings.local.json"
write_project_settings "$(autonomous_settings_json)"
trap 'restore_project_settings' EXIT

# — Main loop ————————————————————————————————————
log "Starting agent loop (model=$MODEL, max_iterations=$MAX_ITERATIONS)"

while true; do
    if [[ "$SHUTTING_DOWN" == true ]]; then
        log "Shutdown requested. Exiting loop."
        break
    fi

    ITERATION=$((ITERATION + 1))
    ITER_START_TIME="$(date +%s)"
    SESSION_LOG="$LOG_DIR/session_$(date -u '+%Y%m%d_%H%M%S')_iter${ITERATION}.log"

    log "==== Iteration $ITERATION ===="

    [[ -f "$PROMPT_FILE" ]] || { log "ERROR: Prompt file not found at $PROMPT_FILE"; exit 1; }
    rm -f "$DONE_FILE"

    log "Running Claude (session log: $SESSION_LOG)..."
    PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

    # Inject iteration context from previous run (Karpathy pattern: carry forward)
    if [[ "$ITERATION" -gt 1 ]]; then
        ITER_CTX="$(iteration_context)"
        PROMPT_CONTENT="$(cat "$ITER_CTX")

$PROMPT_CONTENT"
    fi

    set +e
    claude --dangerously-skip-permissions \
        -p "$PROMPT_CONTENT" \
        --model "$MODEL" \
        > >(tee "$SESSION_LOG") 2>&1 &
    CLAUDE_PID=$!
    start_sentinel_watcher "$CLAUDE_PID"
    wait "$CLAUDE_PID" 2>/dev/null
    CLAUDE_EXIT=$?
    stop_sentinel_watcher
    set -e

    log "Claude exited with code $CLAUDE_EXIT"

    if [[ -f "$DONE_FILE" ]]; then log "Agent signaled done"; else log "WARN: Agent exited without signaling done"; fi

    # Capture iteration metrics for results log
    ITER_FILES_CHANGED="$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')"
    ITER_COMMITS_BEFORE="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

    # Commit changes (controlled by AUTO_COMMIT)
    if [[ -n "$(git status --porcelain)" ]]; then
        LAST_COMMIT_TIME="$(git log -1 --format='%ct' 2>/dev/null || echo 0)"
        AGENT_COMMITTED=false
        [[ "$LAST_COMMIT_TIME" -ge "$ITER_START_TIME" ]] 2>/dev/null && AGENT_COMMITTED=true

        case "$AUTO_COMMIT" in
            off) log "Auto-commit disabled." ;;
            wip)
                if [[ "$AGENT_COMMITTED" == true ]]; then
                    # Safety-net leftovers only
                    [[ -n "$(git status --porcelain)" ]] && { git add -A; git commit -m "[wip] agent-${AGENT_ID}: leftovers from iteration $ITERATION"; }
                else
                    git add -A; git commit -m "[wip] agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
                fi ;;
            on|*)
                git add -A; git commit -m "agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" ;;
        esac

        if [[ "$MULTI_AGENT" == true ]] && ! push_branch_with_retries "$AGENT_BRANCH"; then
            log "WARN: Skipping push for iteration $ITERATION"
        fi
    else
        log "No changes to commit."
    fi

    # Log iteration results (Karpathy autoresearch pattern)
    ITER_COMMITS_AFTER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
    ITER_NEW_COMMITS=$((ITER_COMMITS_AFTER - ITER_COMMITS_BEFORE))
    ITER_STATUS="kept"
    [[ "$ITER_FILES_CHANGED" -eq 0 && "$ITER_NEW_COMMITS" -eq 0 ]] && ITER_STATUS="noop"
    [[ "$CLAUDE_EXIT" -ne 0 ]] && ITER_STATUS="error"
    ITER_DESC="exit=$CLAUDE_EXIT"
    [[ -f "$DONE_FILE" ]] && ITER_DESC="done"
    results_log_append "$ITERATION" "$AGENT_ID" "$ITER_FILES_CHANGED" "$ITER_NEW_COMMITS" "$ITER_STATUS" "$ITER_DESC"

    # Check iteration limit
    if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
        log "Reached max iterations ($MAX_ITERATIONS). Stopping."
        break
    fi

    # Brief pause before next iteration
    log "Sleeping ${LOOP_DELAY}s before next iteration..."
    sleep "$LOOP_DELAY"
done

log "Agent loop finished after $ITERATION iterations."
