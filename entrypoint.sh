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
AUTO_COMMIT="${AUTO_COMMIT:-wip}"  # "off" = no auto-commit, "wip" = safety-net [wip] only, "on" = always commit (legacy)
PUSH_REBASE_MAX_RETRIES="${PUSH_REBASE_MAX_RETRIES:-3}"

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
    local msg="[agentmill:agent-${AGENT_ID} $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent-${AGENT_ID}.log"
}

push_branch_with_retries() {
    local branch="$1"
    local max_retries="${2:-$PUSH_REBASE_MAX_RETRIES}"
    local retry=0

    log "Pushing to upstream (branch: $branch)..."
    while true; do
        if git push origin "$branch" 2>/dev/null; then
            return 0
        fi

        if [ "$retry" -ge "$max_retries" ]; then
            log "ERROR: push failed after $max_retries retries"
            return 1
        fi

        retry=$((retry + 1))
        log "Push failed, rebasing and retrying ($retry/$max_retries)..."

        if ! git fetch origin; then
            log "ERROR: git fetch failed during push retry $retry/$max_retries"
            return 1
        fi

        if ! git rebase "origin/$branch" 2>/dev/null; then
            git rebase --abort 2>/dev/null || true
            log "WARN: Rebase conflict on retry $retry/$max_retries, will retry next iteration"
            return 1
        fi
    done
}

# — Auth check ———————————————————————————————————
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

# — Merge host Claude config (MCP, plugins, settings) ———
/setup-claude-config.sh

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

if [ -d "$UPSTREAM_DIR/.git" ] || [ -f "$UPSTREAM_DIR/HEAD" ]; then
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

    if [ ! -d "$REPO_DIR/.git" ]; then
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

elif [ -d "$REPO_DIR/.git" ] || [ -f "$REPO_DIR/.git" ]; then
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
SETTINGS_LOCAL=".claude/settings.local.json"
SETTINGS_BACKUP=""
mkdir -p .claude

if [ -f "$SETTINGS_LOCAL" ]; then
    SETTINGS_BACKUP="$(cat "$SETTINGS_LOCAL")"
fi

echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit","mcp__*"],"defaultMode":"bypassPermissions"}}' \
    > "$SETTINGS_LOCAL"

restore_settings() {
    if [ -n "$SETTINGS_BACKUP" ]; then
        echo "$SETTINGS_BACKUP" > "$SETTINGS_LOCAL"
    else
        rm -f "$SETTINGS_LOCAL"
    fi
}

trap 'restore_settings' EXIT

# — Main loop ————————————————————————————————————
log "Starting agent loop (model=$MODEL, max_iterations=$MAX_ITERATIONS)"

while true; do
    if [ "$SHUTTING_DOWN" = true ]; then
        log "Shutdown requested. Exiting loop."
        break
    fi

    ITERATION=$((ITERATION + 1))
    ITER_START_TIME="$(date +%s)"
    SESSION_LOG="$LOG_DIR/session_$(date -u '+%Y%m%d_%H%M%S')_iter${ITERATION}.log"

    log "==== Iteration $ITERATION ===="

    # Check for prompt file
    if [ ! -f "$PROMPT_FILE" ]; then
        log "ERROR: Prompt file not found at $PROMPT_FILE"
        log "Mount your prompt file or set PROMPT_FILE env var."
        exit 1
    fi

    # Run Claude
    log "Running Claude (session log: $SESSION_LOG)..."
    PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

    set +e
    claude --dangerously-skip-permissions \
        -p "$PROMPT_CONTENT" \
        --model "$MODEL" \
        2>&1 | tee "$SESSION_LOG"
    CLAUDE_EXIT=$?
    set -e

    log "Claude exited with code $CLAUDE_EXIT"

    # Commit any changes (controlled by AUTO_COMMIT flag)
    if [ -n "$(git status --porcelain)" ]; then
        # Check if the agent already committed during this iteration
        LAST_COMMIT_TIME="$(git log -1 --format='%ct' 2>/dev/null || echo 0)"
        AGENT_COMMITTED=false
        if [ "$LAST_COMMIT_TIME" -ge "$ITER_START_TIME" ] 2>/dev/null; then
            AGENT_COMMITTED=true
        fi

        case "$AUTO_COMMIT" in
            off)
                log "Auto-commit disabled. Uncommitted changes left in working tree."
                ;;
            wip)
                if [ "$AGENT_COMMITTED" = true ]; then
                    # Agent made its own commits — only safety-net the leftovers
                    if [ -n "$(git status --porcelain)" ]; then
                        log "Safety-net: committing leftover uncommitted changes as [wip]..."
                        git add -A
                        git commit -m "[wip] agent-${AGENT_ID}: uncommitted leftovers from iteration $ITERATION"
                    fi
                else
                    # Agent didn't commit at all — save everything as wip
                    log "Safety-net: agent made no commits, saving work as [wip]..."
                    git add -A
                    git commit -m "[wip] agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
                fi
                ;;
            on|*)
                log "Committing changes..."
                git add -A
                git commit -m "agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
                log "Changes committed."
                ;;
        esac

        # Multi-agent: push agent branch to upstream
        if [ "$MULTI_AGENT" = true ]; then
            if ! push_branch_with_retries "$AGENT_BRANCH"; then
                log "WARN: Skipping push for iteration $ITERATION"
            fi
        fi
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
