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

. /entrypoint-common.sh

mkdir -p "$LOG_DIR"

log() {
    local msg
    msg="[agentmill $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent.log"
    return 0
}

require_auth
merge_host_claude_config
configure_git_identity "$GIT_USER" "$GIT_EMAIL"

# --- Repo check -----------------------------------------------
if [[ ! -d "$REPO_DIR/.git" ]] && [[ ! -f "$REPO_DIR/.git" ]]; then
    log "ERROR: No repo found at $REPO_DIR. Set REPO_PATH in .env."
    exit 1
fi

cd "$REPO_DIR"
log "Repo ready at $REPO_DIR"

prepare_repo_environment "$REPO_DIR"

# --- Override project settings for autonomous mode ------------
# The host repo may have restrictive .claude/settings.local.json
# Back up original and restore on exit
RALPH_RULE_FILE=".claude/rules/agentmill-ralph-task.md"
backup_project_settings ".claude/settings.local.json"
if [[ "${RESPAWN:-false}" == "true" ]]; then
    # Respawn mode keeps the same autonomous permissions and only adds a Stop
    # hook so the parent loop can restart Claude between sessions.
    SETTINGS_JSON="$(autonomous_settings_json true)"
else
    SETTINGS_JSON="$(autonomous_settings_json)"
fi
write_project_settings "$SETTINGS_JSON"

restore_settings() {
    restore_project_settings
    rm -f "$RALPH_RULE_FILE"
    return 0
}
trap restore_settings EXIT

# --- Build initial prompt -------------------------------------
INITIAL_PROMPT=""
if [[ "${SKIP_PROMPT:-false}" != "true" ]] && [[ -f "$PROMPT_FILE" ]]; then
    INITIAL_PROMPT="$(cat "$PROMPT_FILE")"
    log "Loaded prompt from $PROMPT_FILE"
fi

if [[ "${AUTO_RALPH:-false}" == "true" ]] && [[ -n "$INITIAL_PROMPT" ]]; then
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
    return 0
}
trap 'cleanup; restore_settings' SIGTERM SIGINT

# --- Launch Claude Code TUI -----------------------------------
RESPAWN="${RESPAWN:-false}"
LOOP_DELAY="${LOOP_DELAY:-5}"
ITERATION=0

if [[ -n "$INITIAL_PROMPT" ]]; then
    log "Starting session with prompt from $PROMPT_FILE."
    export CLAUDE_INITIAL_PROMPT="$INITIAL_PROMPT"
else
    unset CLAUDE_INITIAL_PROMPT
fi

while true; do
    ITERATION=$((ITERATION + 1))
    log "Launching Claude TUI (model=$MODEL, iteration=$ITERATION)"

    if [[ "${SKIP_PROMPT:-false}" == "true" ]]; then
        # Manual mode: launch Claude directly, no expect wrapper
        claude --model "$MODEL" || true
    else
        /auto-trust.exp || true
    fi

    # Safety-net: commit any leftover changes
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        log "Committing leftover changes from iteration $ITERATION..."
        git add -A
        git commit -m "[wip] tui session $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" || true
    fi

    if [[ "$RESPAWN" != "true" ]]; then
        log "Respawn disabled. Exiting."
        break
    fi

    if [[ "$SHUTTING_DOWN" == true ]]; then
        log "Shutdown requested. Exiting."
        break
    fi

    log "Claude exited. Restarting in ${LOOP_DELAY}s..."
    sleep "$LOOP_DELAY"
done
