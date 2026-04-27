#!/usr/bin/env bash
set -euo pipefail

# AgentMill TUI Mode — interactive or autonomous (Ralph Loop)
REPO_DIR="/workspace/repo"
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
MODEL="${MODEL:-sonnet}"
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
DONE_FILE="${DONE_FILE:-/tmp/.agentmill-done}"
SENTINEL_SIGNAL_FLAG_FILE="${SENTINEL_SIGNAL_FLAG_FILE:-/tmp/.agentmill-sentinel-signal}"
AUTO_RALPH_MAX_ITERATIONS="${AUTO_RALPH_MAX_ITERATIONS:-${MAX_ITERATIONS:-10}}"
AUTO_RALPH_COMPLETION_PROMISE="${AUTO_RALPH_COMPLETION_PROMISE:-TASK_COMPLETE}"

# shellcheck source=/entrypoint-common.sh
. /entrypoint-common.sh

# Resolve friendly aliases (opus / sonnet / haiku / opus-4.7 / etc.) to full
# Claude model IDs — see resolve_model() in entrypoint-common.sh for rationale.
MODEL_RAW="$MODEL"
MODEL="$(resolve_model "$MODEL_RAW")"
[[ "$MODEL" != "$MODEL_RAW" ]] && log "Resolved MODEL '$MODEL_RAW' -> '$MODEL'"

# log() provided by entrypoint-common.sh

require_auth
merge_host_claude_config
configure_git_identity "$GIT_USER" "$GIT_EMAIL"
memory_init

[[ -d "$REPO_DIR/.git" ]] || [[ -f "$REPO_DIR/.git" ]] || { log "ERROR: No repo at $REPO_DIR"; exit 1; }

cd "$REPO_DIR"
log "Repo ready at $REPO_DIR"

prepare_repo_environment "$REPO_DIR"

RALPH_RULE_FILE=".claude/rules/agentmill-ralph-task.md"
backup_project_settings ".claude/settings.local.json"
write_project_settings "$(autonomous_settings_json)"

restore_settings() { restore_project_settings; rm -f "$RALPH_RULE_FILE"; }
trap restore_settings EXIT

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
    log "Ralph Loop: $RALPH_RULE_FILE (max=$AUTO_RALPH_MAX_ITERATIONS, promise=$AUTO_RALPH_COMPLETION_PROMISE)"
fi

SHUTTING_DOWN=false
cleanup() { log "Received shutdown signal."; SHUTTING_DOWN=true; }

handle_signal() {
    if [[ -f "$SENTINEL_SIGNAL_FLAG_FILE" ]]; then
        rm -f "$SENTINEL_SIGNAL_FLAG_FILE"; log "Sentinel restart."; return 0
    fi
    cleanup; restore_settings
}
trap handle_signal SIGTERM SIGINT

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

    rm -f "$DONE_FILE" "$SENTINEL_SIGNAL_FLAG_FILE"
    start_sentinel_watcher "$$" process_group

    if [[ "${SKIP_PROMPT:-false}" == "true" ]]; then
        claude --model "$MODEL" || true
    else
        /auto-trust.exp || true
    fi

    stop_sentinel_watcher

    if [[ -f "$DONE_FILE" ]]; then log "Agent signaled done"; else log "WARN: Agent exited without signaling done"; fi

    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        git add -A; git commit -m "[wip] tui session $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" || true
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
