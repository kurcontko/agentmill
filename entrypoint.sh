#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
REPO_DIR="/workspace/repo"
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
MODEL="${MODEL:-sonnet}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}" # 0 = infinite
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
LOOP_DELAY="${LOOP_DELAY:-5}" # seconds between iterations
UPSTREAM_PATH="${REPO_PATH:-/upstream}" # path to repo inside /upstream mount

# ── State ──────────────────────────────────────────────────────
ITERATION=0
SHUTTING_DOWN=false

# ── Graceful shutdown ─────────────────────────────────────────
cleanup() {
    echo "[agentmill] Received shutdown signal. Finishing current session..."
    SHUTTING_DOWN=true
}
trap cleanup SIGTERM SIGINT

# ── Logging helper ─────────────────────────────────────────────
mkdir -p "$LOG_DIR"

log() {
    local msg="[agentmill $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent.log"
}

# ── Auth check ─────────────────────────────────────────────────
CLAUDE_HOME="$HOME/.claude"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    log "Auth: using ANTHROPIC_API_KEY"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    log "Auth: using CLAUDE_CODE_OAUTH_TOKEN (subscription)"
else
    log "ERROR: No auth configured."
    log "  Option 1: Set ANTHROPIC_API_KEY env var (API key)"
    log "  Option 2: Set CLAUDE_CODE_OAUTH_TOKEN env var (run 'claude setup-token' on host)"
    exit 1
fi

# ── Git configuration ─────────────────────────────────────────
git config --global user.name "$GIT_USER"
git config --global user.email "$GIT_EMAIL"
git config --global push.autoSetupRemote true

# ── Repo setup ─────────────────────────────────────────────────
setup_repo() {
    if [ -d "$REPO_DIR/.git" ]; then
        log "Repo already cloned at $REPO_DIR"
        return
    fi

    if [ -d "$UPSTREAM_PATH/.git" ]; then
        log "Cloning from mounted volume: $UPSTREAM_PATH"
        git clone "$UPSTREAM_PATH" "$REPO_DIR"
    elif [ -n "${REPO_URL:-}" ]; then
        log "Cloning from REPO_URL: $REPO_URL"
        git clone "$REPO_URL" "$REPO_DIR"
    else
        log "ERROR: No repo source. Mount a repo at /upstream or set REPO_URL."
        exit 1
    fi

    log "Repo ready at $REPO_DIR"
}

# ── Push with retry on conflict ───────────────────────────────
push_changes() {
    local max_retries=3
    local attempt=0

    while [ $attempt -lt $max_retries ]; do
        if git push 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        log "Push failed (attempt $attempt/$max_retries). Rebasing..."
        git pull --rebase || true
    done

    log "WARNING: Push failed after $max_retries attempts. Changes are committed locally."
    return 1
}

# ── Main loop ──────────────────────────────────────────────────
setup_repo
cd "$REPO_DIR"

log "Starting agent loop (model=$MODEL, max_iterations=$MAX_ITERATIONS)"

while true; do
    if [ "$SHUTTING_DOWN" = true ]; then
        log "Shutdown requested. Exiting loop."
        break
    fi

    ITERATION=$((ITERATION + 1))
    SESSION_LOG="$LOG_DIR/session_$(date -u '+%Y%m%d_%H%M%S')_iter${ITERATION}.log"

    log "═══ Iteration $ITERATION ═══"

    # Pull latest changes
    log "Pulling latest changes..."
    git pull --rebase 2>/dev/null || log "Pull failed or nothing to pull (may be a fresh repo)"

    # Check for prompt file
    if [ ! -f "$PROMPT_FILE" ]; then
        log "ERROR: Prompt file not found at $PROMPT_FILE"
        log "Mount your prompt file or set PROMPT_FILE env var."
        exit 1
    fi

    # Run Claude
    log "Running Claude (session log: $SESSION_LOG)..."
    PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

    set +e
    claude --dangerously-skip-permissions \
        -p "$PROMPT_CONTENT" \
        --model "$MODEL" \
        2>&1 | stdbuf -oL tee "$SESSION_LOG"
    CLAUDE_EXIT=$?
    set -e

    log "Claude exited with code $CLAUDE_EXIT"

    # Commit any changes
    if [ -n "$(git status --porcelain)" ]; then
        log "Committing changes..."
        git add -A
        git commit -m "agent: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
        push_changes || true
        log "Changes committed and pushed."
    else
        log "No changes to commit."
    fi

    # Check iteration limit
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
        log "Reached max iterations ($MAX_ITERATIONS). Stopping."
        break
    fi

    # Brief pause before next iteration
    log "Sleeping ${LOOP_DELAY}s before next iteration..."
    sleep "$LOOP_DELAY"
done

log "Agent loop finished after $ITERATION iterations."
