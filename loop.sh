#!/usr/bin/env bash
set -euo pipefail

# AgentMill — run an agent CLI against a repo in a respawning loop.
# Fresh context every iteration; the repo (PROGRESS.md + git history) is the memory.

AGENT="${AGENT:-claude}"                 # claude | codex
MODEL="${MODEL:-}"                       # blank = the CLI's own default
FALLBACK_MODEL="${FALLBACK_MODEL:-}"     # claude only: --fallback-model when MODEL is overloaded
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"   # framework prompt (how to work)
REPO_DIR="${REPO_DIR:-/workspace/repo}"
MISSION_FILE="${MISSION_FILE:-$REPO_DIR/MILL.md}"  # the repo's mission (what to do)
LOG_DIR="${LOG_DIR:-/workspace/logs}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"    # 0 = unbounded
MAX_ERRORS="${MAX_ERRORS:-3}"            # consecutive agent failures before giving up (0 = unbounded)
MAX_NOOPS="${MAX_NOOPS:-3}"              # consecutive no-progress iterations before stopping (0 = unbounded)
ITER_TIMEOUT="${ITER_TIMEOUT:-3600}"     # seconds per iteration
LOOP_DELAY="${LOOP_DELAY:-5}"            # seconds between iterations
ERROR_BACKOFF="${ERROR_BACKOFF:-30}"     # backoff base after a failure
MAX_BACKOFF="${MAX_BACKOFF:-900}"        # cap on the error backoff
SHUTDOWN_GRACE="${SHUTDOWN_GRACE:-30}"   # seconds a signalled agent gets before SIGKILL
MAX_TURNS="${MAX_TURNS:-0}"              # claude only: --max-turns per session (0 = unbounded)
MAX_BUDGET_USD="${MAX_BUDGET_USD:-}"     # claude only: --max-budget-usd per session (empty = none)
MAX_TOTAL_BUDGET_USD="${MAX_TOTAL_BUDGET_USD:-}"  # loop-wide spend cap in USD (empty = none)
MIN_TURNS="${MIN_TURNS:-2}"              # fewer turns than this with no repo change = broken agent
DONE_PROMISE="${DONE_PROMISE:-TASK_COMPLETE}"
SETUP_CMD="${SETUP_CMD:-}"               # runs once before the loop
CHECK_CMD="${CHECK_CMD:-}"               # ratchet: iteration is reverted if this fails
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"

[[ "$ITER_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
    || { echo "FATAL: ITER_TIMEOUT must be a positive integer" >&2; exit 1; }
[[ "$SHUTDOWN_GRACE" =~ ^[0-9]+$ ]] \
    || { echo "FATAL: SHUTDOWN_GRACE must be a non-negative integer" >&2; exit 1; }
# GNU timeout treats a zero --kill-after duration as disabled. Preserve zero's
# external-shutdown meaning (kill immediately), but keep timeout escalation on.
TIMEOUT_KILL_AFTER="$SHUTDOWN_GRACE"
[[ "$TIMEOUT_KILL_AFTER" -gt 0 ]] || TIMEOUT_KILL_AFTER=1

# GNU timeout is always present in the container; degrade without it (host tests).
# Its normal (non-foreground) mode owns a process group, so TERM and the hard
# kill deadline cover the CLI and every descendant, not only the direct child.
if timeout --kill-after=1 1 true >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout "--kill-after=$TIMEOUT_KILL_AFTER" "$ITER_TIMEOUT")
elif timeout -k 1 1 true >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout -k "$TIMEOUT_KILL_AFTER" "$ITER_TIMEOUT")
else
    TIMEOUT_CMD=(env)
fi

log() { printf '[%s] %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
die() { log "FATAL: $*"; exit 1; }

# Job control gives the loop wrapper and its timed CLI session distinct process
# groups, allowing each layer to enforce a bounded descendant-group shutdown.
set -m
SHUTDOWN=false
AGENT_PID=""
WATCHDOG_PID=""
on_signal() {
    log "shutdown requested — stopping the current agent session"
    SHUTDOWN=true
    [[ -n "$AGENT_PID" && -z "$WATCHDOG_PID" ]] || return 0
    kill -TERM -- "-$AGENT_PID" 2>/dev/null || kill -TERM "$AGENT_PID" 2>/dev/null || true
    # An agent that ignores TERM is killed after the grace period; the loop
    # keeps waiting for it either way (see wait_agent).
    # run_agent has its own descendant-group watchdog. This outer deadline is
    # slightly later, giving that wrapper time to reap the group and return.
    { sleep "$((SHUTDOWN_GRACE + 2))"; kill -KILL -- "-$AGENT_PID" 2>/dev/null; } &
    WATCHDOG_PID=$!
}
trap on_signal TERM INT

# Wait for the backgrounded agent. A trap interrupts `wait`, which then
# returns 128+signal while the agent is still running; keep waiting until it
# has really exited so commit/check/revert never race a live agent.
wait_agent() {
    rc=0
    until wait "$AGENT_PID"; do
        rc=$?
        kill -0 "$AGENT_PID" 2>/dev/null || break
        rc=0
    done
    if [[ -n "$WATCHDOG_PID" ]]; then
        kill -- "-$WATCHDOG_PID" 2>/dev/null || kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        WATCHDOG_PID=""
    fi
    AGENT_PID=""
}

# Interruptible sleep: a foreground `sleep` defers the TERM/INT trap until it
# ends, so a shutdown during LOOP_DELAY or the error backoff would start one
# more full agent session. Backgrounded, the trap runs at once.
pause() {
    local pid
    sleep "$1" &
    pid=$!
    wait "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

[[ -e "$REPO_DIR/.git" ]] || die "no git repo at $REPO_DIR (mount one)"
[[ -f "$PROMPT_FILE" ]] || die "no prompt file at $PROMPT_FILE"
[[ -f "$MISSION_FILE" ]] || die "no mission file at $MISSION_FILE (mill init)"
case "$AGENT" in
    claude) [[ -n "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] \
                || die "set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN" ;;
    codex)  [[ -n "${OPENAI_API_KEY:-}" || -d "$HOME/.codex" ]] \
                || die "set OPENAI_API_KEY or mount ~/.codex" ;;
    *) die "AGENT must be claude or codex, got: $AGENT" ;;
esac

cd "$REPO_DIR"
mkdir -p "$LOG_DIR"
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
# A linked worktree's objects live in the main repo's git dir, mounted at the
# same host path; mark that trusted too or every git command fails. Parsed from
# the .git file rather than asked of git, which would itself refuse first.
if [[ -f "$REPO_DIR/.git" ]]; then
    git_common_dir="$(sed -n 's/^gitdir: *//p' "$REPO_DIR/.git" | head -1)"
    git_common_dir="${git_common_dir%/worktrees/*}"
    [[ -z "$git_common_dir" ]] \
        || git config --global --add safe.directory "$git_common_dir" 2>/dev/null || true
fi
# Identity via the environment, not `git config`: the repo is a bind mount, so
# a repo-local setting would outlive the container and shadow the host user's
# global identity (for a worktree, in every checkout of that repo).
export GIT_AUTHOR_NAME="$GIT_USER" GIT_COMMITTER_NAME="$GIT_USER"
export GIT_AUTHOR_EMAIL="$GIT_EMAIL" GIT_COMMITTER_EMAIL="$GIT_EMAIL"

WORKTREE_STATUS=""
refresh_worktree_status() {
    # Capture the exit status explicitly. A failing command substitution inside
    # `[[ -z ... ]]` otherwise looks exactly like an empty (clean) checkout.
    if ! WORKTREE_STATUS="$(git status --porcelain --untracked-files=all)"; then
        die "could not read repository status at $REPO_DIR"
    fi
}

require_clean_worktree() {
    local reason="$1"
    refresh_worktree_status
    [[ -z "$WORKTREE_STATUS" ]] \
        || die "$reason — commit or stash tracked, staged, and untracked changes first"
}

# A failed CHECK_CMD reverts the whole worktree, which would take pre-existing
# uncommitted work with it. Refuse rather than destroy someone's edits.
require_clean_worktree "$REPO_DIR has uncommitted changes"

if [[ -n "$SETUP_CMD" ]]; then
    log "setup: $SETUP_CMD"
    bash -c "$SETUP_CMD" || die "SETUP_CMD failed"
    require_clean_worktree "SETUP_CMD left the checkout dirty"
fi

# Minimal carry-forward between fresh contexts: recent history + the agent's
# own progress file. Everything else the agent reads from the repo itself.
preamble() {
    echo "<loop-context>"
    echo "You are iteration $iter of an autonomous loop. Recent commits:"
    git log --oneline -5 2>/dev/null || echo "(no commits yet)"
    if [[ -f PROGRESS.md ]]; then
        printf '\nPROGRESS.md:\n'
        head -40 PROGRESS.md
    fi
    echo "</loop-context>"
}

# The mission is re-read from the checkout every iteration, so editing
# MILL.md steers a running loop. Its frontmatter (settings) is mill's
# business and was applied at start; only the body is handed to the agent.
mission_body() {
    awk 'NR == 1 && $0 == "---" { fm = 1; next }
         fm && $0 == "---"     { fm = 0; next }
         !fm' "$MISSION_FILE"
}

MISSION_SUM=""
note_mission_changes() {
    local sum
    sum="$(cksum < "$MISSION_FILE" 2>/dev/null || true)"
    [[ -z "$MISSION_SUM" || "$sum" == "$MISSION_SUM" ]] \
        || log "$(basename "$MISSION_FILE") changed since the last iteration"
    MISSION_SUM="$sum"
}

build_prompt() {
    printf '%s\n\n%s\n\n<mission>\n%s\n</mission>\n' \
        "$(preamble)" "$(cat "$PROMPT_FILE")" "$(mission_body)"
}

# State used inside run_agent's background subshell. The timed command is
# itself backgrounded so this subshell handles TERM immediately while waiting.
SESSION_PID=""
SESSION_WATCHDOG_PID=""
SESSION_RC=0
SESSION_STOP_REQUESTED=false
on_session_signal() {
    SESSION_STOP_REQUESTED=true
    [[ -n "$SESSION_PID" && -z "$SESSION_WATCHDOG_PID" ]] || return 0
    kill -TERM -- "-$SESSION_PID" 2>/dev/null || kill -TERM "$SESSION_PID" 2>/dev/null || true
    { sleep "$SHUTDOWN_GRACE"; kill -KILL -- "-$SESSION_PID" 2>/dev/null; } &
    SESSION_WATCHDOG_PID=$!
}

wait_session() {
    SESSION_RC=0
    until wait "$SESSION_PID"; do
        SESSION_RC=$?
        kill -0 "$SESSION_PID" 2>/dev/null || break
        SESSION_RC=0
    done
    if [[ -n "$SESSION_WATCHDOG_PID" ]]; then
        if kill -0 -- "-$SESSION_PID" 2>/dev/null; then
            # timeout may have exited before one of its descendants. Do not let
            # the wrapper return until the bounded group kill has completed.
            wait "$SESSION_WATCHDOG_PID" 2>/dev/null || true
        else
            kill -- "-$SESSION_WATCHDOG_PID" 2>/dev/null \
                || kill "$SESSION_WATCHDOG_PID" 2>/dev/null || true
            wait "$SESSION_WATCHDOG_PID" 2>/dev/null || true
        fi
        SESSION_WATCHDOG_PID=""
    fi
    SESSION_PID=""
}

# One jq pass over claude's stream-json log: the metrics of the last result
# event as a tab-separated line, then the final message. A run without a
# result event prints nothing at all, which the loop reads as "unknown".
# shellcheck disable=SC2016  # jq program: $r and $ev are jq's, not the shell's
CLAUDE_RESULT_JQ='
  ([inputs | fromjson? | select(.type == "result")] | last) as $r
  | if $r == null then empty else
      ([ ($r.subtype // ""), (($r.is_error // false) | tostring),
         (($r.total_cost_usd // 0) | tostring), (($r.num_turns // "") | tostring),
         (($r.duration_ms // 0) | tostring),
         (($r.usage.input_tokens // "") | tostring),
         (($r.usage.output_tokens // "") | tostring) ] | @tsv),
      ($r.result // "")
    end'

# The same for codex --json (JSONL, no cost reported): usage comes from the
# final turn.completed, turns are the completed items, and an error event or a
# turn that never completed marks the session failed.
# shellcheck disable=SC2016  # jq program, not shell expansion
CODEX_RESULT_JQ='
  [inputs | fromjson?] as $ev
  | if ($ev | length) == 0 then empty else
      ($ev | map(select(.type == "turn.completed")) | last) as $done
      | ($ev | any(.type == "error")) as $err
      | ($ev | map(select(.type == "item.completed"
                          and ((.item.type // "") | test("agent_message|command_execution|file_change|mcp_tool_call|web_search"))))
             | length) as $turns
      | ($err or ($done == null)) as $failed
      | [ (if $failed then "error" else "success" end), ($failed | tostring),
          "0", ($turns | tostring), "0",
          (($done.usage.input_tokens // "") | tostring),
          (($done.usage.output_tokens // "") | tostring) ] | @tsv
    end'

# Runs one agent session. Prints the agent's final message; exit code is the
# agent's. Full event stream goes to the iteration log, session metrics (one
# tab-separated line, empty when unparseable) to $metrics_file.
run_agent() {
    local rc=0 model_args=()
    SESSION_PID="" SESSION_WATCHDOG_PID="" SESSION_RC=0 SESSION_STOP_REQUESTED=false
    : > "$metrics_file"
    trap on_session_signal TERM INT
    case "$AGENT" in
        claude)
            [[ -n "$MODEL" ]] && model_args=(--model "$MODEL")
            [[ -n "$FALLBACK_MODEL" ]] && model_args+=(--fallback-model "$FALLBACK_MODEL")
            [[ "$MAX_TURNS" -gt 0 ]] && model_args+=(--max-turns "$MAX_TURNS")
            [[ -n "$MAX_BUDGET_USD" ]] && model_args+=(--max-budget-usd "$MAX_BUDGET_USD")
            "${TIMEOUT_CMD[@]}" claude -p "$1" \
                --dangerously-skip-permissions \
                ${model_args[@]+"${model_args[@]}"} \
                --output-format stream-json --verbose >>"$iter_log" 2>&1 &
            SESSION_PID=$!
            [[ "$SESSION_STOP_REQUESTED" == false ]] || on_session_signal
            wait_session
            rc="$SESSION_RC"
            jq -Rnr "$CLAUDE_RESULT_JQ" "$iter_log" >"$parse_file" 2>/dev/null || : > "$parse_file"
            head -1 "$parse_file" > "$metrics_file"
            tail -n +2 "$parse_file"
            ;;
        codex)
            [[ -n "$MODEL" ]] && model_args=(-m "$MODEL")
            # MAX_TURNS/MAX_BUDGET_USD have no codex equivalent; ignored, not an error.
            # Truncate first: a run that exits without a final message would
            # otherwise replay the previous iteration's (maybe DONE_PROMISE).
            : > "$codex_msg"
            "${TIMEOUT_CMD[@]}" codex exec "$1" \
                --dangerously-bypass-approvals-and-sandbox \
                ${model_args[@]+"${model_args[@]}"} -C "$REPO_DIR" --json \
                -o "$codex_msg" >>"$iter_log" 2>&1 &
            SESSION_PID=$!
            [[ "$SESSION_STOP_REQUESTED" == false ]] || on_session_signal
            wait_session
            rc="$SESSION_RC"
            jq -Rnr "$CODEX_RESULT_JQ" "$iter_log" >"$metrics_file" 2>/dev/null \
                || : > "$metrics_file"
            cat "$codex_msg" 2>/dev/null || true
            ;;
    esac
    return "$rc"
}

# Return the current commit, or an empty string for an unborn HEAD.
head_oid() {
    git rev-parse --verify HEAD 2>/dev/null || true
}

repo_mutated() {
    refresh_worktree_status
    [[ "$(head_oid)" != "$start_ref" || -n "$WORKTREE_STATUS" ]]
}

count_iteration_commits() {
    local count=""
    if [[ -n "$start_ref" ]]; then
        count="$(git rev-list --count "${start_ref}..HEAD" 2>/dev/null)" || count=0
    else
        count="$(git rev-list --count HEAD 2>/dev/null)" || count=0
    fi
    printf '%s' "${count:-0}"
}

# Session metrics from run_agent's tab-separated line. Every field may be
# empty ("unknown"); nothing here is allowed to abort the loop.
read_metrics() {
    m_subtype="" m_is_error="" m_cost="" m_turns="" m_duration_ms="" m_tokens_in="" m_tokens_out=""
    [[ -s "$metrics_file" ]] || return 0
    IFS=$'\t' read -r m_subtype m_is_error m_cost m_turns m_duration_ms m_tokens_in m_tokens_out \
        < "$metrics_file" || true
    [[ "$m_turns" =~ ^[0-9]+$ ]] || m_turns=""
    [[ "$m_tokens_in" =~ ^[0-9]+$ ]] || m_tokens_in=""
    [[ "$m_tokens_out" =~ ^[0-9]+$ ]] || m_tokens_out=""
    [[ "$m_cost" =~ ^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] || m_cost=""
}

# Money is floating point; the shell only does integers, so awk does the sums
# and comparisons (bc is not installed in the image).
add_cost() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6f", a + b }'; }
fmt_cost() { awk -v a="$1" 'BEGIN { printf "%.2f", a }'; }
cost_reached() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }

# A human-readable digest of one iteration, next to its raw log: what the
# session cost, what it committed, and what it said at the end.
write_summary() {
    local range=""
    [[ "$new_commits" -gt 0 ]] && range="${start_ref:+$start_ref..}HEAD"
    {
        printf 'iteration: %s\nstatus: %s\nsubtype: %s\ncost_usd: %s\nturns: %s\nduration_s: %s (agent reported %sms)\n' \
            "$iter" "$status" "${m_subtype:-unknown}" "$(fmt_cost "$cost")" \
            "${m_turns:-unknown}" "$duration_s" "${m_duration_ms:-0}"
        printf '\ncommits (%s):\n' "$new_commits"
        [[ -z "$range" ]] || git log --oneline "$range" 2>/dev/null || true
        printf '\nfiles changed:\n'
        [[ -z "$range" ]] || git diff --stat "$range" 2>/dev/null || true
        printf '\nfinal message:\n%s\n' "$last_msg"
    } > "${iter_log%.log}.summary" 2>/dev/null || true
}

# Restore every initialized submodule to the commit recorded by the current
# superproject, then discard tracked and untracked changes at every depth.
restore_submodules() {
    # Clean first so an untracked path cannot block checkout of the recorded
    # commit, then clean again after the recursive update at the restored tree.
    git submodule foreach -q --recursive \
        'git reset -q --hard && git clean -q -ffd'
    git submodule sync -q --recursive
    git submodule update -q --recursive --force
    git submodule foreach -q --recursive \
        'git reset -q --hard && git clean -q -ffd'
}

# Undo everything the iteration did, including untracked files it left behind.
restore_iteration() {
    if [[ -n "$start_ref" ]]; then
        if [[ -n "$start_head_ref" ]]; then
            git symbolic-ref HEAD "$start_head_ref"
        else
            git update-ref --no-deref HEAD "$start_ref"
        fi
        git reset -q --hard "$start_ref"
        restore_submodules
    else
        # Clear the index/worktree before deleting the first commit and
        # restoring the original unborn branch name.
        git read-tree --empty
        git clean -q -ffd
        if [[ -n "$start_head_ref" ]]; then
            git symbolic-ref HEAD "$start_head_ref"
            git update-ref -d "$start_head_ref"
        fi
    fi
    git clean -q -ffd
}

log "starting loop: agent=$AGENT model=${MODEL:-<cli default>} max_iterations=$MAX_ITERATIONS"
results_log="$LOG_DIR/results.jsonl"
codex_msg="$LOG_DIR/.codex-last-msg"
msg_file="$LOG_DIR/.last-msg"
metrics_file="$LOG_DIR/.last-metrics"
parse_file="$LOG_DIR/.last-parse"
iter=0 errors=0 noops=0 stop_reason="" total_cost=0

while true; do
    if [[ "$SHUTDOWN" == true ]]; then stop_reason="shutdown signal"; break; fi
    iter=$((iter + 1))
    # --verify so an unborn HEAD leaves start_ref empty instead of the literal "HEAD".
    start_ref="$(head_oid)"
    start_head_ref="$(git symbolic-ref -q HEAD 2>/dev/null || true)"
    iter_log="$LOG_DIR/iter-${iter}-$(git rev-parse --short=7 --verify HEAD 2>/dev/null || echo init).log"
    log "==== iteration $iter ===="

    status=kept rc=0
    : > "$msg_file"
    # Backgrounded so TERM/INT is handled while the agent runs, not after it.
    note_mission_changes
    started_at="$(date +%s)"
    run_agent "$(build_prompt)" >"$msg_file" &
    AGENT_PID=$!
    wait_agent
    duration_s=$(( $(date +%s) - started_at ))
    last_msg="$(cat "$msg_file" 2>/dev/null || true)"
    read_metrics
    cost="${m_cost:-0}"
    total_cost="$(add_cost "$total_cost" "$cost")"
    # The CLI can report failure with exit 0 (max turns, an execution error);
    # trust the result event over the exit code.
    agent_error=false
    [[ "$m_is_error" == true || "$m_subtype" == error* ]] && agent_error=true
    if [[ "$rc" -eq 0 && "$agent_error" == false ]]; then
        errors=0
    else
        errors=$((errors + 1))
        status=error
        if [[ "$rc" -ne 0 ]]; then
            log "agent failed (exit $rc; consecutive errors: $errors/$MAX_ERRORS)"
        else
            log "agent reported an error (${m_subtype:-unknown}; consecutive errors: $errors/$MAX_ERRORS)"
        fi
    fi

    # The prompt asks the agent to commit its own work with real messages;
    # this is only a safety net for leftovers.
    snapshot_failed=false
    refresh_worktree_status
    if [[ -n "$WORKTREE_STATUS" ]]; then
        if ! git add -A \
            || ! git -c commit.gpgSign=false commit --no-verify -qm \
                "[wip] agent leftovers from iteration $iter"; then
            snapshot_failed=true
            log "could not checkpoint iteration $iter leftovers"
        fi
    fi

    mutated=false
    repo_mutated && mutated=true
    new_commits="$(count_iteration_commits)"

    # Ratchet: keep the iteration only if CHECK_CMD passes (Carlini pattern —
    # kept history is always green, a bad iteration costs only tokens). Runs
    # whenever the repo changed, including after an agent error or timeout:
    # that is exactly when the tree is most likely half-finished.
    if [[ "$mutated" == true && "$snapshot_failed" == true ]]; then
        log "checkpoint failed — reverting iteration $iter"
        restore_iteration
        new_commits=0
        status=reverted
    elif [[ "$mutated" == true && -n "$CHECK_CMD" ]]; then
        log "check: $CHECK_CMD"
        if ! bash -c "$CHECK_CMD" >>"$iter_log" 2>&1; then
            log "check failed — reverting iteration $iter"
            restore_iteration
            new_commits=0
            status=reverted
        else
            refresh_worktree_status
            if [[ -n "$WORKTREE_STATUS" ]]; then
                # CHECK_CMD validates the checkpoint; its own test artifacts
                # must not become the next iteration's dirty baseline.
                git reset -q --hard HEAD
                restore_submodules
                git clean -q -ffd
            fi
        fi
    fi

    # Health check: a session that "succeeded" in a couple of turns without
    # touching the repo is almost always a broken key or model, not a genuine
    # no-op — count it as an error so MAX_ERRORS trips fast instead of burning
    # MAX_NOOPS iterations. Skipped when the turn count is unknown.
    if [[ "$status" != error && "$mutated" == false && -n "$m_turns" \
          && "$MIN_TURNS" -gt 0 && "$m_turns" -lt "$MIN_TURNS" ]]; then
        errors=$((errors + 1))
        status=error
        log "agent produced no work in $m_turns turns — treating as error (auth/model problem?)"
    fi

    # Repeated reverts make no progress either, so they count toward MAX_NOOPS.
    if [[ "$status" == kept && "$mutated" == false ]]; then
        status=noop
    fi
    case "$status" in
        noop|reverted) noops=$((noops + 1)) ;;
        kept)          noops=0 ;;
    esac

    # Fields the agent CLI did not report are simply left out, never guessed.
    extra=""
    [[ -z "$m_turns" ]]      || extra+=",\"turns\":$m_turns"
    [[ -z "$m_tokens_in" ]]  || extra+=",\"tokens_in\":$m_tokens_in"
    [[ -z "$m_tokens_out" ]] || extra+=",\"tokens_out\":$m_tokens_out"
    printf '{"iter":%d,"agent":"%s","status":"%s","commits":%d,"head":"%s","ts":"%s"' \
        "$iter" "$AGENT" "$status" "$new_commits" \
        "$(git rev-parse --short=7 --verify HEAD 2>/dev/null || echo none)" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$results_log"
    printf ',"subtype":"%s","cost_usd":%s,"duration_s":%d%s}\n' \
        "$m_subtype" "$(add_cost "$cost" 0)" "$duration_s" "$extra" >>"$results_log"
    log "iteration $iter: $status ($new_commits commits, \$$(fmt_cost "$cost"), ${m_turns:-?} turns, ${duration_s}s; total \$$(fmt_cost "$total_cost"))"
    write_summary

    if [[ "$status" != error && "$status" != reverted && "$last_msg" == *"$DONE_PROMISE"* ]]; then
        stop_reason="agent signaled $DONE_PROMISE"; break
    fi
    if [[ -n "$MAX_TOTAL_BUDGET_USD" ]] && cost_reached "$total_cost" "$MAX_TOTAL_BUDGET_USD"; then
        stop_reason="budget exhausted (\$$(fmt_cost "$total_cost") of \$$(fmt_cost "$MAX_TOTAL_BUDGET_USD"))"
        break
    fi
    [[ "$MAX_ERRORS" -gt 0 && "$errors" -ge "$MAX_ERRORS" ]] && { stop_reason="$MAX_ERRORS consecutive errors"; break; }
    [[ "$MAX_NOOPS" -gt 0 && "$noops" -ge "$MAX_NOOPS" ]] && { stop_reason="$MAX_NOOPS consecutive no-progress iterations"; break; }
    [[ "$MAX_ITERATIONS" -gt 0 && "$iter" -ge "$MAX_ITERATIONS" ]] && { stop_reason="max iterations"; break; }
    [[ "$SHUTDOWN" == true ]] && { stop_reason="shutdown signal"; break; }

    if [[ "$rc" -ne 0 ]]; then
        # 60s, 120s, 240s ... at the default base, capped so an unbounded
        # MAX_ERRORS neither sleeps for hours nor overflows the arithmetic.
        backoff=$((ERROR_BACKOFF * 2 ** (errors < 16 ? errors : 16)))
        [[ "$backoff" -le "$MAX_BACKOFF" ]] || backoff="$MAX_BACKOFF"
        pause "$backoff"
    else
        pause "$LOOP_DELAY"
    fi
done

log "loop finished after $iter iterations: $stop_reason"
log "total cost: \$$(fmt_cost "$total_cost") across $iter iterations"
