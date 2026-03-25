#!/usr/bin/env bash
set -euo pipefail

# — Configuration ————————————————————————————————
AGENT_ID="${AGENT_ID:-1}"
AGENT_BRANCH="${AGENT_BRANCH:-}"  # empty = auto-detect per mode
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
CODEX_MODEL="${CODEX_MODEL:-}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"  # 0 = infinite
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
LOOP_DELAY="${LOOP_DELAY:-5}"  # seconds between iterations
AUTO_COMMIT="${AUTO_COMMIT:-wip}"  # "off" | "wip" | "on"
PUSH_REBASE_MAX_RETRIES="${PUSH_REBASE_MAX_RETRIES:-3}"

. /entrypoint-common.sh

# — State ————————————————————————————————————————
ITERATION=0
SHUTTING_DOWN=false

# — Graceful shutdown ————————————————————————————
cleanup() {
    echo "[agentmill-codex] Received shutdown signal. Finishing current session..."
    SHUTTING_DOWN=true
}
trap cleanup SIGTERM SIGINT

# — Logging helper ———————————————————————————————
mkdir -p "$LOG_DIR"

log() {
    local msg="[agentmill-codex:agent-${AGENT_ID} $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/codex-agent-${AGENT_ID}.log"
}

push_branch_with_retries() {
    local branch="$1"
    local max_retries="${2:-$PUSH_REBASE_MAX_RETRIES}"
    local retry=0
    local push_output=""

    log "Pushing to upstream (branch: $branch)..."
    while true; do
        if push_output="$(git push --porcelain origin "$branch" 2>&1)"; then
            return 0
        fi

        if ! push_failure_is_retryable "$push_output"; then
            log "ERROR: git push failed permanently for branch $branch"
            while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                    log "git push: $line"
                fi
            done <<< "$push_output"
            return 1
        fi

        if [[ "$retry" -ge "$max_retries" ]]; then
            log "ERROR: push failed after $max_retries retries"
            return 1
        fi

        retry=$((retry + 1))
        log "Push failed, rebasing and retrying ($retry/$max_retries)..."

        if ! git fetch origin; then
            log "ERROR: git fetch failed during push retry $retry/$max_retries"
            return 1
        fi

        if ! git rebase "origin/$branch" 2>/dev/null; then
            git rebase --abort 2>/dev/null || true
            log "WARN: Rebase conflict on retry $retry/$max_retries, will retry next iteration"
            return 1
        fi
    done
}

require_codex_auth
configure_git_identity "$GIT_USER" "$GIT_EMAIL" "$AGENT_ID"

# — Workspace setup ——————————————————————————————
UPSTREAM_DIR="/workspace/upstream"
REPO_DIR="/workspace/repo"

if [[ -d "$UPSTREAM_DIR/.git" ]] || [[ -f "$UPSTREAM_DIR/HEAD" ]]; then
    REPO_DIR="/workspace/repo-${AGENT_ID}"
    : "${AGENT_BRANCH:=codex-agent-${AGENT_ID}}"
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

# — Main loop ————————————————————————————————————
log "Starting Codex agent loop (max_iterations=$MAX_ITERATIONS${CODEX_MODEL:+ model=$CODEX_MODEL})"

while true; do
    if [[ "$SHUTTING_DOWN" == true ]]; then
        log "Shutdown requested. Exiting loop."
        break
    fi

    ITERATION=$((ITERATION + 1))
    ITER_START_TIME="$(date +%s)"
    SESSION_LOG="$LOG_DIR/codex_session_$(date -u '+%Y%m%d_%H%M%S')_iter${ITERATION}.log"

    log "==== Iteration $ITERATION ===="

    if [[ ! -f "$PROMPT_FILE" ]]; then
        log "ERROR: Prompt file not found at $PROMPT_FILE"
        exit 1
    fi

    # Build codex exec args
    codex_args=(exec -C "$REPO_DIR" --dangerously-bypass-approvals-and-sandbox)
    if [[ -n "$CODEX_MODEL" ]]; then
        codex_args+=(-m "$CODEX_MODEL")
    fi

    log "Running Codex (session log: $SESSION_LOG)..."
    set +e
    codex "${codex_args[@]}" - < "$PROMPT_FILE" 2>&1 | tee "$SESSION_LOG"
    CODEX_EXIT=$?
    set -e

    log "Codex exited with code $CODEX_EXIT"

    # Commit any changes
    if [[ -n "$(git status --porcelain)" ]]; then
        LAST_COMMIT_TIME="$(git log -1 --format='%ct' 2>/dev/null || echo 0)"
        AGENT_COMMITTED=false
        if [[ "$LAST_COMMIT_TIME" -ge "$ITER_START_TIME" ]] 2>/dev/null; then
            AGENT_COMMITTED=true
        fi

        case "$AUTO_COMMIT" in
            off)
                log "Auto-commit disabled. Uncommitted changes left in working tree."
                ;;
            wip)
                if [[ "$AGENT_COMMITTED" == true ]]; then
                    if [[ -n "$(git status --porcelain)" ]]; then
                        log "Safety-net: committing leftover uncommitted changes as [wip]..."
                        git add -A
                        git commit -m "[wip] codex-agent-${AGENT_ID}: uncommitted leftovers from iteration $ITERATION"
                    fi
                else
                    log "Safety-net: agent made no commits, saving work as [wip]..."
                    git add -A
                    git commit -m "[wip] codex-agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
                fi
                ;;
            on|*)
                log "Committing changes..."
                git add -A
                git commit -m "codex-agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
                log "Changes committed."
                ;;
        esac

        if [[ "$MULTI_AGENT" == true ]] && ! push_branch_with_retries "$AGENT_BRANCH"; then
            log "WARN: Skipping push for iteration $ITERATION"
        fi
    else
        log "No changes to commit."
    fi

    if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
        log "Reached max iterations ($MAX_ITERATIONS). Stopping."
        break
    fi

    log "Sleeping ${LOOP_DELAY}s before next iteration..."
    sleep "$LOOP_DELAY"
done

log "Codex agent loop finished after $ITERATION iterations."
