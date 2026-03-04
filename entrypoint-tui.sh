#!/usr/bin/env bash
set -euo pipefail

# ── AgentMill TUI Mode ───────────────────────────────────────────────
# Runs Claude Code in interactive TUI mode (not pipe mode).
# The full Claude Code terminal UI is forwarded to your terminal.
# --dangerously-skip-permissions makes it autonomous: you watch, it works.
#
# Usage: docker compose run dashboard
# ─────────────────────────────────────────────────────────────────────

REPO_DIR="/workspace/repo"
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
MODEL="${MODEL:-sonnet}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
LOOP_DELAY="${LOOP_DELAY:-5}"

ITERATION=0
SHUTTING_DOWN=false

cleanup() {
    echo "[agentmill] Shutdown signal received."
    SHUTTING_DOWN=true
}
trap cleanup SIGTERM SIGINT

mkdir -p "$LOG_DIR"

log() {
    local msg="[agentmill $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent.log"
}

# ── Auth ──────────────────────────────────────────────────────────────
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    log "Auth: using ANTHROPIC_API_KEY"
elif [ -d "/root/.claude" ] && [ "$(ls -A /root/.claude 2>/dev/null)" ]; then
    log "Auth: using mounted ~/.claude (subscription login)"
else
    log "ERROR: No auth configured."
    log "  Set ANTHROPIC_API_KEY or mount ~/.claude"
    exit 1
fi

# ── Git config ────────────────────────────────────────────────────────
git config --global user.name "$GIT_USER"
git config --global user.email "$GIT_EMAIL"
git config --global push.autoSetupRemote true

# ── Repo setup ────────────────────────────────────────────────────────
if [ ! -d "$REPO_DIR/.git" ]; then
    if [ -d "/upstream/.git" ]; then
        log "Cloning from mounted /upstream..."
        git clone /upstream "$REPO_DIR"
    elif [ -n "${REPO_URL:-}" ]; then
        log "Cloning from REPO_URL: $REPO_URL"
        git clone "$REPO_URL" "$REPO_DIR"
    else
        log "ERROR: No repo source. Mount /upstream or set REPO_URL."
        exit 1
    fi
fi

cd "$REPO_DIR"
log "Repo ready at $REPO_DIR"

# ── Main loop ─────────────────────────────────────────────────────────
log "Starting TUI mode (model=$MODEL, max_iterations=${MAX_ITERATIONS:-∞})"

while true; do
    [ "$SHUTTING_DOWN" = true ] && break

    ITERATION=$((ITERATION + 1))
    log "═══ Iteration $ITERATION (TUI) ═══"

    # Sync
    git pull --rebase 2>/dev/null || true

    # Read prompt
    if [ ! -f "$PROMPT_FILE" ]; then
        log "ERROR: Prompt file not found at $PROMPT_FILE"
        exit 1
    fi
    PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

    # Launch Claude Code in interactive TUI mode.
    # The prompt is passed as a positional argument = first message.
    # --dangerously-skip-permissions = all tool calls auto-approved.
    # The TUI renders in your terminal — you see everything Claude does.
    set +e
    claude --dangerously-skip-permissions \
        --model "$MODEL" \
        "$PROMPT_CONTENT"
    CLAUDE_EXIT=$?
    set -e

    log "Claude session exited ($CLAUDE_EXIT)"

    # Commit and push any changes
    if [ -n "$(git status --porcelain)" ]; then
        log "Changes detected. Committing..."
        git add -A
        git commit -m "agent: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"

        # Push with retry
        git push 2>/dev/null || {
            git pull --rebase 2>/dev/null || true
            git push 2>/dev/null || {
                git pull --rebase 2>/dev/null || true
                git push 2>/dev/null || log "WARNING: Push failed after retries."
            }
        }
        log "Changes committed and pushed."
    else
        log "No changes to commit."
    fi

    # Iteration limit
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
        log "Reached max iterations ($MAX_ITERATIONS). Stopping."
        break
    fi

    [ "$SHUTTING_DOWN" = true ] && break

    log "Next iteration in ${LOOP_DELAY}s..."
    sleep "$LOOP_DELAY"
done

log "Agent finished after $ITERATION iterations."
