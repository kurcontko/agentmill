#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="${AGENT_ID:-1}"
AGENT_BRANCH="${AGENT_BRANCH:-}"
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
CODEX_MODEL="${CODEX_MODEL:-}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
LOOP_DELAY="${LOOP_DELAY:-5}"
PREVIEW_APP_URL="${PREVIEW_APP_URL:-}"
ITERATION=0
SHUTTING_DOWN=false
PREVIEW_STATUS_FILE=""

cleanup() {
    echo "[agentmill-codex] Received shutdown signal. Finishing current session..."
    SHUTTING_DOWN=true
}
trap cleanup SIGTERM SIGINT

mkdir -p "$LOG_DIR"

log() {
    local msg="[agentmill-codex:agent-${AGENT_ID} $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/codex-agent-${AGENT_ID}.log"
}

update_preview_status() {
    local state="$1"
    if [ -z "$PREVIEW_STATUS_FILE" ] || [ ! -f "$PREVIEW_STATUS_FILE" ]; then
        return 0
    fi

    local commit branch
    commit="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    branch="$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || true)"

    local tmp_file
    tmp_file="$(mktemp)"
    jq \
        --arg state "$state" \
        --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg commit "$commit" \
        --arg branch "$branch" \
        '.state = $state | .updated_at = $updated_at | .commit = $commit | .branch = $branch' \
        "$PREVIEW_STATUS_FILE" > "$tmp_file"
    mv "$tmp_file" "$PREVIEW_STATUS_FILE"
}

if [ -n "${OPENAI_API_KEY:-}" ]; then
    log "Auth: using OPENAI_API_KEY"
elif [ -d "$HOME/.codex" ]; then
    log "Auth: using mounted ~/.codex state"
else
    log "ERROR: No Codex auth configured."
    log "  Option 1: Set OPENAI_API_KEY env var"
    log "  Option 2: Mount ~/.codex from a host that already ran 'codex --login'"
    exit 1
fi

git config --global user.name "${GIT_USER}-${AGENT_ID}"
git config --global user.email "$GIT_EMAIL"

UPSTREAM_DIR="/workspace/upstream"
REPO_DIR="/workspace/repo"

if [ -d "$UPSTREAM_DIR/.git" ] || [ -f "$UPSTREAM_DIR/HEAD" ]; then
    REPO_DIR="/workspace/repo-${AGENT_ID}"
    : "${AGENT_BRANCH:=codex-agent-${AGENT_ID}}"
    MULTI_AGENT=true

    log "Multi-agent mode: agent-${AGENT_ID} on branch ${AGENT_BRANCH}"
    git -C "$UPSTREAM_DIR" config receive.denyCurrentBranch updateInstead 2>/dev/null || true

    if [ ! -d "$REPO_DIR/.git" ]; then
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
elif [ -d "$REPO_DIR/.git" ] || [ -f "$REPO_DIR/.git" ]; then
    MULTI_AGENT=false
    : "${AGENT_BRANCH:=main}"
    cd "$REPO_DIR"
    log "Repo ready at $REPO_DIR (direct mount)"
else
    log "ERROR: No repo found. Mount to /workspace/repo (single) or /workspace/upstream (multi)."
    exit 1
fi

log "Preparing repo environment..."
. /setup-repo-env.sh "$REPO_DIR"
log "Repo environment ready."

log "Starting Codex agent loop (max_iterations=$MAX_ITERATIONS${CODEX_MODEL:+ model=$CODEX_MODEL})"

while true; do
    if [ "$SHUTTING_DOWN" = true ]; then
        log "Shutdown requested. Exiting loop."
        break
    fi

    ITERATION=$((ITERATION + 1))
    PREVIEW_STATUS_FILE="$LOG_DIR/codex-preview/agent-${AGENT_ID}/status.json"

    log "==== Iteration $ITERATION ===="

    if [ ! -f "$PROMPT_FILE" ]; then
        log "ERROR: Prompt file not found at $PROMPT_FILE"
        exit 1
    fi

    supervisor_args=(
        /codex_preview_supervisor.py
        --repo-dir "$REPO_DIR"
        --prompt-file "$PROMPT_FILE"
        --log-dir "$LOG_DIR"
        --agent-id "$AGENT_ID"
        --iteration "$ITERATION"
        --max-iterations "$MAX_ITERATIONS"
    )
    if [ -n "$CODEX_MODEL" ]; then
        supervisor_args+=(--model "$CODEX_MODEL")
    fi
    if [ -n "$PREVIEW_APP_URL" ]; then
        supervisor_args+=(--preview-app-url "$PREVIEW_APP_URL")
    fi

    log "Running Codex with preview supervisor..."
    set +e
    python3 "${supervisor_args[@]}"
    CODEX_EXIT=$?
    set -e

    log "Codex exited with code $CODEX_EXIT"

    if [ -n "$(git status --porcelain)" ]; then
        log "Committing changes..."
        git add -A
        git commit -m "codex-agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
        log "Changes committed."

        if [ "$MULTI_AGENT" = true ]; then
            log "Pushing to upstream (branch: $AGENT_BRANCH)..."
            if ! git push origin "$AGENT_BRANCH" 2>/dev/null; then
                log "Push failed, rebasing and retrying..."
                git fetch origin
                if git rebase "origin/$AGENT_BRANCH" 2>/dev/null; then
                    git push origin "$AGENT_BRANCH" || log "WARN: Push failed, will retry next iteration"
                else
                    git rebase --abort
                    log "WARN: Rebase conflict, will retry next iteration"
                fi
            fi
        fi
    else
        log "No changes to commit."
    fi

    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
        log "Reached max iterations ($MAX_ITERATIONS). Stopping."
        update_preview_status "stopped"
        break
    fi

    log "Sleeping ${LOOP_DELAY}s before next iteration..."
    sleep "$LOOP_DELAY"
done

log "Codex agent loop finished after $ITERATION iterations."
