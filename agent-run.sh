#!/usr/bin/env bash
# agent-run.sh — CLI abstraction layer for AgentMill
#
# Provides shell functions that route to either Claude Code CLI or OpenCode
# based on the AGENT_CLI environment variable. Source this file, don't execute it.
#
# Usage:
#   . /agent-run.sh
#   agent_run_headless "$prompt" "$model"
#   agent_run_tui "$model"

set -euo pipefail

AGENT_CLI="${AGENT_CLI:-claude}"

case "$AGENT_CLI" in
    claude|opencode) ;;
    *)
        echo "ERROR: AGENT_CLI must be 'claude' or 'opencode', got '$AGENT_CLI'" >&2
        exit 1
        ;;
esac

# agent_run_headless PROMPT MODEL
#   Run a headless (non-interactive) prompt. Output goes to stdout/stderr.
#   Returns the CLI exit code.
agent_run_headless() {
    local prompt="$1"
    local model="$2"

    case "$AGENT_CLI" in
        claude)
            claude --dangerously-skip-permissions \
                -p "$prompt" \
                --model "$model"
            ;;
        opencode)
            opencode run \
                --model "$model" \
                "$prompt"
            ;;
    esac
}

# agent_run_tui MODEL [INITIAL_PROMPT]
#   Launch the interactive TUI.
agent_run_tui() {
    local model="$1"
    local initial_prompt="${2:-}"

    case "$AGENT_CLI" in
        claude)
            if [ -n "$initial_prompt" ] && [ -f /auto-trust.exp ]; then
                # Use expect wrapper to auto-accept trust dialog and inject prompt
                export CLAUDE_MODEL="$model"
                export CLAUDE_INITIAL_PROMPT="$initial_prompt"
                /auto-trust.exp
            else
                claude --model "$model"
            fi
            ;;
        opencode)
            if [ -n "$initial_prompt" ]; then
                opencode --model "$model" --message "$initial_prompt"
            else
                opencode --model "$model"
            fi
            ;;
    esac
}
