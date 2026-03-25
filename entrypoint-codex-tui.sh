#!/usr/bin/env bash
set -euo pipefail

# --- AgentMill Codex TUI Mode --------------------------------
# Launches Codex in interactive TUI mode.
# For respawning loop: set RESPAWN=true — uses Codex's hooks.json
# Stop event to touch a sentinel file, then commits and restarts.
#
# Usage: docker compose run codex-tui
# ---------------------------------------------------------------

REPO_DIR="/workspace/repo"
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_APPROVAL="${CODEX_APPROVAL:-on-request}"  # untrusted | on-request | never
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
DONE_FILE="${DONE_FILE:-/tmp/.agentmill-done}"

. /entrypoint-common.sh

mkdir -p "$LOG_DIR"

log() {
    local msg="[agentmill-codex-tui $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/codex-tui.log"
}

require_codex_auth
configure_git_identity "$GIT_USER" "$GIT_EMAIL"

# --- Repo check -----------------------------------------------
if [[ ! -d "$REPO_DIR/.git" ]] && [[ ! -f "$REPO_DIR/.git" ]]; then
    log "ERROR: No repo found at $REPO_DIR. Set REPO_PATH in .env."
    exit 1
fi

cd "$REPO_DIR"
log "Repo ready at $REPO_DIR"

prepare_repo_environment "$REPO_DIR"

# --- Install Codex Stop hook via hooks.json --------------------
# Codex supports hooks.json with Stop event — same pattern as
# Claude Code's Stop hook. Touches a sentinel file on completion.
CODEX_HOOKS_DIR="$HOME/.codex"
CODEX_HOOKS_FILE="$CODEX_HOOKS_DIR/hooks.json"
CODEX_HOOKS_BACKUP=""

install_codex_hooks() {
    mkdir -p "$CODEX_HOOKS_DIR"
    if [[ -f "$CODEX_HOOKS_FILE" ]]; then
        CODEX_HOOKS_BACKUP="$(mktemp)"
        cp "$CODEX_HOOKS_FILE" "$CODEX_HOOKS_BACKUP"
    fi

    cat > "$CODEX_HOOKS_FILE" << HOOKJSON
[
  {
    "event": "Stop",
    "hooks": [
      {
        "type": "command",
        "command": "touch ${DONE_FILE}"
      }
    ]
  }
]
HOOKJSON
    log "Installed Codex Stop hook -> $DONE_FILE"
}

restore_codex_hooks() {
    if [[ -n "${CODEX_HOOKS_BACKUP:-}" ]] && [[ -f "$CODEX_HOOKS_BACKUP" ]]; then
        cp "$CODEX_HOOKS_BACKUP" "$CODEX_HOOKS_FILE"
        rm -f "$CODEX_HOOKS_BACKUP"
    else
        rm -f "$CODEX_HOOKS_FILE"
    fi
}

# --- Build codex TUI args --------------------------------------
build_codex_args() {
    local args=(-C "$REPO_DIR")

    case "$CODEX_APPROVAL" in
        untrusted|on-request|never)
            args+=(-a "$CODEX_APPROVAL")
            ;;
        full-auto)
            args+=(--full-auto)
            ;;
        *)
            log "ERROR: Unsupported CODEX_APPROVAL=$CODEX_APPROVAL (valid: untrusted, on-request, never, full-auto)"
            exit 1
            ;;
    esac

    if [[ -n "$CODEX_MODEL" ]]; then
        args+=(-m "$CODEX_MODEL")
    fi

    printf '%s\n' "${args[@]}"
}

# --- Graceful shutdown -----------------------------------------
SHUTTING_DOWN=false
cleanup() {
    log "Received shutdown signal. Finishing current session..."
    SHUTTING_DOWN=true
}
trap cleanup SIGTERM SIGINT

# --- Launch ----------------------------------------------------
RESPAWN="${RESPAWN:-false}"
LOOP_DELAY="${LOOP_DELAY:-5}"
ITERATION=0

# Load prompt
INITIAL_PROMPT=""
if [[ "${SKIP_PROMPT:-false}" != "true" ]] && [[ -f "$PROMPT_FILE" ]]; then
    INITIAL_PROMPT="$(cat "$PROMPT_FILE")"
    log "Loaded prompt from $PROMPT_FILE"
fi

# Read codex args into array
mapfile -t CODEX_ARGS < <(build_codex_args)

# Install hooks for respawn mode; restore on exit
if [[ "$RESPAWN" == "true" ]]; then
    install_codex_hooks
    trap 'restore_codex_hooks' EXIT
fi

while true; do
    ITERATION=$((ITERATION + 1))
    log "Launching Codex TUI (approval=$CODEX_APPROVAL, iteration=$ITERATION)"

    # Clean sentinel before each iteration
    rm -f "$DONE_FILE"

    if [[ "$RESPAWN" == "true" ]] && [[ -n "$INITIAL_PROMPT" ]]; then
        # Respawn mode: run codex, watch for sentinel from Stop hook
        codex "${CODEX_ARGS[@]}" "$INITIAL_PROMPT" &
        CODEX_PID=$!

        # Wait for either: codex exits naturally, or sentinel file appears
        while kill -0 "$CODEX_PID" 2>/dev/null; do
            if [[ -f "$DONE_FILE" ]]; then
                log "Stop hook fired ($DONE_FILE). Codex completed."
                sleep 2
                kill "$CODEX_PID" 2>/dev/null || true
                wait "$CODEX_PID" 2>/dev/null || true
                break
            fi
            sleep 1
        done
        wait "$CODEX_PID" 2>/dev/null || true
    elif [[ -n "$INITIAL_PROMPT" ]]; then
        # Single-shot with prompt
        codex "${CODEX_ARGS[@]}" "$INITIAL_PROMPT" || true
    else
        # Manual mode: no prompt
        codex "${CODEX_ARGS[@]}" || true
    fi

    # Safety-net: commit any leftover changes
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        log "Committing leftover changes from iteration $ITERATION..."
        git add -A
        git commit -m "[wip] codex-tui session $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" || true
    fi

    if [[ "$RESPAWN" != "true" ]]; then
        log "Respawn disabled. Exiting."
        break
    fi

    if [[ "$SHUTTING_DOWN" == true ]]; then
        log "Shutdown requested. Exiting."
        break
    fi

    rm -f "$DONE_FILE"
    log "Codex exited. Restarting in ${LOOP_DELAY}s..."
    sleep "$LOOP_DELAY"
done
