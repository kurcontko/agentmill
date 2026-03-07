#!/usr/bin/env bash
set -euo pipefail

# --- AgentMill TUI Mode ---------------------------------------------------
# Launches Claude Code in interactive TUI mode.
# Use Ralph Loop plugin (/ralph-loop) for autonomous iteration,
# or interact manually - your choice.
#
# Usage: docker compose run dashboard
# --------------------------------------------------------------------------

REPO_DIR="/workspace/repo"
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
ENGINE="${ENGINE:-claude}"
MODEL="${MODEL:-sonnet}"
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"

mkdir -p "$LOG_DIR"

log() {
    local msg="[agentmill $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent.log"
}

# --- Auth -----------------------------------------------------------------
if [ "$ENGINE" = "opencode" ]; then
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
        log "WARNING: No API keys detected for opencode."
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

    /setup-claude-config.sh
fi

# --- Git config -----------------------------------------------------------
git config --global user.name "$GIT_USER"
git config --global user.email "$GIT_EMAIL"

# --- Repo check -----------------------------------------------------------
if [ ! -d "$REPO_DIR/.git" ]; then
    log "ERROR: No repo found at $REPO_DIR. Set REPO_PATH in .env."
    exit 1
fi

cd "$REPO_DIR"
log "Repo ready at $REPO_DIR"

# --- Override project settings for autonomous mode ------------------------
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
    # The host repo may have restrictive .claude/settings.local.json
    # Back up original and restore on exit
    SETTINGS_LOCAL=".claude/settings.local.json"
    SETTINGS_BACKUP=""
    mkdir -p .claude
    if [ -f "$SETTINGS_LOCAL" ]; then
        SETTINGS_BACKUP="$(cat "$SETTINGS_LOCAL")"
    fi
    echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit","mcp__*"],"defaultMode":"bypass"}}' > "$SETTINGS_LOCAL"

    restore_settings() {
        if [ -n "$SETTINGS_BACKUP" ]; then
            echo "$SETTINGS_BACKUP" > "$SETTINGS_LOCAL"
        else
            rm -f "$SETTINGS_LOCAL"
        fi
    }
    trap restore_settings EXIT
fi

# --- Build initial prompt -------------------------------------------------
INITIAL_PROMPT=""
if [ -f "$PROMPT_FILE" ]; then
    INITIAL_PROMPT="$(cat "$PROMPT_FILE")"
    log "Loaded prompt from $PROMPT_FILE"
fi

# --- Launch TUI -----------------------------------------------------------
if [ "$ENGINE" = "opencode" ]; then
    log "Launching OpenCode TUI (model=$MODEL)"
    if [ -n "$INITIAL_PROMPT" ]; then
        exec opencode --model "$MODEL" --prompt "$INITIAL_PROMPT"
    else
        exec opencode --model "$MODEL"
    fi
else
    if [ "${AUTO_RALPH:-false}" = "true" ] && [ -n "$INITIAL_PROMPT" ]; then
        INITIAL_PROMPT="/ralph-loop:ralph-loop ${INITIAL_PROMPT}"
        log "Ralph Loop enabled - will auto-start"
    fi

    # auto-trust.exp handles the trust dialog automatically, then hands
    # full control to your terminal via `interact`.
    # Prompt is passed via env var to avoid expect/Tcl escaping issues.
    log "Launching Claude TUI (model=$MODEL)"
    export CLAUDE_INITIAL_PROMPT="$INITIAL_PROMPT"
    exec /auto-trust.exp
fi