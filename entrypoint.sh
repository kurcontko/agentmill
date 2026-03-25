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
LOOP_DELAY_MAX="${LOOP_DELAY_MAX:-300}"  # max backoff delay (5 min)
AUTO_COMMIT="${AUTO_COMMIT:-wip}"  # "off" = no auto-commit, "wip" = safety-net [wip] only, "on" = always commit (legacy)
PUSH_REBASE_MAX_RETRIES="${PUSH_REBASE_MAX_RETRIES:-3}"
AGENT_CLI="${AGENT_CLI:-claude}"  # "claude" or "opencode"

# — State ————————————————————————————————————————
ITERATION=0
SHUTTING_DOWN=false
CURRENT_DELAY="$LOOP_DELAY"
NO_CHANGE_STREAK=0

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

# — Context injection ————————————————————————————
generate_iteration_context() {
    local context_file="$LOG_DIR/iteration_context.md"
    {
        echo "## Iteration $ITERATION Context (auto-generated)"
        echo ""

        # Last commit summary
        echo "### Last Commit"
        git log -1 --format='%h %s (%ar)' 2>/dev/null || echo "(no commits yet)"
        echo ""

        # Recent changes overview
        echo "### Recent Changes (last 5 commits)"
        git log --oneline -5 2>/dev/null || echo "(no history)"
        echo ""

        # Current working tree status
        echo "### Working Tree"
        git status --short 2>/dev/null || echo "(clean)"
        echo ""

        # PROGRESS.md tail
        if [ -f PROGRESS.md ]; then
            echo "### Progress (tail)"
            tail -15 PROGRESS.md
            echo ""
        fi

        # Last session summary (continuity)
        if [ -f "$LOG_DIR/last-session-summary.md" ]; then
            echo "### Last Session Summary"
            cat "$LOG_DIR/last-session-summary.md"
            echo ""
        fi

        # Other active agents
        AWARENESS="$(generate_agent_awareness)"
        if [ -n "$AWARENESS" ]; then
            echo "$AWARENESS"
            echo ""
        fi

        # No-change streak warning
        if [ "$NO_CHANGE_STREAK" -ge 2 ]; then
            echo "### WARNING: No-change streak ($NO_CHANGE_STREAK iterations)"
            echo "The last $NO_CHANGE_STREAK iterations produced no changes. Try a different approach."
            echo ""
        fi
    } > "$context_file"
    echo "$context_file"
}

# — Budget tracking ——————————————————————————————
log_budget() {
    local session_log="$1"
    local budget_file="$LOG_DIR/budget.csv"

    # Create header if file doesn't exist
    if [ ! -f "$budget_file" ]; then
        echo "iteration,timestamp,input_tokens,output_tokens,total_tokens,duration_s" > "$budget_file"
    fi

    # Try to extract token counts from Claude's output
    local input_tokens output_tokens total_tokens
    input_tokens="$(grep -oP 'input[_\s]*tokens?[:\s]*\K[0-9]+' "$session_log" 2>/dev/null | tail -1 || echo 0)"
    output_tokens="$(grep -oP 'output[_\s]*tokens?[:\s]*\K[0-9]+' "$session_log" 2>/dev/null | tail -1 || echo 0)"
    total_tokens="$(grep -oP 'total[_\s]*tokens?[:\s]*\K[0-9]+' "$session_log" 2>/dev/null | tail -1 || echo 0)"

    local duration=$(($(date +%s) - ITER_START_TIME))
    echo "$ITERATION,$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$input_tokens,$output_tokens,$total_tokens,$duration" >> "$budget_file"
}

# — Agent manifest ———————————————————————————————
AGENT_MANIFEST_DIR="$LOG_DIR/agents"
mkdir -p "$AGENT_MANIFEST_DIR"

write_agent_manifest() {
    local status="${1:-running}"
    local manifest="$AGENT_MANIFEST_DIR/agent-${AGENT_ID}.json"
    cat > "$manifest" <<MANIFEST_EOF
{
  "id": "${AGENT_ID}",
  "branch": "${AGENT_BRANCH:-unknown}",
  "role": "${AGENT_ROLE:-general}",
  "prompt_file": "${PROMPT_FILE}",
  "started_at": "${AGENT_START_TIME:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}",
  "last_iteration": ${ITERATION},
  "status": "${status}",
  "updated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
MANIFEST_EOF
}

# — Mutual awareness —————————————————————————————
generate_agent_awareness() {
    local awareness=""
    local manifest_file
    for manifest_file in "$AGENT_MANIFEST_DIR"/agent-*.json; do
        [ -f "$manifest_file" ] || continue
        local other_id
        other_id="$(basename "$manifest_file" .json | sed 's/^agent-//')"
        # Skip self
        [ "$other_id" = "$AGENT_ID" ] && continue
        # Skip stale manifests (>30 min old)
        local file_age
        file_age=$(( $(date +%s) - $(stat -c %Y "$manifest_file" 2>/dev/null || echo 0) ))
        [ "$file_age" -gt 1800 ] && continue
        awareness="${awareness}
- Agent ${other_id}: $(grep -oP '"status"\s*:\s*"\K[^"]+' "$manifest_file" 2>/dev/null || echo unknown) (iter $(grep -oP '"last_iteration"\s*:\s*\K[0-9]+' "$manifest_file" 2>/dev/null || echo '?'), branch $(grep -oP '"branch"\s*:\s*"\K[^"]+' "$manifest_file" 2>/dev/null || echo '?'))"
    done

    if [ -n "$awareness" ]; then
        echo "### Active Agents${awareness}"
    fi
}

# — Lock protocol for current_tasks/ —————————————
LOCK_STALE_SECONDS=900  # 15 minutes

acquire_task_lock() {
    local slug="$1"
    local lock_file="current_tasks/${slug}.lock"
    mkdir -p current_tasks

    # Check for existing lock
    if [ -f "$lock_file" ]; then
        local lock_age
        lock_age=$(( $(date +%s) - $(stat -c %Y "$lock_file" 2>/dev/null || echo 0) ))
        if [ "$lock_age" -lt "$LOCK_STALE_SECONDS" ]; then
            local lock_owner
            lock_owner="$(head -1 "$lock_file" 2>/dev/null || echo unknown)"
            log "WARN: Task '$slug' locked by $lock_owner (${lock_age}s ago)"
            return 1
        fi
        log "Removing stale lock for '$slug' (${lock_age}s old)"
    fi

    echo "agent-${AGENT_ID}" > "$lock_file"
    date -u '+%Y-%m-%dT%H:%M:%SZ' >> "$lock_file"
    return 0
}

release_task_lock() {
    local slug="$1"
    local lock_file="current_tasks/${slug}.lock"
    if [ -f "$lock_file" ]; then
        local lock_owner
        lock_owner="$(head -1 "$lock_file" 2>/dev/null || echo unknown)"
        if [ "$lock_owner" = "agent-${AGENT_ID}" ]; then
            rm -f "$lock_file"
        fi
    fi
}

# — Smart commit helpers ——————————————————————————
classify_commit() {
    # Classify changes as feat/fix/refactor/test/docs based on file paths
    local files="$1"
    local classification="feat"

    if echo "$files" | grep -qE '(test_|_test\.|\.test\.|spec\.)'; then
        classification="test"
    elif echo "$files" | grep -qE '(README|CHANGELOG|\.md$|docs/)'; then
        classification="docs"
    elif echo "$files" | grep -qE '(\.fix|bugfix|hotfix)' || echo "$files" | grep -qiE 'fix'; then
        classification="fix"
    fi

    echo "$classification"
}

extract_intended_message() {
    # Parse Claude's session log for commit messages it intended but didn't execute
    local session_log="$1"
    # Look for patterns like: git commit -m "..." or commit message suggestions
    local msg
    msg="$(grep -oP 'git commit -m ["\x27]\K[^"\x27]+' "$session_log" 2>/dev/null | tail -1 || true)"
    if [ -z "$msg" ]; then
        # Try to find commit message suggestions in natural language
        msg="$(grep -oP '(?:commit message|commit msg)[:\s]*["\x27]?\K[^"\x27\n]+' "$session_log" 2>/dev/null | tail -1 || true)"
    fi
    echo "$msg"
}

smart_commit_split() {
    # If diff is large (>500 lines), try to split into semantic commits by directory
    local total_lines
    total_lines="$(git diff --cached --stat | tail -1 | grep -oP '\d+(?= insertion)' || echo 0)"
    local total_deletions
    total_deletions="$(git diff --cached --stat | tail -1 | grep -oP '\d+(?= deletion)' || echo 0)"
    local total_changes=$(( total_lines + total_deletions ))

    if [ "$total_changes" -le 500 ]; then
        return 1  # Not large enough to split
    fi

    log "Large diff detected ($total_changes lines). Splitting into semantic commits..."

    # Get unique top-level directories of changed files
    local dirs
    dirs="$(git diff --cached --name-only | sed 's|/.*||' | sort -u)"

    # Unstage everything first
    git reset HEAD -- . > /dev/null 2>&1

    local committed=false
    local dir
    for dir in $dirs; do
        local dir_files
        dir_files="$(git status --porcelain -- "$dir" 2>/dev/null | awk '{print $2}')"
        if [ -z "$dir_files" ]; then
            continue
        fi

        git add -- "$dir"
        local classification
        classification="$(classify_commit "$dir_files")"
        git commit -m "${classification}: agent-${AGENT_ID}: changes in ${dir}/ (iteration $ITERATION)" > /dev/null 2>&1 || true
        committed=true
    done

    # Catch any remaining files not in subdirectories
    if [ -n "$(git status --porcelain)" ]; then
        git add -A
        git commit -m "feat: agent-${AGENT_ID}: remaining changes (iteration $ITERATION)" > /dev/null 2>&1 || true
    fi

    [ "$committed" = true ]
}

# — Session continuity ————————————————————————————
write_session_summary() {
    local summary_file="$LOG_DIR/last-session-summary.md"
    {
        echo "# Session Summary (agent-${AGENT_ID}, iteration $ITERATION)"
        echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo ""

        # What changed
        echo "## What Changed"
        git log --oneline -5 2>/dev/null || echo "(no commits)"
        echo ""
        DIFF_STAT="$(git diff --stat HEAD~1 2>/dev/null | tail -1 || echo 'nothing')"
        echo "Last diff: $DIFF_STAT"
        echo ""

        # What broke (test results if available)
        echo "## Test Status"
        if [ -f /tmp/quality_test.log ]; then
            tail -5 /tmp/quality_test.log
        else
            echo "(no test results available)"
        fi
        echo ""

        # What's next
        echo "## What's Next"
        if [ -f PROGRESS.md ]; then
            grep -A5 '## Next Up' PROGRESS.md 2>/dev/null || echo "(see PROGRESS.md)"
        else
            echo "(no PROGRESS.md)"
        fi
        echo ""

        # No-progress streak warning
        if [ "$NO_CHANGE_STREAK" -ge 3 ]; then
            echo "## WARNING: No-progress streak ($NO_CHANGE_STREAK iterations)"
            echo "Consider operator intervention. The agent has produced no meaningful changes for $NO_CHANGE_STREAK consecutive iterations."
            echo ""
        fi
    } > "$summary_file"
}

# — Quality gates ————————————————————————————————
check_progress_updated() {
    local before_hash="$1"
    local after_hash
    if [ -f PROGRESS.md ]; then
        after_hash="$(sha256sum PROGRESS.md | cut -d' ' -f1)"
    else
        after_hash="none"
    fi
    [ "$before_hash" != "$after_hash" ]
}

log_quality_score() {
    local quality_file="$LOG_DIR/quality.csv"
    if [ ! -f "$quality_file" ]; then
        echo "iteration,timestamp,files_changed,tests_added,tests_passing,progress_updated" > "$quality_file"
    fi

    local files_changed tests_added tests_passing progress_updated
    files_changed="$(git diff --name-only HEAD~1 2>/dev/null | wc -l || echo 0)"
    tests_added="$(git diff HEAD~1 2>/dev/null | grep -c '^+.*\(def test_\|it(\|describe(\|assert\|expect\)' || echo 0)"

    # Check if tests pass (quick check)
    tests_passing="unknown"
    if [ -f Makefile ] && grep -q '^test:' Makefile 2>/dev/null; then
        if make test > /tmp/quality_test.log 2>&1; then
            tests_passing="yes"
        else
            tests_passing="no"
        fi
    elif [ -f pyproject.toml ] || [ -f setup.py ]; then
        if python3 -m unittest discover -s tests > /tmp/quality_test.log 2>&1; then
            tests_passing="yes"
        else
            tests_passing="no"
        fi
    fi

    progress_updated="${1:-false}"
    echo "$ITERATION,$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$files_changed,$tests_added,$tests_passing,$progress_updated" >> "$quality_file"
}

# — Auth check ———————————————————————————————————
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
        log "  Option 1: Set LOCAL_ENDPOINT for local models (vLLM, llama.cpp)"
        log "  Option 2: Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or other provider key"
        exit 1
    fi
fi

# — Merge host config (CLI-specific) ————————————————
if [ "$AGENT_CLI" = "claude" ]; then
    /setup-claude-config.sh
else
    log "Using AGENT_CLI=$AGENT_CLI"
fi

# — Source CLI wrapper ———————————————————————————
. /agent-run.sh

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
if [ "$AGENT_CLI" = "claude" ]; then
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
elif [ "$AGENT_CLI" = "opencode" ]; then
    /setup-opencode-config.sh "$(pwd)"
fi

# — Write initial agent manifest ——————————————————
AGENT_START_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
AGENT_ROLE="${AGENT_ROLE:-general}"
write_agent_manifest "starting"

# — Main loop ————————————————————————————————————
log "Starting agent loop (cli=$AGENT_CLI, model=$MODEL, max_iterations=$MAX_ITERATIONS)"

while true; do
    if [ "$SHUTTING_DOWN" = true ]; then
        log "Shutdown requested. Exiting loop."
        break
    fi

    ITERATION=$((ITERATION + 1))
    ITER_START_TIME="$(date +%s)"
    SESSION_LOG="$LOG_DIR/session_$(date -u '+%Y%m%d_%H%M%S')_iter${ITERATION}.log"

    log "==== Iteration $ITERATION ===="

    # Update agent manifest
    write_agent_manifest "running"

    # Pre-iteration checkpoint tag (lightweight rollback point)
    git tag -f "pre-iter-${AGENT_ID}-${ITERATION}" 2>/dev/null || true

    # Check for prompt file
    if [ ! -f "$PROMPT_FILE" ]; then
        log "ERROR: Prompt file not found at $PROMPT_FILE"
        log "Mount your prompt file or set PROMPT_FILE env var."
        exit 1
    fi

    # Snapshot PROGRESS.md hash for quality gate
    if [ -f PROGRESS.md ]; then
        PROGRESS_HASH_BEFORE="$(sha256sum PROGRESS.md | cut -d' ' -f1)"
    else
        PROGRESS_HASH_BEFORE="none"
    fi

    # Generate iteration context preamble
    CONTEXT_FILE="$(generate_iteration_context)"

    # Run Claude with context-enriched prompt
    log "Running Claude (session log: $SESSION_LOG)..."
    PROMPT_CONTENT="$(cat "$CONTEXT_FILE")

---

$(cat "$PROMPT_FILE")"

    set +e
    agent_run_headless "$PROMPT_CONTENT" "$MODEL" \
        2>&1 | tee "$SESSION_LOG"
    CLAUDE_EXIT=$?
    set -e

    log "Claude exited with code $CLAUDE_EXIT"

    # Quality gate: check if PROGRESS.md was updated when changes were made
    PROGRESS_WAS_UPDATED=false
    if [ -n "$(git status --porcelain)" ] || [ -n "$(git diff --name-only HEAD 2>/dev/null)" ]; then
        if check_progress_updated "$PROGRESS_HASH_BEFORE"; then
            PROGRESS_WAS_UPDATED=true
        else
            log "WARN: Changes made but PROGRESS.md not updated. Running reminder..."
            set +e
            agent_run_headless "You made changes but did not update PROGRESS.md. Please update PROGRESS.md now with what you accomplished, what's in progress, and what's next. Keep it concise." "$MODEL" \
                2>&1 | tee "$LOG_DIR/reminder_iter${ITERATION}.log"
            set -e
            # Re-check after reminder
            if check_progress_updated "$PROGRESS_HASH_BEFORE"; then
                PROGRESS_WAS_UPDATED=true
            fi
        fi
    fi

    # Commit any changes (controlled by AUTO_COMMIT flag)
    ITERATION_HAD_CHANGES=false
    if [ -n "$(git status --porcelain)" ]; then
        ITERATION_HAD_CHANGES=true
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
                    # Agent didn't commit at all — try smart commit
                    log "Safety-net: agent made no commits, saving work..."

                    # Try to extract intended commit message from session log
                    INTENDED_MSG="$(extract_intended_message "$SESSION_LOG")"

                    git add -A

                    # Try to split large diffs into semantic commits
                    if smart_commit_split; then
                        log "Split large diff into semantic commits."
                    elif [ -n "$INTENDED_MSG" ]; then
                        # Use the agent's intended message with classification
                        CHANGED_FILES="$(git diff --cached --name-only 2>/dev/null)"
                        COMMIT_CLASS="$(classify_commit "$CHANGED_FILES")"
                        git commit -m "${COMMIT_CLASS}: ${INTENDED_MSG}"
                        log "Committed with extracted message: ${COMMIT_CLASS}: ${INTENDED_MSG}"
                    else
                        # Fallback: classify and commit as wip
                        CHANGED_FILES="$(git diff --cached --name-only 2>/dev/null)"
                        COMMIT_CLASS="$(classify_commit "$CHANGED_FILES")"
                        git commit -m "[wip] ${COMMIT_CLASS}: agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
                    fi
                fi
                ;;
            on|*)
                log "Committing changes..."
                git add -A
                git commit -m "agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
                log "Changes committed."
                ;;
        esac

        # Log quality metrics
        DIFF_STAT="$(git diff --stat HEAD~1 2>/dev/null | tail -1 || echo 'unknown')"
        log "Iteration $ITERATION diff: $DIFF_STAT"

        # Log quality score
        log_quality_score "$PROGRESS_WAS_UPDATED"

        # Multi-agent: push agent branch to upstream
        if [ "$MULTI_AGENT" = true ]; then
            if ! push_branch_with_retries "$AGENT_BRANCH"; then
                # Rebase failed with conflicts — ask Claude to resolve
                if [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
                    log "Merge conflicts detected. Asking Claude to resolve..."
                    CONFLICT_FILES="$(git diff --name-only --diff-filter=U 2>/dev/null | head -20)"
                    RESOLVE_PROMPT="There are git merge conflicts in the following files that need to be resolved:

${CONFLICT_FILES}

Please resolve all conflict markers (<<<<<<< ======= >>>>>>>) in these files.
Choose the best resolution for each conflict based on the intent of both sides.
After resolving, stage the files with git add and run: git rebase --continue"

                    set +e
                    agent_run_headless "$RESOLVE_PROMPT" "$MODEL" \
                        2>&1 | tee "$LOG_DIR/resolve_iter${ITERATION}.log"
                    set -e

                    # Retry push after resolution
                    if ! push_branch_with_retries "$AGENT_BRANCH"; then
                        log "WARN: Push still failed after conflict resolution in iteration $ITERATION"
                    fi
                else
                    log "WARN: Skipping push for iteration $ITERATION"
                fi
            fi
        fi
    else
        # Check if agent committed during this iteration (working tree clean but commits made)
        LAST_COMMIT_TIME="$(git log -1 --format='%ct' 2>/dev/null || echo 0)"
        if [ "$LAST_COMMIT_TIME" -ge "$ITER_START_TIME" ] 2>/dev/null; then
            ITERATION_HAD_CHANGES=true
        fi
        log "No changes to commit."
    fi

    # Log budget/token metrics
    log_budget "$SESSION_LOG"

    # Write session summary for continuity
    write_session_summary

    # Check iteration limit
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
        log "Reached max iterations ($MAX_ITERATIONS). Stopping."
        break
    fi

    # Adaptive delay: backoff on no changes, reset on changes
    if [ "$ITERATION_HAD_CHANGES" = true ]; then
        CURRENT_DELAY="$LOOP_DELAY"
        NO_CHANGE_STREAK=0
    else
        NO_CHANGE_STREAK=$((NO_CHANGE_STREAK + 1))
        CURRENT_DELAY=$((CURRENT_DELAY * 2))
        if [ "$CURRENT_DELAY" -gt "$LOOP_DELAY_MAX" ]; then
            CURRENT_DELAY="$LOOP_DELAY_MAX"
        fi
        log "No changes detected (streak: $NO_CHANGE_STREAK). Backing off."
        if [ "$NO_CHANGE_STREAK" -ge 3 ]; then
            log "WARNING: No-progress streak ($NO_CHANGE_STREAK iterations). Consider operator intervention."
        fi
    fi

    log "Sleeping ${CURRENT_DELAY}s before next iteration..."
    sleep "$CURRENT_DELAY"
done

write_agent_manifest "finished"
log "Agent loop finished after $ITERATION iterations."
