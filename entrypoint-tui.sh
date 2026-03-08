#!/usr/bin/env bash
set -euo pipefail

# --- AgentMill TUI Mode ---------------------------------------
# Launches Claude Code in interactive TUI mode.
# Use Ralph Loop plugin (/ralph-loop) for autonomous iteration,
# or interact manually - your choice.
#
# Usage: docker compose run dashboard
# --------------------------------------------------------------

REPO_DIR="/workspace/repo"
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
MODEL="${MODEL:-sonnet}"
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
AUTO_RALPH_MAX_ITERATIONS="${AUTO_RALPH_MAX_ITERATIONS:-${MAX_ITERATIONS:-10}}"
AUTO_RALPH_COMPLETION_PROMISE="${AUTO_RALPH_COMPLETION_PROMISE:-TASK_COMPLETE}"

mkdir -p "$LOG_DIR"

log() {
    local msg="[agentmill $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent.log"
}

# --- Auth -----------------------------------------------------
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

# --- Merge host Claude config (MCP, plugins, settings) --------
/setup-claude-config.sh

# --- Git config -----------------------------------------------
git config --global user.name "$GIT_USER"
git config --global user.email "$GIT_EMAIL"

# --- Repo check -----------------------------------------------
if [ ! -d "$REPO_DIR/.git" ]; then
    log "ERROR: No repo found at $REPO_DIR. Set REPO_PATH in .env."
    exit 1
fi

cd "$REPO_DIR"
log "Repo ready at $REPO_DIR"

log "Preparing repo environment..."
. /setup-repo-env.sh "$REPO_DIR"
log "Repo environment ready."

# --- Override project settings for autonomous mode ------------
# The host repo may have restrictive .claude/settings.local.json
# Back up original and restore on exit
SETTINGS_LOCAL=".claude/settings.local.json"
SETTINGS_BACKUP=""
RALPH_RULE_FILE=".claude/rules/agentmill-ralph-task.md"
mkdir -p .claude
if [ -f "$SETTINGS_LOCAL" ]; then
    SETTINGS_BACKUP="$(cat "$SETTINGS_LOCAL")"
fi
echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit"],"defaultMode":"bypassPermissions"}}' > "$SETTINGS_LOCAL"

restore_settings() {
    if [ -n "$SETTINGS_BACKUP" ]; then
        echo "$SETTINGS_BACKUP" > "$SETTINGS_LOCAL"
    else
        rm -f "$SETTINGS_LOCAL"
    fi
    rm -f "$RALPH_RULE_FILE"
}
trap restore_settings EXIT

# --- Build initial prompt -------------------------------------
INITIAL_PROMPT=""
if [ -f "$PROMPT_FILE" ]; then
    INITIAL_PROMPT="$(cat "$PROMPT_FILE")"
    log "Loaded prompt from $PROMPT_FILE"
fi

if [ "${AUTO_RALPH:-false}" = "true" ] && [ -n "$INITIAL_PROMPT" ]; then
    mkdir -p "$(dirname "$RALPH_RULE_FILE")"
    cat > "$RALPH_RULE_FILE" <<EOF
# AgentMill Ralph Task

This file is generated at container startup from \`$PROMPT_FILE\`.
Treat it as the authoritative Ralph loop task for this session.

When the task is genuinely complete, output this exact tag on its own line:
<promise>$AUTO_RALPH_COMPLETION_PROMISE</promise>

$INITIAL_PROMPT
EOF
    INITIAL_PROMPT="/ralph-loop:ralph-loop Read .claude/rules/agentmill-ralph-task.md and execute that task exactly. Use the completion criteria defined there. --max-iterations $AUTO_RALPH_MAX_ITERATIONS --completion-promise $AUTO_RALPH_COMPLETION_PROMISE"
    log "Ralph Loop enabled - using $RALPH_RULE_FILE for task context"
    log "Ralph Loop limits: max_iterations=$AUTO_RALPH_MAX_ITERATIONS completion_promise=$AUTO_RALPH_COMPLETION_PROMISE"
fi

# --- Launch Claude Code TUI -----------------------------------
log "Launching Claude TUI (model=$MODEL)"
if [ -n "$INITIAL_PROMPT" ]; then
    log "Starting interactive session with prompt from $PROMPT_FILE."
    export CLAUDE_INITIAL_PROMPT="$INITIAL_PROMPT"
else
    unset CLAUDE_INITIAL_PROMPT
fi
exec /auto-trust.exp
