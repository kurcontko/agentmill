#!/usr/bin/env bash
set -euo pipefail

# — Configuration ————————————————————————————————
AGENT_ID="${AGENT_ID:-1}"
AGENT_BRANCH="${AGENT_BRANCH:-}"  # empty = auto-detect per mode
LOG_DIR="${LOG_DIR:-/workspace/logs}"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
MODEL="${MODEL:-sonnet}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"  # 0 = infinite
MAX_WALL_SECONDS="${MAX_WALL_SECONDS:-0}"  # 0 = no wall-clock limit
MAX_LOG_BYTES="${MAX_LOG_BYTES:-0}"  # 0 = no log-size limit
MAX_TOTAL_TOKENS="${MAX_TOTAL_TOKENS:-0}"  # 0 = no token budget
MAX_TOTAL_USD="${MAX_TOTAL_USD:-0}"  # 0 = no cost budget
AGENTMILL_CLAUDE_OUTPUT_FORMAT="${AGENTMILL_CLAUDE_OUTPUT_FORMAT:-text}"  # text|json|stream-json
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
LOOP_DELAY="${LOOP_DELAY:-5}"  # seconds between iterations
AUTO_COMMIT="${AUTO_COMMIT:-wip}"  # "off" = no auto-commit, "wip" = safety-net [wip] only, "on" = always commit (legacy)
PUSH_REBASE_MAX_RETRIES="${PUSH_REBASE_MAX_RETRIES:-3}"
DONE_FILE="${DONE_FILE:-/tmp/.agentmill-done}"
AGENTMILL_WORKSPACE_MODE="${AGENTMILL_WORKSPACE_MODE:-direct}"
AGENTMILL_RUN_MODE="${AGENTMILL_RUN_MODE:-headless}"

# shellcheck source=/entrypoint-common.sh
. "${AGENTMILL_ENTRYPOINT_COMMON:-/entrypoint-common.sh}"
apply_agent_env_overrides
client_select "${AGENTMILL_CLIENT:-${AGENTMILL_PROVIDER:-claude}}"

MODEL_RAW="$MODEL"
MODEL="$(client_resolve_model "$MODEL_RAW")"
export MODEL
[[ "$MODEL" != "$MODEL_RAW" ]] && log "Resolved MODEL '$MODEL_RAW' -> '$MODEL'"
client_version "$MODEL"

# — State ————————————————————————————————————————
ITERATION=0
SHUTTING_DOWN=false

# — Graceful shutdown ————————————————————————————
cleanup() { log "Received shutdown signal. Finishing current session..."; SHUTTING_DOWN=true; }
trap cleanup SIGTERM SIGINT

# LOG_DIR already initialized by entrypoint-common.sh

push_branch_with_retries() {
    local branch="$1" max_retries="${2:-$PUSH_REBASE_MAX_RETRIES}" retry=0 push_output

    log "Pushing to upstream (branch: $branch)..."
    if ! enforce_git_remote_action_policy push "$branch"; then
        if declare -F event_emit_kv >/dev/null; then
            event_emit_kv push.failed branch="$branch" retry=0 retryable=false reason="git remote action policy denied"
        fi
        if declare -F run_hook >/dev/null; then
            run_hook on_failure "$(hook_payload hook=on_failure stage=push branch="$branch" retry=0 retryable=false reason="git remote action policy denied")" || true
        fi
        return 1
    fi
    while true; do
        if declare -F event_emit_kv >/dev/null; then
            event_emit_kv push.attempted branch="$branch" retry="$retry" max_retries="$max_retries"
        fi
        if push_output="$(git push --porcelain origin "$branch" 2>&1)"; then
            if declare -F event_emit_kv >/dev/null; then
                event_emit_kv push.completed branch="$branch" retry="$retry"
            fi
            return 0
        fi

        if ! push_failure_is_retryable "$push_output"; then
            log "ERROR: git push failed permanently for branch $branch"
            if [[ -n "$push_output" ]]; then
                while IFS= read -r line || [[ -n "$line" ]]; do
                    log "git push: $line"
                done <<< "$push_output"
            fi
            if declare -F event_emit_kv >/dev/null; then
                event_emit_kv push.failed branch="$branch" retry="$retry" retryable=false reason="$push_output"
            fi
            if declare -F run_hook >/dev/null; then
                run_hook on_failure "$(hook_payload hook=on_failure stage=push branch="$branch" retry="$retry" retryable=false reason="$push_output")" || true
            fi
            return 1
        fi
        if [[ "$retry" -ge "$max_retries" ]]; then
            log "ERROR: push failed after $max_retries retries"
            if declare -F event_emit_kv >/dev/null; then
                event_emit_kv push.failed branch="$branch" retry="$retry" retryable=true reason="retry limit reached"
            fi
            if declare -F run_hook >/dev/null; then
                run_hook on_failure "$(hook_payload hook=on_failure stage=push branch="$branch" retry="$retry" retryable=true reason="retry limit reached")" || true
            fi
            return 1
        fi

        retry=$((retry + 1))
        log "Push rejected, rebasing and retrying ($retry/$max_retries)..."
        if ! enforce_git_remote_action_policy fetch "$branch" || ! enforce_git_remote_action_policy rebase "$branch"; then
            if declare -F event_emit_kv >/dev/null; then
                event_emit_kv push.failed branch="$branch" retry="$retry" retryable=false reason="git rebase policy denied"
            fi
            if declare -F run_hook >/dev/null; then
                run_hook on_failure "$(hook_payload hook=on_failure stage=rebase branch="$branch" retry="$retry" retryable=false reason="git rebase policy denied")" || true
            fi
            return 1
        fi
        git fetch origin || { log "ERROR: git fetch failed on retry $retry"; return 1; }
        if git rebase "origin/$branch" 2>/dev/null; then
            if declare -F event_emit_kv >/dev/null; then
                event_emit_kv push.rebased branch="$branch" retry="$retry"
            fi
        else
            git rebase --abort 2>/dev/null || true
            log "WARN: Rebase conflict on retry $retry"
            if declare -F event_emit_kv >/dev/null; then
                event_emit_kv push.failed branch="$branch" retry="$retry" retryable=true reason="rebase conflict"
            fi
            if declare -F run_hook >/dev/null; then
                run_hook on_failure "$(hook_payload hook=on_failure stage=push branch="$branch" retry="$retry" retryable=true reason="rebase conflict")" || true
            fi
            if [[ "$retry" -ge "$max_retries" ]]; then
                log "ERROR: push failed after $max_retries retries"
                if declare -F event_emit_kv >/dev/null; then
                    event_emit_kv push.failed branch="$branch" retry="$retry" retryable=true reason="retry limit reached"
                fi
                if declare -F run_hook >/dev/null; then
                    run_hook on_failure "$(hook_payload hook=on_failure stage=push branch="$branch" retry="$retry" retryable=true reason="retry limit reached")" || true
                fi
                return 1
            fi
        fi
    done
}

client_require_auth
client_prepare_home
enforce_mcp_manifest_stability || exit 1
results_log_init
memory_init
configure_git_identity "$GIT_USER" "$GIT_EMAIL" "$AGENT_ID"
validate_runtime_policy headless || exit 1
RUN_START_TIME="$(date +%s)"

# — Workspace setup: auto-detect single/multi-agent/worktree mode —
UPSTREAM_DIR="${UPSTREAM_DIR:-/workspace/upstream}"
REPO_DIR="${REPO_DIR:-/workspace/repo}"

if [[ -d "$UPSTREAM_DIR/.git" ]] || [[ -f "$UPSTREAM_DIR/HEAD" ]]; then
    # Multi-agent: clone upstream into isolated workspace per agent
    REPO_DIR="${REPO_DIR}-${AGENT_ID}"
    : "${AGENT_BRANCH:=agent-${AGENT_ID}}"
    MULTI_AGENT=true

    log "Multi-agent mode: agent-${AGENT_ID} on branch ${AGENT_BRANCH}"
    if ! is_readonly_clone_mode; then
        git -C "$UPSTREAM_DIR" config receive.denyCurrentBranch updateInstead 2>/dev/null || true
    fi

    if [[ ! -d "$REPO_DIR/.git" ]]; then
        git clone "$UPSTREAM_DIR" "$REPO_DIR"
        cd "$REPO_DIR"
        git remote set-url origin "$UPSTREAM_DIR"
    else
        cd "$REPO_DIR"
        git fetch origin
    fi

    UPSTREAM_HEAD="$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
    if git show-ref --verify --quiet "refs/heads/$AGENT_BRANCH"; then
        git checkout "$AGENT_BRANCH"
        # Fast-forward to upstream if behind
        git rebase "$UPSTREAM_HEAD" 2>/dev/null || git rebase --abort
    else
        git checkout -b "$AGENT_BRANCH" "$UPSTREAM_HEAD"
    fi

    log "Repo ready at $REPO_DIR (branch: $(git branch --show-current))"

elif [[ -d "$REPO_DIR/.git" ]] || [[ -f "$REPO_DIR/.git" ]]; then
    MULTI_AGENT=false
    : "${AGENT_BRANCH:=main}"
    cd "$REPO_DIR"
    log "Repo ready at $REPO_DIR (direct mount)"
else
    log "ERROR: No repo found. Mount to /workspace/repo (single) or /workspace/upstream (multi)."
    exit 1
fi

enforce_workspace_isolation "$MULTI_AGENT" || exit 1
enforce_git_branch_policy "$MULTI_AGENT" || exit 1
AGENTMILL_BASE_SHA="${AGENTMILL_BASE_SHA:-$(git rev-parse HEAD 2>/dev/null || echo HEAD)}"
export AGENTMILL_BASE_SHA
prepare_repo_environment "$REPO_DIR"
event_emit_kv run.configured \
    mode="$AGENTMILL_RUN_MODE" \
    client="$AGENTMILL_CLIENT" \
    model="$MODEL" \
    model_raw="$MODEL_RAW" \
    profile="$AGENTMILL_PROFILE_LEVEL" \
    role="${AGENTMILL_ROLE:-}" \
    completion_gate="${AGENTMILL_COMPLETION_GATE:-done_file}" \
    network="${AGENTMILL_NETWORK:-}" \
    mcp_allowlist="${AGENTMILL_MCP_ALLOWLIST:-}" \
    mcp_manifest_lock="$AGENTMILL_MCP_MANIFEST_LOCK" \
    prompt_file="$PROMPT_FILE" \
    max_iterations="$MAX_ITERATIONS" \
    max_wall_seconds="$MAX_WALL_SECONDS" \
    max_log_bytes="$MAX_LOG_BYTES" \
    max_total_tokens="$MAX_TOTAL_TOKENS" \
    max_total_usd="$MAX_TOTAL_USD" \
    loop_delay="$LOOP_DELAY" \
    auto_commit="$AUTO_COMMIT" \
    branch="$AGENT_BRANCH" \
    base_sha="$AGENTMILL_BASE_SHA" \
    multi_agent="$MULTI_AGENT" \
    workspace_mode="$AGENTMILL_WORKSPACE_MODE" \
    repo_dir="$REPO_DIR"
status_write 0 starting "configured"

# — Override project settings for autonomous mode ————————
client_prepare_project "$REPO_DIR"
trap 'client_cleanup' EXIT

# — Main loop ————————————————————————————————————
log "Starting agent loop (model=$MODEL, max_iterations=$MAX_ITERATIONS)"

while true; do
    if [[ "$SHUTTING_DOWN" == true ]]; then
        log "Shutdown requested. Exiting loop."
        break
    fi

    ITERATION=$((ITERATION + 1))
    ITER_START_TIME="$(date +%s)"
    SESSION_LOG="$LOG_DIR/session_agent-${AGENT_ID}_$(date -u '+%Y%m%d_%H%M%S')_iter${ITERATION}.log"
    ITER_COMMITS_BEFORE="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
    ITER_HEAD_BEFORE="$(git rev-parse HEAD 2>/dev/null || echo HEAD)"

    log "==== Iteration $ITERATION ===="
    event_emit_kv iteration.started session_log="$SESSION_LOG" prompt_file="$PROMPT_FILE"
    status_write "$ITERATION" running "session:$(basename "$SESSION_LOG")"

    if ! enforce_mcp_manifest_stability; then
        status_write "$ITERATION" policy_denied "mcp_manifest_changed"
        results_log_append "$ITERATION" "$AGENT_ID" 0 0 "policy_denied" "mcp_manifest_changed"
        emit_iteration_failed "mcp_manifest_changed" "policy_denied" "mcp_manifest_changed" 0 0 0
        event_emit_kv iteration.completed status="policy_denied" description="mcp_manifest_changed" files_changed=0 commits=0 exit_code=0
        break
    fi

    rm -f "$DONE_FILE"

    set +e
    run_hook pre_iteration "$(hook_payload hook=pre_iteration session_log="$SESSION_LOG" prompt_file="$PROMPT_FILE")"
    PRE_HOOK_RC=$?
    set -e
    if [[ "$PRE_HOOK_RC" -ne 0 ]]; then
        log_warn "pre_iteration hook blocked iteration $ITERATION"
        status_write "$ITERATION" "policy_${HOOK_LAST_DECISION:-denied}" "pre_iteration:${HOOK_LAST_REASON:-blocked}"
        results_log_append "$ITERATION" "$AGENT_ID" 0 0 "policy_${HOOK_LAST_DECISION:-denied}" "pre_iteration:${HOOK_LAST_REASON:-blocked}"
        emit_iteration_failed "pre_iteration_${HOOK_LAST_DECISION:-denied}" "policy_${HOOK_LAST_DECISION:-denied}" "pre_iteration:${HOOK_LAST_REASON:-blocked}" 0 0 0
        event_emit_kv iteration.completed status="policy_${HOOK_LAST_DECISION:-denied}" description="pre_iteration:${HOOK_LAST_REASON:-blocked}" files_changed=0 commits=0 exit_code=0
        break
    fi
    if ! apply_hook_prompt_file_update; then
        status_write "$ITERATION" "policy_${HOOK_LAST_DECISION:-denied}" "pre_iteration:${HOOK_LAST_REASON:-blocked}"
        results_log_append "$ITERATION" "$AGENT_ID" 0 0 "policy_${HOOK_LAST_DECISION:-denied}" "pre_iteration:${HOOK_LAST_REASON:-blocked}"
        emit_iteration_failed "pre_iteration_${HOOK_LAST_DECISION:-denied}" "policy_${HOOK_LAST_DECISION:-denied}" "pre_iteration:${HOOK_LAST_REASON:-blocked}" 0 0 0
        event_emit_kv iteration.completed status="policy_${HOOK_LAST_DECISION:-denied}" description="pre_iteration:${HOOK_LAST_REASON:-blocked}" files_changed=0 commits=0 exit_code=0
        break
    fi
    [[ -f "$PROMPT_FILE" ]] || { log "ERROR: Prompt file not found at $PROMPT_FILE"; exit 1; }

    log "Running client $AGENTMILL_CLIENT (session log: $SESSION_LOG)..."
    PROMPT_CONTENT="$(cat "$PROMPT_FILE")"
    PROMPT_CONTENT="$(prepend_hook_additional_context "$PROMPT_CONTENT")"

    # Inject iteration context from previous run (Karpathy pattern: carry forward)
    if [[ "$ITERATION" -gt 1 ]]; then
        ITER_CTX="$(iteration_context)"
        PROMPT_CONTENT="$(cat "$ITER_CTX")

$PROMPT_CONTENT"
    fi

    event_emit_kv agent.started client="$AGENTMILL_CLIENT" session_log="$SESSION_LOG"
    set +e
    client_run_headless "$PROMPT_CONTENT" "$SESSION_LOG"
    CLAUDE_EXIT=$?
    set -e

    log "Client $AGENTMILL_CLIENT exited with code $CLAUDE_EXIT"

    DONE_SIGNALED=false
    COMPLETION_ACCEPTED=false
    if [[ -f "$DONE_FILE" ]]; then
        DONE_SIGNALED=true
        log "Agent signaled done"
    else
        log "WARN: Agent exited without signaling done"
    fi
    completion_gate_evaluate "${AGENTMILL_COMPLETION_GATE:-done_file}"
    COMPLETION_ACCEPTED="$COMPLETION_GATE_PASSED"
    if [[ "$COMPLETION_ACCEPTED" == true ]]; then
        set +e
        run_hook on_complete "$(hook_payload hook=on_complete gate="$COMPLETION_GATE_NAME" evidence="$COMPLETION_GATE_EVIDENCE" value="$COMPLETION_GATE_VALUE" threshold="$COMPLETION_GATE_THRESHOLD" session_log="$SESSION_LOG")"
        COMPLETE_HOOK_RC=$?
        set -e
        if [[ "$COMPLETE_HOOK_RC" -ne 0 ]]; then
            COMPLETION_ACCEPTED=false
            log_warn "on_complete hook rejected completion for iteration $ITERATION"
        fi
    fi
    client_emit_completed "$CLAUDE_EXIT" "$DONE_SIGNALED" "$COMPLETION_ACCEPTED" "$SESSION_LOG"
    record_usage_from_session "$ITERATION" "$AGENT_ID" "$SESSION_LOG"
    record_tool_events_from_session "$ITERATION" "$AGENT_ID" "$SESSION_LOG"
    SHELL_POLICY_RC=0
    set +e
    enforce_shell_command_policy_from_session "$SESSION_LOG"
    SHELL_POLICY_RC=$?
    set -e
    TOOL_CLASS_POLICY_RC=0
    set +e
    enforce_tool_class_policy_from_session "$SESSION_LOG"
    TOOL_CLASS_POLICY_RC=$?
    set -e
    event_emit_kv convergence.evaluated gate="$COMPLETION_GATE_NAME" passed="$COMPLETION_ACCEPTED" value="$COMPLETION_GATE_VALUE" threshold="$COMPLETION_GATE_THRESHOLD" evidence="$COMPLETION_GATE_EVIDENCE" hook_decision="${HOOK_LAST_DECISION:-allow}"
    convergence_log_append "$ITERATION" "$AGENT_ID" "$COMPLETION_GATE_NAME" "$COMPLETION_ACCEPTED" "$COMPLETION_GATE_VALUE" "$COMPLETION_GATE_THRESHOLD" "$COMPLETION_GATE_EVIDENCE" "${HOOK_LAST_DECISION:-allow}"

    # Capture iteration metrics for results log, including agent-created commits
    # and untracked files.
    ITER_FILES_CHANGED="$(iteration_changed_file_count "$ITER_HEAD_BEFORE")"

    set +e
    run_hook post_iteration "$(hook_payload hook=post_iteration exit_code="$CLAUDE_EXIT" done_signaled="$DONE_SIGNALED" completion_accepted="$COMPLETION_ACCEPTED" files_changed="$ITER_FILES_CHANGED" session_log="$SESSION_LOG")"
    POST_HOOK_RC=$?
    set -e
    WRITE_ROOT_RC=0
    if [[ "$POST_HOOK_RC" -eq 0 && "$SHELL_POLICY_RC" -eq 0 && "$TOOL_CLASS_POLICY_RC" -eq 0 ]]; then
        set +e
        enforce_write_root_policy
        WRITE_ROOT_RC=$?
        set -e
    fi
    HIGH_RISK_RC=0
    if [[ "$POST_HOOK_RC" -eq 0 && "$SHELL_POLICY_RC" -eq 0 && "$TOOL_CLASS_POLICY_RC" -eq 0 && "$WRITE_ROOT_RC" -eq 0 ]]; then
        set +e
        enforce_high_risk_change_policy
        HIGH_RISK_RC=$?
        set -e
    fi
    MERGE_POLICY_RC=0
    if [[ "$POST_HOOK_RC" -eq 0 && "$SHELL_POLICY_RC" -eq 0 && "$TOOL_CLASS_POLICY_RC" -eq 0 && "$WRITE_ROOT_RC" -eq 0 && "$HIGH_RISK_RC" -eq 0 ]]; then
        set +e
        enforce_git_merge_policy "$ITER_HEAD_BEFORE"
        MERGE_POLICY_RC=$?
        set -e
    fi
    PUSH_RC=0

    # Commit changes (controlled by AUTO_COMMIT)
    if [[ "$POST_HOOK_RC" -ne 0 ]]; then
        log_warn "post_iteration hook blocked commit/push for iteration $ITERATION"
    elif [[ "$SHELL_POLICY_RC" -ne 0 ]]; then
        log_warn "Shell command policy blocked commit/push for iteration $ITERATION"
    elif [[ "$TOOL_CLASS_POLICY_RC" -ne 0 ]]; then
        log_warn "Tool class policy blocked commit/push for iteration $ITERATION"
    elif [[ "$WRITE_ROOT_RC" -ne 0 ]]; then
        log_warn "Write-root policy blocked commit/push for iteration $ITERATION"
    elif [[ "$HIGH_RISK_RC" -ne 0 ]]; then
        log_warn "High-risk change policy blocked commit/push for iteration $ITERATION"
    elif [[ "$MERGE_POLICY_RC" -ne 0 ]]; then
        log_warn "Merge commit policy blocked commit/push for iteration $ITERATION"
    elif [[ -n "$(git status --porcelain)" ]]; then
        LAST_COMMIT_TIME="$(git log -1 --format='%ct' 2>/dev/null || echo 0)"
        AGENT_COMMITTED=false
        [[ "$LAST_COMMIT_TIME" -ge "$ITER_START_TIME" ]] 2>/dev/null && AGENT_COMMITTED=true

        case "$AUTO_COMMIT" in
            off) log "Auto-commit disabled." ;;
            wip)
                if [[ "$AGENT_COMMITTED" == true ]]; then
                    # Safety-net leftovers only
                    [[ -n "$(git status --porcelain)" ]] && { git add -A; git commit -m "[wip] agent-${AGENT_ID}: leftovers from iteration $ITERATION"; }
                else
                    git add -A; git commit -m "[wip] agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
                fi ;;
            on|*)
                git add -A; git commit -m "agent-${AGENT_ID}: iteration $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" ;;
        esac

        if [[ "$MULTI_AGENT" == true ]]; then
            if is_readonly_clone_mode; then
                export_readonly_clone_artifacts "$ITERATION"
            elif ! push_branch_with_retries "$AGENT_BRANCH"; then
                log "WARN: Skipping push for iteration $ITERATION"
                PUSH_RC=1
            fi
        fi
    else
        log "No changes to commit."
    fi

    # Log iteration results (Karpathy autoresearch pattern)
    ITER_COMMITS_AFTER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
    ITER_NEW_COMMITS=$((ITER_COMMITS_AFTER - ITER_COMMITS_BEFORE))
    ITER_STATUS="kept"
    [[ "$ITER_FILES_CHANGED" -eq 0 && "$ITER_NEW_COMMITS" -eq 0 ]] && ITER_STATUS="noop"
    [[ "$CLAUDE_EXIT" -ne 0 && "$COMPLETION_ACCEPTED" != true ]] && ITER_STATUS="error"
    [[ "$POST_HOOK_RC" -ne 0 ]] && ITER_STATUS="policy_${HOOK_LAST_DECISION:-denied}"
    [[ "$SHELL_POLICY_RC" -ne 0 ]] && ITER_STATUS="policy_denied"
    [[ "$TOOL_CLASS_POLICY_RC" -ne 0 ]] && ITER_STATUS="policy_denied"
    [[ "$WRITE_ROOT_RC" -ne 0 ]] && ITER_STATUS="policy_denied"
    [[ "$HIGH_RISK_RC" -ne 0 ]] && ITER_STATUS="policy_denied"
    [[ "$MERGE_POLICY_RC" -ne 0 ]] && ITER_STATUS="policy_denied"
    [[ "$PUSH_RC" -ne 0 ]] && ITER_STATUS="push_failed"
    ITER_DESC="exit=$CLAUDE_EXIT"
    [[ "$COMPLETION_ACCEPTED" == true ]] && ITER_DESC="done"
    [[ "$POST_HOOK_RC" -ne 0 ]] && ITER_DESC="post_iteration:${HOOK_LAST_REASON:-blocked}"
    [[ "$SHELL_POLICY_RC" -ne 0 ]] && ITER_DESC="shell_command_policy"
    [[ "$TOOL_CLASS_POLICY_RC" -ne 0 ]] && ITER_DESC="tool_class_policy"
    [[ "$WRITE_ROOT_RC" -ne 0 ]] && ITER_DESC="write_root_policy"
    [[ "$HIGH_RISK_RC" -ne 0 ]] && ITER_DESC="high_risk_changes"
    [[ "$MERGE_POLICY_RC" -ne 0 ]] && ITER_DESC="merge_commits_disallowed"
    [[ "$PUSH_RC" -ne 0 ]] && ITER_DESC="push_failed"
    if [[ "$ITER_NEW_COMMITS" -gt 0 ]]; then
        event_emit_kv commit.created count="$ITER_NEW_COMMITS" head="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    else
        event_emit_kv commit.skipped reason="no new commits"
    fi
    results_log_append "$ITERATION" "$AGENT_ID" "$ITER_FILES_CHANGED" "$ITER_NEW_COMMITS" "$ITER_STATUS" "$ITER_DESC" \
        "$USAGE_LAST_INPUT_TOKENS" "$USAGE_LAST_OUTPUT_TOKENS" "$USAGE_LAST_CACHE_CREATION_INPUT_TOKENS" "$USAGE_LAST_CACHE_READ_INPUT_TOKENS" "$USAGE_LAST_TOTAL_TOKENS" "$USAGE_LAST_COST_USD"
    status_write "$ITERATION" "$ITER_STATUS" "$ITER_DESC"
    if [[ "$CLAUDE_EXIT" -ne 0 && "$COMPLETION_ACCEPTED" != true ]]; then
        emit_iteration_failed "claude_exit" "$ITER_STATUS" "$ITER_DESC" "$CLAUDE_EXIT" "$ITER_FILES_CHANGED" "$ITER_NEW_COMMITS"
    elif [[ "$POST_HOOK_RC" -ne 0 ]]; then
        emit_iteration_failed "post_iteration_${HOOK_LAST_DECISION:-denied}" "$ITER_STATUS" "$ITER_DESC" "$CLAUDE_EXIT" "$ITER_FILES_CHANGED" "$ITER_NEW_COMMITS"
    elif [[ "$SHELL_POLICY_RC" -ne 0 ]]; then
        emit_iteration_failed "shell_command_policy" "$ITER_STATUS" "$ITER_DESC" "$CLAUDE_EXIT" "$ITER_FILES_CHANGED" "$ITER_NEW_COMMITS"
    elif [[ "$TOOL_CLASS_POLICY_RC" -ne 0 ]]; then
        emit_iteration_failed "tool_class_policy" "$ITER_STATUS" "$ITER_DESC" "$CLAUDE_EXIT" "$ITER_FILES_CHANGED" "$ITER_NEW_COMMITS"
    elif [[ "$WRITE_ROOT_RC" -ne 0 ]]; then
        emit_iteration_failed "write_root_policy" "$ITER_STATUS" "$ITER_DESC" "$CLAUDE_EXIT" "$ITER_FILES_CHANGED" "$ITER_NEW_COMMITS"
    elif [[ "$HIGH_RISK_RC" -ne 0 ]]; then
        emit_iteration_failed "high_risk_changes" "$ITER_STATUS" "$ITER_DESC" "$CLAUDE_EXIT" "$ITER_FILES_CHANGED" "$ITER_NEW_COMMITS"
    elif [[ "$MERGE_POLICY_RC" -ne 0 ]]; then
        emit_iteration_failed "merge_commits_disallowed" "$ITER_STATUS" "$ITER_DESC" "$CLAUDE_EXIT" "$ITER_FILES_CHANGED" "$ITER_NEW_COMMITS"
    elif [[ "$PUSH_RC" -ne 0 ]]; then
        emit_iteration_failed "push_failed" "$ITER_STATUS" "$ITER_DESC" "$CLAUDE_EXIT" "$ITER_FILES_CHANGED" "$ITER_NEW_COMMITS"
    fi
    event_emit_kv iteration.completed status="$ITER_STATUS" description="$ITER_DESC" files_changed="$ITER_FILES_CHANGED" commits="$ITER_NEW_COMMITS" exit_code="$CLAUDE_EXIT"

    if [[ "$COMPLETION_ACCEPTED" == true ]]; then
        event_emit_kv loop.stopped reason=completion gate="$COMPLETION_GATE_NAME"
        break
    fi

    if ! enforce_log_budget; then
        event_emit_kv loop.stopped reason=max_log_bytes max_log_bytes="$MAX_LOG_BYTES"
        break
    fi

    if ! enforce_usage_budget; then
        event_emit_kv loop.stopped reason="${USAGE_BUDGET_LAST_REASON:-usage_budget}"
        break
    fi

    # Check iteration limit
    if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
        log "Reached max iterations ($MAX_ITERATIONS). Stopping."
        event_emit_kv loop.stopped reason=max_iterations max_iterations="$MAX_ITERATIONS"
        break
    fi

    if [[ "$MAX_WALL_SECONDS" -gt 0 ]]; then
        RUN_ELAPSED_SECONDS=$(( $(date +%s) - RUN_START_TIME ))
        if [[ "$RUN_ELAPSED_SECONDS" -ge "$MAX_WALL_SECONDS" ]]; then
            log "Reached max wall-clock seconds ($MAX_WALL_SECONDS). Stopping."
            event_emit_kv budget.exhausted budget=wall_seconds elapsed_seconds="$RUN_ELAPSED_SECONDS" max_wall_seconds="$MAX_WALL_SECONDS"
            event_emit_kv loop.stopped reason=max_wall_seconds max_wall_seconds="$MAX_WALL_SECONDS"
            break
        fi
    fi

    # Brief pause before next iteration
    log "Sleeping ${LOOP_DELAY}s before next iteration..."
    sleep "$LOOP_DELAY"
done

log "Agent loop finished after $ITERATION iterations."
event_emit_kv run.completed iterations="$ITERATION"
