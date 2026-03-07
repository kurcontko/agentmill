#!/usr/bin/env bash
set -euo pipefail

# --- Configuration -------------------------
REPO_DIR="/workspace/repo"
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
ENGINE="${ENGINE:-claude}"
MODEL="${MODEL:-sonnet}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}" # 0 = infinite
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
LOOP_DELAY="${LOOP_DELAY:-5}" # seconds between iterations

# --- State ---------------------------------
ITERATION=0
SHUTTING_DOWN=false

# --- Graceful shutdown ---------------------
cleanup() {
    echo "[agentmill] Received shutdown signal. Finishing current session..."
    SHUTTING_DOWN=true
}
trap cleanup SIGTERM SIGINT

# --- Logging helper ------------------------
mkdir -p "$LOG_DIR"

log() {
    local msg="[agentmill $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent.log"
}

# --- Auth check ----------------------------
if [ "$ENGINE" = "opencode" ]; then
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
        log "WARNING: No API keys detected for opencode."
        log "  Set ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, or configure via opencode.json"
    else
        log "Auth: using API key(s) for opencode engine"
    fi
else
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        log "Auth: using ANTHROPIC_API_KEY"
    elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        log "Auth: using CLAUDE_CODE_OAUTH_TOKEN (subscription)"
        if [ ! -f "$HOME/.claude.json" ]; then
            echo '{"hasCompletedOnboarding":true}' > "$HOME/.claude.json"
        fi
    else
        log "ERROR: No auth configured."
        log "  Option 1: Set ANTHROPIC_API_KEY env var (API credits)"
        log "  Option 2: Set CLAUDE_CODE_OAUTH_TOKEN env var (subscription, from 'claude setup-token')"
        exit 1
    fi

    # --- Merge host Claude config (MCP, plugins, settings) ---
    /setup-claude-config.sh
fi

# --- Git configuration ---------------------
git config --global user.name "$GIT_USER"
git config --global user.email "$GIT_EMAIL"

# --- Repo check ----------------------------
if [ ! -d "$REPO_DIR/.git" ]; then
    log "ERROR: No repo found at $REPO_DIR. Set REPO_PATH in .env."
    exit 1
fi

cd "$REPO_DIR"
log "Repo ready at $REPO_DIR"

# --- Override project settings for autonomous mode ---
if [ "$ENGINE" = "opencode" ]; then
    OPENCODE_CONFIG="opencode.json"
    OPENCODE_BACKUP=""
    if [ -f "$OPENCODE_CONFIG" ]; then
        OPENCODE_BACKUP="$(cat "$OPENCODE_CONFIG")"
    fi
    cat > "$OPENCODE_CONFIG" <<'OCEOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "edit": "allow",
    "bash": "allow",
    "webfetch": "allow"
  }
}
OCEOF

    restore_settings() {
        if [ -n "$OPENCODE_BACKUP" ]; then
            echo "$OPENCODE_BACKUP" > "$OPENCODE_CONFIG"
        else
            rm -f "$OPENCODE_CONFIG"
        fi
    }
    trap restore_settings EXIT
else
    SETTINGS_LOCAL=".claude/settings.local.json"
    SETTINGS_BACKUP=""
    mkdir -p .claude
    if [ -f "$SETTINGS_LOCAL" ]; then
        SETTINGS_BACKUP="$(cat "$SETTINGS_LOCAL")"
    fi
    echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit","mcp__*"],"defaultMode":"bypassPermissions"}}' > "$SETTINGS_LOCAL"

    restore_settings() {
        if [ -n "$SETTINGS_BACKUP" ]; then
            echo "$SETTINGS_BACKUP" > "$SETTINGS_LOCAL"
        else
            rm -f "$SETTINGS_LOCAL"
        fi
    }
    trap 'restore_settings' EXIT
fi

# --- Main loop -----------------------------
log "Starting agent loop (engine=$ENGINE, model=$MODEL, max_iterations=$MAX_ITERATIONS)"

while true; do
    if [ "$SHUTTING_DOWN" = true ]; then
        log "Shutdown requested. Exiting loop."
        break
    fi

    ITERATION=$((ITERATION + 1))
    SESSION_LOG="$LOG_DIR/session_$(date -u '+%Y%m%d_%H%M%S')_iter${ITERATION}.log"

    log "=== Iteration $ITERATION ==="

    # Check for prompt file
    if [ ! -f "$PROMPT_FILE" ]; then
        log "ERROR: Prompt file not found at $PROMPT_FILE"
        log "Mount your prompt file or set PROMPT_FILE env var."
        exit 1
    fi

    # Run agent
    PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

    set +e
    if [ "$ENGINE" = "opencode" ]; then
        log "Running OpenCode (session log: $SESSION_LOG)..."
        opencode run "$PROMPT_CONTENT" \
            --model "$MODEL" \
            2>&1 | tee "$SESSION_LOG"
    else
        log "Running Claude (session log: $SESSION_LOG)..."
        claude --dangerously-skip-permissions \
            -p "$PROMPT_CONTENT" \
            --model "$MODEL" \
            2>&1 | tee "$SESSION_LOG"
    fi
    AGENT_EXIT=$?
    set -e

    log "Agent exited with code $AGENT_EXIT"

    # Commit any changes (directly to the mounted host repo)
    if [ -n "$(git status --porcelain)" ]; then
        log "Committing changes..."
        git add -A
        git commit -m "agent: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
        log "Changes committed."
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