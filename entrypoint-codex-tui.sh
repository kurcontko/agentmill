#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/workspace/repo"
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_APPROVAL_MODE="${CODEX_APPROVAL_MODE:-suggest}"
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"

mkdir -p "$LOG_DIR"

log() {
    local msg="[agentmill-codex $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/codex-dashboard.log"
}

if [ -n "${OPENAI_API_KEY:-}" ]; then
    log "Auth: using OPENAI_API_KEY"
elif [ -d "$HOME/.codex" ]; then
    log "Auth: using mounted ~/.codex state"
else
    log "ERROR: No Codex auth configured."
    log "  Option 1: Set OPENAI_API_KEY env var"
    log "  Option 2: Mount ~/.codex from a host that already ran 'codex --login'"
    exit 1
fi

git config --global user.name "$GIT_USER"
git config --global user.email "$GIT_EMAIL"

if [ ! -d "$REPO_DIR/.git" ]; then
    log "ERROR: No repo found at $REPO_DIR. Set REPO_PATH in .env."
    exit 1
fi

cd "$REPO_DIR"
log "Repo ready at $REPO_DIR"

log "Preparing repo environment..."
. /setup-repo-env.sh "$REPO_DIR"
log "Repo environment ready."

if [ -f "$PROMPT_FILE" ]; then
    INITIAL_PROMPT="$(cat "$PROMPT_FILE")"
    log "Loaded prompt from $PROMPT_FILE"
fi

codex_args=()

case "$CODEX_APPROVAL_MODE" in
    suggest)
        codex_args+=(--suggest)
        ;;
    auto-edit)
        codex_args+=(--auto-edit)
        ;;
    full-auto)
        codex_args+=(--full-auto)
        ;;
    *)
        log "ERROR: Unsupported CODEX_APPROVAL_MODE=$CODEX_APPROVAL_MODE"
        log "  Valid values: suggest, auto-edit, full-auto"
        exit 1
        ;;
esac

if [ -n "$CODEX_MODEL" ]; then
    codex_args+=(-m "$CODEX_MODEL")
fi

log "Launching Codex TUI (approval_mode=$CODEX_APPROVAL_MODE${CODEX_MODEL:+ model=$CODEX_MODEL})"
if [ -n "${INITIAL_PROMPT:-}" ]; then
    exec codex "${codex_args[@]}" "$INITIAL_PROMPT"
else
    exec codex "${codex_args[@]}"
fi
