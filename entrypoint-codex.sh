#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Codex agent entrypoint — runs codex in a loop with git sync
# ---------------------------------------------------------------------------

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

trap 'echo "[codex] Shutdown signal received"; SHUTTING_DOWN=true' SIGTERM SIGINT

mkdir -p "$LOG_DIR"

log() { echo "[codex:agent-${AGENT_ID} $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_DIR/codex-agent-${AGENT_ID}.log"; }

# -- Auth check --
if [ -n "${OPENAI_API_KEY:-}" ]; then
    log "Auth: OPENAI_API_KEY"
elif [ -d "$HOME/.codex" ]; then
    log "Auth: ~/.codex"
else
    log "ERROR: No Codex auth. Set OPENAI_API_KEY or mount ~/.codex"
    exit 1
fi

git config --global user.name "${GIT_USER}-${AGENT_ID}"
git config --global user.email "$GIT_EMAIL"

# -- Repo setup --
UPSTREAM_DIR="/workspace/upstream"
REPO_DIR="/workspace/repo"
MULTI_AGENT=false

if [ -d "$UPSTREAM_DIR/.git" ] || [ -f "$UPSTREAM_DIR/HEAD" ]; then
    REPO_DIR="/workspace/repo-${AGENT_ID}"
    : "${AGENT_BRANCH:=codex-agent-${AGENT_ID}}"
    MULTI_AGENT=true
    log "Multi-agent mode: branch ${AGENT_BRANCH}"

    git -C "$UPSTREAM_DIR" config receive.denyCurrentBranch updateInstead 2>/dev/null || true

    if [ ! -d "$REPO_DIR/.git" ]; then
        git clone "$UPSTREAM_DIR" "$REPO_DIR"
    else
        git -C "$REPO_DIR" fetch origin
    fi
    cd "$REPO_DIR"

    UPSTREAM_HEAD="$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
    if git show-ref --verify --quiet "refs/heads/$AGENT_BRANCH"; then
        git checkout "$AGENT_BRANCH"
        git rebase "$UPSTREAM_HEAD" 2>/dev/null || git rebase --abort
    else
        git checkout -b "$AGENT_BRANCH" "$UPSTREAM_HEAD"
    fi
    log "Repo ready at $REPO_DIR (branch: $(git branch --show-current))"
elif [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR"
    log "Repo ready at $REPO_DIR (direct mount)"
else
    log "ERROR: No repo found. Mount to /workspace/repo or /workspace/upstream"
    exit 1
fi

log "Setting up repo environment..."
. /setup-repo-env.sh "$REPO_DIR"
log "Environment ready"

# -- Main loop --
log "Starting loop (max_iterations=$MAX_ITERATIONS${CODEX_MODEL:+ model=$CODEX_MODEL})"

while true; do
    [ "$SHUTTING_DOWN" = true ] && { log "Shutdown. Exiting."; break; }

    ITERATION=$((ITERATION + 1))
    log "==== Iteration $ITERATION ===="

    [ ! -f "$PROMPT_FILE" ] && { log "ERROR: Prompt not found: $PROMPT_FILE"; exit 1; }

    # Build supervisor args
    supervisor_args=(
        /codex_preview_supervisor.py
        --repo-dir "$REPO_DIR"
        --prompt-file "$PROMPT_FILE"
        --log-dir "$LOG_DIR"
        --agent-id "$AGENT_ID"
        --iteration "$ITERATION"
        --max-iterations "$MAX_ITERATIONS"
    )
    [ -n "$CODEX_MODEL" ] && supervisor_args+=(--model "$CODEX_MODEL")
    [ -n "$PREVIEW_APP_URL" ] && supervisor_args+=(--preview-app-url "$PREVIEW_APP_URL")

    log "Running supervisor..."
    set +e
    python3 "${supervisor_args[@]}"
    CODEX_EXIT=$?
    set -e
    log "Codex exited: $CODEX_EXIT"

    # Commit & push
    if [ -n "$(git status --porcelain)" ]; then
        log "Committing..."
        git add -A
        git commit -m "codex-agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"

        if [ "$MULTI_AGENT" = true ]; then
            log "Pushing to upstream..."
            if ! git push origin "$AGENT_BRANCH" 2>/dev/null; then
                log "Push failed, rebasing..."
                git fetch origin
                if git rebase "origin/$AGENT_BRANCH" 2>/dev/null; then
                    git push origin "$AGENT_BRANCH" || log "WARN: Push failed, retry next iteration"
                else
                    git rebase --abort
                    log "WARN: Rebase conflict, retry next iteration"
                fi
            fi
        fi
    else
        log "No changes."
    fi

    # Check iteration limit
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
        log "Max iterations ($MAX_ITERATIONS) reached."
        STATUS_FILE="$LOG_DIR/codex-preview/agent-${AGENT_ID}/status.json"
        if [ -f "$STATUS_FILE" ] && command -v jq >/dev/null 2>&1; then
            tmp=$(mktemp)
            jq --arg s "stopped" --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
                '.state=$s | .updated_at=$t' "$STATUS_FILE" > "$tmp" && mv "$tmp" "$STATUS_FILE"
        fi
        break
    fi

    log "Sleeping ${LOOP_DELAY}s..."
    sleep "$LOOP_DELAY"
done

log "Finished after $ITERATION iterations."
