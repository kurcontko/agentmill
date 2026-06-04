#!/usr/bin/env bash
set -euo pipefail

# AgentMill TUI Mode — interactive or autonomous (Ralph Loop)
REPO_DIR="${REPO_DIR:-/workspace/repo}"
LOG_DIR="${LOG_DIR:-/workspace/logs}"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
MODEL="${MODEL:-sonnet}"
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"
DONE_FILE="${DONE_FILE:-/tmp/.agentmill-done}"
SENTINEL_SIGNAL_FLAG_FILE="${SENTINEL_SIGNAL_FLAG_FILE:-/tmp/.agentmill-sentinel-signal}"
AUTO_RALPH_MAX_ITERATIONS="${AUTO_RALPH_MAX_ITERATIONS:-${MAX_ITERATIONS:-10}}"
AUTO_RALPH_COMPLETION_PROMISE="${AUTO_RALPH_COMPLETION_PROMISE:-TASK_COMPLETE}"
MAX_WALL_SECONDS="${MAX_WALL_SECONDS:-0}"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-0}"
MAX_TOTAL_TOKENS="${MAX_TOTAL_TOKENS:-0}"
MAX_TOTAL_USD="${MAX_TOTAL_USD:-0}"
AGENTMILL_WORKSPACE_MODE="${AGENTMILL_WORKSPACE_MODE:-direct}"
AUTO_COMMIT="${AUTO_COMMIT:-}"

# shellcheck source=/entrypoint-common.sh
. "${AGENTMILL_ENTRYPOINT_COMMON:-/entrypoint-common.sh}"
apply_agent_env_overrides
client_select "${AGENTMILL_CLIENT:-${AGENTMILL_PROVIDER:-claude}}"

MODEL_RAW="$MODEL"
MODEL="$(client_resolve_model "$MODEL_RAW")"
export MODEL
[[ "$MODEL" != "$MODEL_RAW" ]] && log "Resolved MODEL '$MODEL_RAW' -> '$MODEL'"
client_version "$MODEL"

# log() provided by entrypoint-common.sh

client_require_auth
client_prepare_home
enforce_mcp_manifest_stability || exit 1
configure_git_identity "$GIT_USER" "$GIT_EMAIL"
memory_init
validate_runtime_policy tui || exit 1
RUN_START_TIME="$(date +%s)"

UPSTREAM_DIR="${UPSTREAM_DIR:-/workspace/upstream}"
if [[ -d "$UPSTREAM_DIR/.git" ]] || [[ -f "$UPSTREAM_DIR/HEAD" ]]; then
    REPO_DIR="${REPO_DIR}-${AGENT_ID:-tui}"
    : "${AGENT_BRANCH:=agent-${AGENT_ID:-tui}}"
    MULTI_AGENT=true

    log "Clone mode: ${AGENT_ID:-tui} on branch ${AGENT_BRANCH}"
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
        git rebase "$UPSTREAM_HEAD" 2>/dev/null || git rebase --abort
    else
        git checkout -b "$AGENT_BRANCH" "$UPSTREAM_HEAD"
    fi
elif [[ -d "$REPO_DIR/.git" ]] || [[ -f "$REPO_DIR/.git" ]]; then
    MULTI_AGENT=false
    : "${AGENT_BRANCH:=main}"
    cd "$REPO_DIR"
else
    log "ERROR: No repo at $REPO_DIR or /workspace/upstream"
    exit 1
fi

log "Repo ready at $REPO_DIR"
enforce_workspace_isolation "$MULTI_AGENT" || exit 1
enforce_git_branch_policy "$MULTI_AGENT" || exit 1
AGENTMILL_BASE_SHA="${AGENTMILL_BASE_SHA:-$(git rev-parse HEAD 2>/dev/null || echo HEAD)}"
export AGENTMILL_BASE_SHA
if [[ -z "$AUTO_COMMIT" ]]; then
    if [[ "${AGENTMILL_PROFILE_LEVEL:-trusted}" == "trusted" ]]; then
        AUTO_COMMIT="wip"
    else
        AUTO_COMMIT="off"
    fi
fi

prepare_repo_environment "$REPO_DIR"
event_emit_kv run.configured \
    mode=tui \
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
    auto_ralph="${AUTO_RALPH:-false}" \
    respawn="${RESPAWN:-false}" \
    max_wall_seconds="$MAX_WALL_SECONDS" \
    max_log_bytes="$MAX_LOG_BYTES" \
    max_total_tokens="$MAX_TOTAL_TOKENS" \
    max_total_usd="$MAX_TOTAL_USD" \
    branch="$AGENT_BRANCH" \
    base_sha="$AGENTMILL_BASE_SHA" \
    multi_agent="$MULTI_AGENT" \
    workspace_mode="$AGENTMILL_WORKSPACE_MODE" \
    auto_commit="$AUTO_COMMIT" \
    repo_dir="$REPO_DIR"
status_write 0 starting "configured" "${MAX_ITERATIONS:-0}"

RALPH_RULE_FILE=".claude/rules/agentmill-ralph-task.md"
client_prepare_project "$REPO_DIR"

restore_settings() { client_cleanup; rm -f "$RALPH_RULE_FILE"; }
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

BASE_INITIAL_PROMPT="$INITIAL_PROMPT"
if [[ -n "$BASE_INITIAL_PROMPT" ]]; then
    log "Starting session with prompt from $PROMPT_FILE."
    export CLAUDE_INITIAL_PROMPT="$BASE_INITIAL_PROMPT"
else
    unset CLAUDE_INITIAL_PROMPT
fi

while true; do
    ITERATION=$((ITERATION + 1))
    ITER_COMMITS_BEFORE="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
    ITER_HEAD_BEFORE="$(git rev-parse HEAD 2>/dev/null || echo HEAD)"
    log "Launching $AGENTMILL_CLIENT TUI (model=$MODEL, iteration=$ITERATION)"
    event_emit_kv iteration.started mode=tui client="$AGENTMILL_CLIENT" prompt_file="$PROMPT_FILE"
    status_write "$ITERATION" running "tui"

    if ! enforce_mcp_manifest_stability; then
        status_write "$ITERATION" policy_denied "mcp_manifest_changed"
        emit_iteration_failed "mcp_manifest_changed" "policy_denied" "mcp_manifest_changed" 0 "" 0
        event_emit_kv iteration.completed mode=tui status="policy_denied" reason="mcp_manifest_changed" commits=0
        break
    fi

    rm -f "$DONE_FILE" "$SENTINEL_SIGNAL_FLAG_FILE"

    set +e
    run_hook pre_iteration "$(hook_payload hook=pre_iteration mode=tui prompt_file="$PROMPT_FILE")"
    PRE_HOOK_RC=$?
    set -e
    if [[ "$PRE_HOOK_RC" -ne 0 ]]; then
        log_warn "pre_iteration hook blocked TUI iteration $ITERATION"
        status_write "$ITERATION" "policy_${HOOK_LAST_DECISION:-denied}" "pre_iteration:${HOOK_LAST_REASON:-blocked}"
        emit_iteration_failed "pre_iteration_${HOOK_LAST_DECISION:-denied}" "policy_${HOOK_LAST_DECISION:-denied}" "pre_iteration:${HOOK_LAST_REASON:-blocked}" 0 "" 0
        event_emit_kv iteration.completed mode=tui status="policy_${HOOK_LAST_DECISION:-denied}" reason="${HOOK_LAST_REASON:-blocked}" commits=0
        break
    fi
    if ! apply_hook_prompt_file_update; then
        status_write "$ITERATION" "policy_${HOOK_LAST_DECISION:-denied}" "pre_iteration:${HOOK_LAST_REASON:-blocked}"
        emit_iteration_failed "pre_iteration_${HOOK_LAST_DECISION:-denied}" "policy_${HOOK_LAST_DECISION:-denied}" "pre_iteration:${HOOK_LAST_REASON:-blocked}" 0 "" 0
        event_emit_kv iteration.completed mode=tui status="policy_${HOOK_LAST_DECISION:-denied}" reason="${HOOK_LAST_REASON:-blocked}" commits=0
        break
    fi
    if [[ "${SKIP_PROMPT:-false}" != "true" && "${AUTO_RALPH:-false}" != "true" && -f "$PROMPT_FILE" ]]; then
        BASE_INITIAL_PROMPT="$(cat "$PROMPT_FILE")"
    fi

    ITER_INITIAL_PROMPT="$(prepend_hook_additional_context "$BASE_INITIAL_PROMPT")"
    if [[ -n "$ITER_INITIAL_PROMPT" ]]; then
        export CLAUDE_INITIAL_PROMPT="$ITER_INITIAL_PROMPT"
    else
        unset CLAUDE_INITIAL_PROMPT
    fi

    start_sentinel_watcher "$$" process_group
    start_wall_clock_watcher "$$" process_group

    event_emit_kv agent.started mode=tui client="$AGENTMILL_CLIENT"
    SESSION_LOG=""
    client_run_tui
    SESSION_LOG="${CLIENT_LAST_SESSION_LOG:-}"

    stop_sentinel_watcher
    stop_wall_clock_watcher

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
        run_hook on_complete "$(hook_payload hook=on_complete mode=tui gate="$COMPLETION_GATE_NAME" evidence="$COMPLETION_GATE_EVIDENCE" value="$COMPLETION_GATE_VALUE" threshold="$COMPLETION_GATE_THRESHOLD" session_log="$SESSION_LOG")"
        COMPLETE_HOOK_RC=$?
        set -e
        if [[ "$COMPLETE_HOOK_RC" -ne 0 ]]; then
            COMPLETION_ACCEPTED=false
            log_warn "on_complete hook rejected TUI completion for iteration $ITERATION"
        fi
    fi
    client_emit_completed "" "$DONE_SIGNALED" "$COMPLETION_ACCEPTED" "$SESSION_LOG"
    if [[ -n "$SESSION_LOG" && -f "$SESSION_LOG" ]]; then
        record_tool_events_from_session "$ITERATION" "${AGENT_ID:-tui}" "$SESSION_LOG"
    fi
    SHELL_POLICY_RC=0
    if [[ -n "$SESSION_LOG" && -f "$SESSION_LOG" ]]; then
        set +e
        enforce_shell_command_policy_from_session "$SESSION_LOG"
        SHELL_POLICY_RC=$?
        set -e
    fi
    TOOL_CLASS_POLICY_RC=0
    if [[ -n "$SESSION_LOG" && -f "$SESSION_LOG" ]]; then
        set +e
        enforce_tool_class_policy_from_session "$SESSION_LOG"
        TOOL_CLASS_POLICY_RC=$?
        set -e
    fi
    event_emit_kv convergence.evaluated gate="$COMPLETION_GATE_NAME" passed="$COMPLETION_ACCEPTED" value="$COMPLETION_GATE_VALUE" threshold="$COMPLETION_GATE_THRESHOLD" evidence="$COMPLETION_GATE_EVIDENCE" hook_decision="${HOOK_LAST_DECISION:-allow}"
    convergence_log_append "$ITERATION" "${AGENT_ID:-tui}" "$COMPLETION_GATE_NAME" "$COMPLETION_ACCEPTED" "$COMPLETION_GATE_VALUE" "$COMPLETION_GATE_THRESHOLD" "$COMPLETION_GATE_EVIDENCE" "${HOOK_LAST_DECISION:-allow}"

    set +e
    run_hook post_iteration "$(hook_payload hook=post_iteration mode=tui done_signaled="$DONE_SIGNALED" completion_accepted="$COMPLETION_ACCEPTED" session_log="$SESSION_LOG")"
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

    if [[ "$POST_HOOK_RC" -ne 0 ]]; then
        log_warn "post_iteration hook blocked TUI commit for iteration $ITERATION"
    elif [[ "$SHELL_POLICY_RC" -ne 0 ]]; then
        log_warn "Shell command policy blocked TUI commit for iteration $ITERATION"
    elif [[ "$TOOL_CLASS_POLICY_RC" -ne 0 ]]; then
        log_warn "Tool class policy blocked TUI commit for iteration $ITERATION"
    elif [[ "$WRITE_ROOT_RC" -ne 0 ]]; then
        log_warn "Write-root policy blocked TUI commit for iteration $ITERATION"
    elif [[ "$HIGH_RISK_RC" -ne 0 ]]; then
        log_warn "High-risk change policy blocked TUI commit for iteration $ITERATION"
    elif [[ "$MERGE_POLICY_RC" -ne 0 ]]; then
        log_warn "Merge commit policy blocked TUI commit for iteration $ITERATION"
    elif [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        case "$AUTO_COMMIT" in
            off)
                log "Auto-commit disabled."
                ;;
            wip)
                git add -A
                git commit -m "[wip] tui session $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" || true
                ;;
            on)
                git add -A
                git commit -m "tui session $ITERATION ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" || true
                ;;
            *)
                log_error "Invalid AUTO_COMMIT mode for TUI: $AUTO_COMMIT"
                event_emit_kv policy.denied reason=invalid_auto_commit mode=tui auto_commit="$AUTO_COMMIT"
                POST_HOOK_RC=1
                ;;
        esac
    fi
    if [[ "$POST_HOOK_RC" -eq 0 && "$SHELL_POLICY_RC" -eq 0 && "$TOOL_CLASS_POLICY_RC" -eq 0 && "$WRITE_ROOT_RC" -eq 0 && "$HIGH_RISK_RC" -eq 0 && "$MERGE_POLICY_RC" -eq 0 && "$MULTI_AGENT" == true ]] && is_readonly_clone_mode; then
        export_readonly_clone_artifacts "$ITERATION"
    fi
    ITER_COMMITS_AFTER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
    ITER_NEW_COMMITS=$((ITER_COMMITS_AFTER - ITER_COMMITS_BEFORE))
    if [[ "$ITER_NEW_COMMITS" -gt 0 ]]; then
        event_emit_kv commit.created count="$ITER_NEW_COMMITS" head="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    else
        event_emit_kv commit.skipped reason="no new commits"
    fi
    ITER_STATUS="kept"
    [[ "$POST_HOOK_RC" -ne 0 ]] && ITER_STATUS="policy_${HOOK_LAST_DECISION:-denied}"
    [[ "$SHELL_POLICY_RC" -ne 0 ]] && ITER_STATUS="policy_denied"
    [[ "$TOOL_CLASS_POLICY_RC" -ne 0 ]] && ITER_STATUS="policy_denied"
    [[ "$WRITE_ROOT_RC" -ne 0 ]] && ITER_STATUS="policy_denied"
    [[ "$HIGH_RISK_RC" -ne 0 ]] && ITER_STATUS="policy_denied"
    [[ "$MERGE_POLICY_RC" -ne 0 ]] && ITER_STATUS="policy_denied"
    if [[ "$POST_HOOK_RC" -ne 0 ]]; then
        emit_iteration_failed "post_iteration_${HOOK_LAST_DECISION:-denied}" "$ITER_STATUS" "post_iteration:${HOOK_LAST_REASON:-blocked}" 0 "" "$ITER_NEW_COMMITS"
    elif [[ "$SHELL_POLICY_RC" -ne 0 ]]; then
        emit_iteration_failed "shell_command_policy" "$ITER_STATUS" "shell_command_policy" 0 "" "$ITER_NEW_COMMITS"
    elif [[ "$TOOL_CLASS_POLICY_RC" -ne 0 ]]; then
        emit_iteration_failed "tool_class_policy" "$ITER_STATUS" "tool_class_policy" 0 "" "$ITER_NEW_COMMITS"
    elif [[ "$WRITE_ROOT_RC" -ne 0 ]]; then
        emit_iteration_failed "write_root_policy" "$ITER_STATUS" "write_root_policy" 0 "" "$ITER_NEW_COMMITS"
    elif [[ "$HIGH_RISK_RC" -ne 0 ]]; then
        emit_iteration_failed "high_risk_changes" "$ITER_STATUS" "high_risk_changes" 0 "" "$ITER_NEW_COMMITS"
    elif [[ "$MERGE_POLICY_RC" -ne 0 ]]; then
        emit_iteration_failed "merge_commits_disallowed" "$ITER_STATUS" "merge_commits_disallowed" 0 "" "$ITER_NEW_COMMITS"
    fi
    event_emit_kv iteration.completed mode=tui status="$ITER_STATUS" done_signaled="$DONE_SIGNALED" completion_accepted="$COMPLETION_ACCEPTED" commits="$ITER_NEW_COMMITS"
    status_write "$ITERATION" "$ITER_STATUS" "done=$DONE_SIGNALED completion=$COMPLETION_ACCEPTED" "${MAX_ITERATIONS:-0}"

    if [[ "$COMPLETION_ACCEPTED" == true ]]; then
        event_emit_kv loop.stopped reason=completion gate="$COMPLETION_GATE_NAME" mode=tui
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

    if [[ "$RESPAWN" != "true" ]]; then
        log "Respawn disabled. Exiting."
        event_emit_kv loop.stopped reason=respawn_disabled
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

    if [[ "$SHUTTING_DOWN" == true ]]; then
        log "Shutdown requested. Exiting."
        event_emit_kv loop.stopped reason=shutdown
        break
    fi

    log "Client $AGENTMILL_CLIENT exited. Restarting in ${LOOP_DELAY}s..."
    sleep "$LOOP_DELAY"
done

event_emit_kv run.completed iterations="$ITERATION"
