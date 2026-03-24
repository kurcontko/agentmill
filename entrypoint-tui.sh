#!/usr/bin/env bash
set -euo pipefail

# --- AgentMill TUI Mode ---------------------------------------
# Launches Claude Code or OpenCode in interactive TUI mode.
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
AGENT_CLI="${AGENT_CLI:-claude}"
AUTO_RALPH_MAX_ITERATIONS="${AUTO_RALPH_MAX_ITERATIONS:-${MAX_ITERATIONS:-10}}"
AUTO_RALPH_COMPLETION_PROMISE="${AUTO_RALPH_COMPLETION_PROMISE:-TASK_COMPLETE}"

mkdir -p "$LOG_DIR"

log() {
    local msg="[agentmill $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent.log"
}

# --- Source CLI wrapper ----------------------------------------
. /agent-run.sh

# --- Auth -----------------------------------------------------
if [ "$AGENT_CLI" = "claude" ]; then
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
elif [ "$AGENT_CLI" = "opencode" ]; then
    if [ -n "${LOCAL_ENDPOINT:-}" ]; then
        log "Auth: using LOCAL_ENDPOINT ($LOCAL_ENDPOINT)"
    elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        log "Auth: using ANTHROPIC_API_KEY (via opencode)"
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
        log "Auth: using OPENAI_API_KEY (via opencode)"
    else
        log "ERROR: No auth configured for opencode."
        exit 1
    fi
fi

# --- Merge host config (CLI-specific) -------------------------
if [ "$AGENT_CLI" = "claude" ]; then
    /setup-claude-config.sh
else
    log "Using AGENT_CLI=$AGENT_CLI"
fi

# --- Git config -----------------------------------------------
git config --global user.name "$GIT_USER"
git config --global user.email "$GIT_EMAIL"

# --- Repo check -----------------------------------------------
if [ ! -d "$REPO_DIR/.git" ] && [ ! -f "$REPO_DIR/.git" ]; then
    log "ERROR: No repo found at $REPO_DIR. Set REPO_PATH in .env."
    exit 1
fi

cd "$REPO_DIR"
log "Repo ready at $REPO_DIR"

log "Preparing repo environment..."
. /setup-repo-env.sh "$REPO_DIR"
log "Repo environment ready."

# --- Override project settings for autonomous mode ------------
RALPH_RULE_FILE=".claude/rules/agentmill-ralph-task.md"

if [ "$AGENT_CLI" = "claude" ]; then
    SETTINGS_LOCAL=".claude/settings.local.json"
    SETTINGS_BACKUP=""
    mkdir -p .claude
    if [ -f "$SETTINGS_LOCAL" ]; then
        SETTINGS_BACKUP="$(cat "$SETTINGS_LOCAL")"
    fi
    SETTINGS_JSON='{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit"],"defaultMode":"bypassPermissions"}}'
    if [ "${RESPAWN:-false}" = "true" ]; then
        SETTINGS_JSON='{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit"],"defaultMode":"bypassPermissions"},"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"kill -TERM $PPID 2>/dev/null; exit 0"}]}]}}'
    fi
    echo "$SETTINGS_JSON" > "$SETTINGS_LOCAL"

    restore_settings() {
        if [ -n "$SETTINGS_BACKUP" ]; then
            echo "$SETTINGS_BACKUP" > "$SETTINGS_LOCAL"
        else
            rm -f "$SETTINGS_LOCAL"
        fi
        rm -f "$RALPH_RULE_FILE"
    }
    trap restore_settings EXIT
elif [ "$AGENT_CLI" = "opencode" ]; then
    /setup-opencode-config.sh "$(pwd)"
    restore_settings() {
        rm -f "$RALPH_RULE_FILE"
    }
    trap restore_settings EXIT
fi

# --- Build initial prompt -------------------------------------
INITIAL_PROMPT=""
if [ "${SKIP_PROMPT:-false}" != "true" ] && [ -f "$PROMPT_FILE" ]; then
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

# --- Graceful shutdown -----------------------------------------
SHUTTING_DOWN=false
cleanup() {
    log "Received shutdown signal. Finishing current session..."
    SHUTTING_DOWN=true
}
trap 'cleanup; restore_settings' SIGTERM SIGINT

# --- Launch TUI ------------------------------------------------
RESPAWN="${RESPAWN:-false}"
LOOP_DELAY="${LOOP_DELAY:-5}"
ITERATION=0

while true; do
    ITERATION=$((ITERATION + 1))
    log "Launching TUI (cli=$AGENT_CLI, model=$MODEL, iteration=$ITERATION)"

    if [ "${SKIP_PROMPT:-false}" = "true" ]; then
        # Manual mode: launch TUI directly, no initial prompt
        agent_run_tui "$MODEL" || true
    else
        if [ "$AGENT_CLI" = "claude" ]; then
            export CLAUDE_INITIAL_PROMPT="${INITIAL_PROMPT:-}"
            /auto-trust.exp || true
        else
            agent_run_tui "$MODEL" "${INITIAL_PROMPT:-}" || true
        fi
    fi

    # Safety-net: commit any leftover changes
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        log "Committing leftover changes from iteration $ITERATION..."
        git add -A
        git commit -m "[wip] tui session $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" || true
    fi

    if [ "$RESPAWN" != "true" ]; then
        log "Respawn disabled. Exiting."
        break
    fi

    if [ "$SHUTTING_DOWN" = true ]; then
        log "Shutdown requested. Exiting."
        break
    fi

    log "Session exited. Restarting in ${LOOP_DELAY}s..."
    sleep "$LOOP_DELAY"
done
