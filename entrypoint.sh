#!/usr/bin/env bash
set -euo pipefail

# — Configuration ————————————————————————————————
AGENT_ID="${AGENT_ID:-1}"
AGENT_BRANCH="${AGENT_BRANCH:-}"  # empty = auto-detect per mode
LOG_DIR="/workspace/logs"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
MODEL="${MODEL:-sonnet}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"  # 0 = infinite
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
LOOP_DELAY="${LOOP_DELAY:-5}"  # seconds between iterations
AGENT_RUNTIME="${AGENT_RUNTIME:-claude-code}"  # claude-code | thin
THIN_BASE_URL="${THIN_BASE_URL:-${OPENAI_BASE_URL:-https://api.openai.com/v1}}"
THIN_API_KEY="${THIN_API_KEY:-${OPENAI_API_KEY:-}}"
THIN_MAX_ROUNDS="${THIN_MAX_ROUNDS:-50}"

# — State ————————————————————————————————————————
ITERATION=0
SHUTTING_DOWN=false

# — Graceful shutdown ————————————————————————————
cleanup() {
    echo "[agentmill] Received shutdown signal. Finishing current session..."
    SHUTTING_DOWN=true
}
trap cleanup SIGTERM SIGINT

# — Logging helper ———————————————————————————————
mkdir -p "$LOG_DIR"

log() {
    local msg
    msg="[agentmill:agent-${AGENT_ID} $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent-${AGENT_ID}.log"
}

# — Auth check ———————————————————————————————————
if [[ "$AGENT_RUNTIME" = "thin" ]]; then
    if [[ -z "${THIN_API_KEY:-}" ]]; then
        log "ERROR: thin runtime requires THIN_API_KEY, OPENAI_API_KEY, or --api-key"
        exit 1
    fi
    log "Auth: using thin runtime (base_url=${THIN_BASE_URL})"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    log "Auth: using ANTHROPIC_API_KEY"
elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    log "Auth: using CLAUDE_CODE_OAUTH_TOKEN (subscription)"
    if [[ ! -f "$HOME/.claude.json" ]]; then
        echo '{"hasCompletedOnboarding":true}' > "$HOME/.claude.json"
    fi
else
    log "ERROR: No auth configured."
    log "  Option 1: Set ANTHROPIC_API_KEY env var (API credits)"
    log "  Option 2: Set CLAUDE_CODE_OAUTH_TOKEN env var (subscription, from 'claude setup-token')"
    log "  Option 3: Set AGENT_RUNTIME=thin with THIN_API_KEY (any OpenAI-compatible API)"
    exit 1
fi

# — Merge host Claude config (MCP, plugins, settings) ———
if [[ "$AGENT_RUNTIME" != "thin" ]]; then
    /setup-claude-config.sh
fi

# — Git configuration ————————————————————————————
git config --global user.name "${GIT_USER}-${AGENT_ID}"
git config --global user.email "$GIT_EMAIL"

# — Workspace setup ——————————————————————————————
# Three modes, auto-detected:
#
#   1. Single agent (default)
#      Mount: REPO_PATH -> /workspace/repo
#      Agent works directly in the mounted repo.
#
#   2. Multi-agent: independent clones
#      Mount: REPO_PATH -> /workspace/upstream (read-only)
#      Each agent clones into /workspace/repo-$AGENT_ID.
#      Sync via git push/pull to upstream.
#
#   3. Multi-agent: pre-created worktrees
#      Mount: host worktree -> /workspace/repo
#      Host creates worktrees beforehand; each agent gets its own mount.
#      From the agent's perspective, this looks like mode 1.

UPSTREAM_DIR="/workspace/upstream"
REPO_DIR="/workspace/repo"

if [[ -d "$UPSTREAM_DIR/.git" || -f "$UPSTREAM_DIR/HEAD" ]]; then
    # Mode 2: upstream mounted — clone into isolated workspace
    # Each agent gets its own clone. Sync via git push/pull.
    # Default branch: agent-$AGENT_ID (safe to push to non-bare upstream
    # as long as the branch isn't checked out on the host).
    REPO_DIR="/workspace/repo-${AGENT_ID}"
    : "${AGENT_BRANCH:=agent-${AGENT_ID}}"
    MULTI_AGENT=true

    log "Multi-agent mode: agent-${AGENT_ID} on branch ${AGENT_BRANCH}"

    # Allow pushing to non-bare upstream (agents push to their own branches,
    # not the checked-out branch, so this is safe).
    git -C "$UPSTREAM_DIR" config receive.denyCurrentBranch updateInstead 2>/dev/null || true

    if [[ ! -d "$REPO_DIR/.git" ]]; then
        git clone "$UPSTREAM_DIR" "$REPO_DIR"
        cd "$REPO_DIR"
        git remote set-url origin "$UPSTREAM_DIR"
    else
        cd "$REPO_DIR"
        git fetch origin
    fi

    # Create or checkout agent branch from upstream's HEAD
    UPSTREAM_HEAD="$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
    if git show-ref --verify --quiet "refs/heads/$AGENT_BRANCH"; then
        git checkout "$AGENT_BRANCH"
        # Fast-forward to upstream if behind
        git rebase "$UPSTREAM_HEAD" 2>/dev/null || git rebase --abort
    else
        git checkout -b "$AGENT_BRANCH" "$UPSTREAM_HEAD"
    fi

    log "Repo ready at $REPO_DIR (branch: $(git branch --show-current))"

elif [[ -d "$REPO_DIR/.git" ]]; then
    # Mode 1 or 3: direct mount (single agent or pre-created worktree)
    MULTI_AGENT=false
    : "${AGENT_BRANCH:=main}"
    cd "$REPO_DIR"
    log "Repo ready at $REPO_DIR (direct mount)"
else
    log "ERROR: No repo found. Mount to /workspace/repo (single) or /workspace/upstream (multi)."
    exit 1
fi

log "Preparing repo environment..."
. /setup-repo-env.sh "$REPO_DIR"
log "Repo environment ready."

# — Override project settings for autonomous mode ————————
if [[ "$AGENT_RUNTIME" != "thin" ]]; then
    SETTINGS_LOCAL=".claude/settings.local.json"
    SETTINGS_BACKUP=""
    mkdir -p .claude

    if [[ -f "$SETTINGS_LOCAL" ]]; then
        SETTINGS_BACKUP="$(cat "$SETTINGS_LOCAL")"
    fi

    # NOSONAR — autonomous agent container requires full tool permissions
    echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit","mcp__*"],"defaultMode":"bypassPermissions"}}' \
        > "$SETTINGS_LOCAL"

    restore_settings() {
        if [[ -n "$SETTINGS_BACKUP" ]]; then
            echo "$SETTINGS_BACKUP" > "$SETTINGS_LOCAL"
        else
            rm -f "$SETTINGS_LOCAL"
        fi
        return 0
    }

    trap 'restore_settings' EXIT
fi

# — Agent dispatch ———————————————————————————————
run_agent() {
    local prompt="$1"
    local log_file="$2"

    case "$AGENT_RUNTIME" in
        claude-code)
            # NOSONAR — dangerously-skip-permissions is required for headless autonomous operation
            claude --dangerously-skip-permissions \
                -p "$prompt" \
                --model "$MODEL" \
                2>&1 | tee "$log_file"
            ;;
        thin)
            python3 /thin_runner.py \
                --prompt "$prompt" \
                --model "$MODEL" \
                --base-url "$THIN_BASE_URL" \
                --api-key "$THIN_API_KEY" \
                --max-rounds "$THIN_MAX_ROUNDS" \
                --cwd "$PWD" \
                --verbose \
                2>&1 | tee "$log_file"
            ;;
        *)
            log "ERROR: Unknown AGENT_RUNTIME: $AGENT_RUNTIME"
            return 1
            ;;
    esac
}

# — Main loop ————————————————————————————————————
log "Starting agent loop (runtime=$AGENT_RUNTIME, model=$MODEL, max_iterations=$MAX_ITERATIONS)"

while true; do
    if [[ "$SHUTTING_DOWN" = true ]]; then
        log "Shutdown requested. Exiting loop."
        break
    fi

    ITERATION=$((ITERATION + 1))
    SESSION_LOG="$LOG_DIR/session_$(date -u '+%Y%m%d_%H%M%S')_iter${ITERATION}.log"

    log "==== Iteration $ITERATION ===="

    # Check for prompt file
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log "ERROR: Prompt file not found at $PROMPT_FILE"
        log "Mount your prompt file or set PROMPT_FILE env var."
        exit 1
    fi

    # Run agent
    log "Running agent ($AGENT_RUNTIME, session log: $SESSION_LOG)..."
    PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

    set +e
    run_agent "$PROMPT_CONTENT" "$SESSION_LOG"
    AGENT_EXIT=$?
    set -e

    log "Agent exited with code $AGENT_EXIT"

    # Commit any changes
    if [[ -n "$(git status --porcelain)" ]]; then
        log "Committing changes..."
        git add -A
        git commit -m "agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
        log "Changes committed."

        # Multi-agent: push agent branch to upstream
        if [[ "$MULTI_AGENT" = true ]]; then
            log "Pushing to upstream (branch: $AGENT_BRANCH)..."
            if ! git push origin "$AGENT_BRANCH" 2>/dev/null; then
                log "Push failed, rebasing and retrying..."
                git fetch origin
                if git rebase "origin/$AGENT_BRANCH" 2>/dev/null; then
                    git push origin "$AGENT_BRANCH" || log "WARN: Push failed, will retry next iteration"
                else
                    git rebase --abort
                    log "WARN: Rebase conflict, will retry next iteration"
                fi
            fi
        fi
    else
        log "No changes to commit."
    fi

    # Check iteration limit
    if [[ "$MAX_ITERATIONS" -gt 0 && "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
        log "Reached max iterations ($MAX_ITERATIONS). Stopping."
        break
    fi

    # Brief pause before next iteration
    log "Sleeping ${LOOP_DELAY}s before next iteration..."
    sleep "$LOOP_DELAY"
done

log "Agent loop finished after $ITERATION iterations."
