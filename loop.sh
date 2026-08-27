#!/usr/bin/env bash
set -euo pipefail

# AgentMill — run an agent CLI against a repo in a respawning loop.
# Fresh context every iteration; the repo (TODO.md + git history) is the memory.

AGENT="${AGENT:-claude}"                 # claude | codex
MODEL="${MODEL:-sonnet}"
FALLBACK_MODEL="${FALLBACK_MODEL:-sonnet}"
PROMPT_FILE="${PROMPT_FILE:-/prompts/PROMPT.md}"
REPO_DIR="${REPO_DIR:-/workspace/repo}"
LOG_DIR="${LOG_DIR:-/workspace/logs}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"    # 0 = unbounded
MAX_ERRORS="${MAX_ERRORS:-3}"            # consecutive agent failures before giving up
MAX_NOOPS="${MAX_NOOPS:-3}"              # consecutive no-progress iterations before stopping
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

SHUTDOWN=false
trap 'log "shutdown requested — finishing current iteration"; SHUTDOWN=true' TERM INT

[[ -e "$REPO_DIR/.git" ]] || die "no git repo at $REPO_DIR (mount one)"
[[ -f "$PROMPT_FILE" ]] || die "no prompt file at $PROMPT_FILE"
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
git config user.name "$GIT_USER"
git config user.email "$GIT_EMAIL"

if [[ -n "$SETUP_CMD" ]]; then
    log "setup: $SETUP_CMD"
    bash -c "$SETUP_CMD" || die "SETUP_CMD failed"
fi

# Minimal carry-forward between fresh contexts: recent history + the agent's
# own TODO list. Everything else the agent reads from the repo itself.
preamble() {
    echo "<loop-context>"
    echo "You are iteration $iter of an autonomous loop. Recent commits:"
    git log --oneline -5 2>/dev/null || echo "(no commits yet)"
    if [[ -f TODO.md ]]; then
        printf '\nTODO.md:\n'
        head -40 TODO.md
    fi
    echo "</loop-context>"
    echo
}

# Runs one agent session. Prints the agent's final message; exit code is the
# agent's. Full event stream goes to the iteration log.
run_agent() {
    local rc=0
    case "$AGENT" in
        claude)
            "${TIMEOUT_CMD[@]}" claude -p "$1" \
                --dangerously-skip-permissions \
                --model "$MODEL" --fallback-model "$FALLBACK_MODEL" \
                --output-format stream-json --verbose \
                | tee -a "$iter_log" \
                | jq -r 'select(.type == "result") | .result // empty' \
                || rc=$?
            ;;
        codex)
            "${TIMEOUT_CMD[@]}" codex exec "$1" \
                --dangerously-bypass-approvals-and-sandbox \
                -m "$MODEL" -C "$REPO_DIR" --json \
                -o /tmp/agentmill-last-msg >>"$iter_log" 2>&1 \
                || rc=$?
            cat /tmp/agentmill-last-msg 2>/dev/null || true
            ;;
    esac
    return "$rc"
}

log "starting loop: agent=$AGENT model=$MODEL max_iterations=$MAX_ITERATIONS"
results_log="$LOG_DIR/results.jsonl"
iter=0 errors=0 noops=0 stop_reason=""

while true; do
    iter=$((iter + 1))
    start_ref="$(git rev-parse HEAD 2>/dev/null || echo "")"
    iter_log="$LOG_DIR/iter-${iter}-$(git rev-parse --short=7 HEAD 2>/dev/null || echo init).log"
    log "==== iteration $iter ===="

    status=kept
    if last_msg="$(run_agent "$(preamble)$(cat "$PROMPT_FILE")")"; then
        errors=0
    else
        rc=$?
        errors=$((errors + 1))
        status=error
        log "agent failed (exit $rc; consecutive errors: $errors/$MAX_ERRORS)"
    fi

    # The prompt asks the agent to commit its own work with real messages;
    # this is only a safety net for leftovers.
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        git add -A
        git commit -qm "[wip] agent leftovers from iteration $iter" || true
    fi

    if [[ -n "$start_ref" ]]; then
        new_commits="$(git rev-list --count "${start_ref}..HEAD" 2>/dev/null || echo 0)"
    else
        new_commits="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
    fi

    # Ratchet: keep the iteration only if CHECK_CMD passes (Carlini pattern —
    # kept history is always green, a bad iteration costs only tokens).
    if [[ "$status" != error && -n "$CHECK_CMD" && "$new_commits" -gt 0 ]]; then
        log "check: $CHECK_CMD"
        if ! bash -c "$CHECK_CMD" >>"$iter_log" 2>&1; then
            log "check failed — reverting iteration $iter"
            [[ -n "$start_ref" ]] && git reset -q --hard "$start_ref"
            status=reverted
        fi
    fi

    # Repeated reverts make no progress either, so they count toward MAX_NOOPS.
    if [[ "$status" == kept && "$new_commits" -eq 0 ]]; then
        status=noop
    fi
    case "$status" in
        noop|reverted) noops=$((noops + 1)) ;;
        kept)          noops=0 ;;
    esac

    printf '{"iter":%d,"agent":"%s","status":"%s","commits":%d,"head":"%s","ts":"%s"}\n' \
        "$iter" "$AGENT" "$status" "$new_commits" \
        "$(git rev-parse --short=7 HEAD 2>/dev/null || echo none)" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$results_log"
    log "iteration $iter: $status ($new_commits commits)"

    if [[ "$status" != error && "$status" != reverted && "$last_msg" == *"$DONE_PROMISE"* ]]; then
        stop_reason="agent signaled $DONE_PROMISE"; break
    fi
    [[ "$errors" -ge "$MAX_ERRORS" ]] && { stop_reason="$MAX_ERRORS consecutive errors"; break; }
    [[ "$noops" -ge "$MAX_NOOPS" ]] && { stop_reason="$MAX_NOOPS consecutive no-progress iterations"; break; }
    [[ "$MAX_ITERATIONS" -gt 0 && "$iter" -ge "$MAX_ITERATIONS" ]] && { stop_reason="max iterations"; break; }
    [[ "$SHUTDOWN" == true ]] && { stop_reason="shutdown signal"; break; }

    if [[ "$status" == error ]]; then
        sleep $((ERROR_BACKOFF * 2 ** errors))   # 60s, 120s, 240s at the default base
    else
        sleep "$LOOP_DELAY"
    fi
done

log "loop finished after $iter iterations: $stop_reason"
