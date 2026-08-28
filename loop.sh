#!/usr/bin/env bash
set -euo pipefail

# AgentMill — run an agent CLI against a repo in a respawning loop.
# Fresh context every iteration; the repo (PROGRESS.md + git history) is the memory.

AGENT="${AGENT:-claude}"                 # claude | codex
MODEL="${MODEL:-}"                       # blank = backend-specific default
FALLBACK_MODEL="${FALLBACK_MODEL:-sonnet}"   # claude only
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
REPO_DIR="${REPO_DIR:-/workspace/repo}"
LOG_DIR="${LOG_DIR:-/workspace/logs}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"    # 0 = unbounded
MAX_ERRORS="${MAX_ERRORS:-3}"            # consecutive agent failures before giving up (0 = unbounded)
MAX_NOOPS="${MAX_NOOPS:-3}"              # consecutive no-progress iterations before stopping (0 = unbounded)
ITER_TIMEOUT="${ITER_TIMEOUT:-3600}"     # seconds per iteration
LOOP_DELAY="${LOOP_DELAY:-5}"            # seconds between iterations
ERROR_BACKOFF="${ERROR_BACKOFF:-30}"     # backoff base after a failure
DONE_PROMISE="${DONE_PROMISE:-TASK_COMPLETE}"
SETUP_CMD="${SETUP_CMD:-}"               # runs once before the loop
CHECK_CMD="${CHECK_CMD:-}"               # ratchet: iteration is reverted if this fails
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"

# GNU timeout is always present in the container; degrade without it (host tests).
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout "$ITER_TIMEOUT")
else
    TIMEOUT_CMD=(env)
fi

log() { printf '[%s] %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
die() { log "FATAL: $*"; exit 1; }

# Job control so a backgrounded agent gets its own process group and the whole
# CLI pipeline can be signalled at once.
set -m
SHUTDOWN=false
AGENT_PID=""
on_signal() {
    log "shutdown requested — stopping the current agent session"
    SHUTDOWN=true
    [[ -n "$AGENT_PID" ]] || return 0
    kill -TERM -- "-$AGENT_PID" 2>/dev/null || kill -TERM "$AGENT_PID" 2>/dev/null || true
}
trap on_signal TERM INT

[[ -e "$REPO_DIR/.git" ]] || die "no git repo at $REPO_DIR (mount one)"
[[ -f "$PROMPT_FILE" ]] || die "no prompt file at $PROMPT_FILE"
case "$AGENT" in
    claude) [[ -n "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] \
                || die "set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"
            MODEL="${MODEL:-sonnet}" ;;
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
git config user.name "$GIT_USER"
git config user.email "$GIT_EMAIL"

worktree_status() {
    git status --porcelain --untracked-files=all 2>/dev/null
}

require_clean_worktree() {
    local reason="$1"
    [[ -z "$(worktree_status)" ]] \
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

# Runs one agent session. Prints the agent's final message; exit code is the
# agent's. Full event stream goes to the iteration log.
run_agent() {
    local rc=0 model_args=()
    case "$AGENT" in
        claude)
            [[ -n "$MODEL" ]] && model_args=(--model "$MODEL" --fallback-model "$FALLBACK_MODEL")
            "${TIMEOUT_CMD[@]}" claude -p "$1" \
                --dangerously-skip-permissions \
                "${model_args[@]}" \
                --output-format stream-json --verbose \
                | tee -a "$iter_log" \
                | jq -r 'select(.type == "result") | .result // empty' \
                || rc=$?
            ;;
        codex)
            [[ -n "$MODEL" ]] && model_args=(-m "$MODEL")
            # Truncate first: a run that exits without a final message would
            # otherwise replay the previous iteration's (maybe DONE_PROMISE).
            : > "$codex_msg"
            "${TIMEOUT_CMD[@]}" codex exec "$1" \
                --dangerously-bypass-approvals-and-sandbox \
                "${model_args[@]}" -C "$REPO_DIR" --json \
                -o "$codex_msg" >>"$iter_log" 2>&1 \
                || rc=$?
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
    [[ "$(head_oid)" != "$start_ref" || -n "$(worktree_status)" ]]
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

# Undo everything the iteration did, including untracked files it left behind.
restore_iteration() {
    if [[ -n "$start_ref" ]]; then
        if [[ -n "$start_head_ref" ]]; then
            git symbolic-ref HEAD "$start_head_ref"
        else
            git update-ref --no-deref HEAD "$start_ref"
        fi
        git reset -q --hard "$start_ref"
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
iter=0 errors=0 noops=0 stop_reason=""

while true; do
    iter=$((iter + 1))
    # --verify so an unborn HEAD leaves start_ref empty instead of the literal "HEAD".
    start_ref="$(head_oid)"
    start_head_ref="$(git symbolic-ref -q HEAD 2>/dev/null || true)"
    iter_log="$LOG_DIR/iter-${iter}-$(git rev-parse --short=7 --verify HEAD 2>/dev/null || echo init).log"
    log "==== iteration $iter ===="

    status=kept rc=0
    : > "$msg_file"
    # Backgrounded so TERM/INT is handled while the agent runs, not after it.
    run_agent "$(printf '%s\n\n%s' "$(preamble)" "$(cat "$PROMPT_FILE")")" >"$msg_file" &
    AGENT_PID=$!
    wait "$AGENT_PID" || rc=$?
    AGENT_PID=""
    last_msg="$(cat "$msg_file" 2>/dev/null || true)"
    if [[ "$rc" -eq 0 ]]; then
        errors=0
    else
        errors=$((errors + 1))
        status=error
        log "agent failed (exit $rc; consecutive errors: $errors/$MAX_ERRORS)"
    fi

    # The prompt asks the agent to commit its own work with real messages;
    # this is only a safety net for leftovers.
    snapshot_failed=false
    if [[ -n "$(worktree_status)" ]]; then
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
        elif [[ -n "$(worktree_status)" ]]; then
            # CHECK_CMD validates the checkpoint; its own test artifacts must
            # not become the next iteration's dirty baseline.
            git reset -q --hard HEAD
            git clean -q -ffd
        fi
    fi

    # Repeated reverts make no progress either, so they count toward MAX_NOOPS.
    if [[ "$status" == kept && "$mutated" == false ]]; then
        status=noop
    fi
    case "$status" in
        noop|reverted) noops=$((noops + 1)) ;;
        kept)          noops=0 ;;
    esac

    printf '{"iter":%d,"agent":"%s","status":"%s","commits":%d,"head":"%s","ts":"%s"}\n' \
        "$iter" "$AGENT" "$status" "$new_commits" \
        "$(git rev-parse --short=7 --verify HEAD 2>/dev/null || echo none)" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$results_log"
    log "iteration $iter: $status ($new_commits commits)"

    if [[ "$status" != error && "$status" != reverted && "$last_msg" == *"$DONE_PROMISE"* ]]; then
        stop_reason="agent signaled $DONE_PROMISE"; break
    fi
    [[ "$MAX_ERRORS" -gt 0 && "$errors" -ge "$MAX_ERRORS" ]] && { stop_reason="$MAX_ERRORS consecutive errors"; break; }
    [[ "$MAX_NOOPS" -gt 0 && "$noops" -ge "$MAX_NOOPS" ]] && { stop_reason="$MAX_NOOPS consecutive no-progress iterations"; break; }
    [[ "$MAX_ITERATIONS" -gt 0 && "$iter" -ge "$MAX_ITERATIONS" ]] && { stop_reason="max iterations"; break; }
    [[ "$SHUTDOWN" == true ]] && { stop_reason="shutdown signal"; break; }

    if [[ "$rc" -ne 0 ]]; then
        sleep $((ERROR_BACKOFF * 2 ** errors))   # 60s, 120s, 240s at the default base
    else
        sleep "$LOOP_DELAY"
    fi
done

log "loop finished after $iter iterations: $stop_reason"
