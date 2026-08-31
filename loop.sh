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
METRIC_CMD="${METRIC_CMD:-}"             # metric ratchet: last stdout line is the score (empty = off)
METRIC_DIRECTION="${METRIC_DIRECTION:-min}"   # min | max — which way is an improvement
DONE_CMD="${DONE_CMD:-}"                 # completion verifier: a done claim is rejected if this fails
EVALUATOR="${EVALUATOR:-false}"          # write-confined review session before a done claim is honored
EVALUATOR_FILE="${EVALUATOR_FILE:-/prompts/EVALUATOR.md}"  # the reviewer's prompt
CLAUDE_BARE="${CLAUDE_BARE:-false}"      # claude only: --bare (skips CLAUDE.md/hook discovery)
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
# PROBE_CMD bounds the one-off capability probes below: a CLI that hangs on
# --help must not hang the loop before it has run anything.
if timeout --kill-after=1 1 true >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout "--kill-after=$TIMEOUT_KILL_AFTER" "$ITER_TIMEOUT")
    PROBE_CMD=(timeout --kill-after=1 10)
    SHUTDOWN_CLEANUP_CMD=(timeout --kill-after=1 20)
elif timeout -k 1 1 true >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout -k "$TIMEOUT_KILL_AFTER" "$ITER_TIMEOUT")
    PROBE_CMD=(timeout -k 1 10)
    SHUTDOWN_CLEANUP_CMD=(timeout -k 1 20)
else
    TIMEOUT_CMD=(env)
    PROBE_CMD=(env)
    SHUTDOWN_CLEANUP_CMD=(env)
fi

log() { printf '[%s] %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
die() { log "FATAL: $*"; exit 1; }

# Job control gives the loop wrapper and its timed CLI session distinct process
# groups, allowing each layer to enforce a bounded descendant-group shutdown.
set -m
SHUTDOWN=false
AGENT_PID=""
WATCHDOG_PID=""
REVIEWER_HANDSHAKE_FILE=""
REVIEWER_ACK_FILE=""
SUPERVISOR_REVIEWER_STATE_FILE=""
SESSION_REVIEWER_PID=""
SESSION_REVIEWER_PGID=""
SESSION_REVIEWER_PID_START=""
SESSION_REVIEWER_PG_START=""
REVIEWER_CONTROL=/usr/local/bin/agentmill-reviewer-control
REVIEWER_CONTROL_FAILED=false

read_state_file() {
    local file="$1"
    local reviewer_pid reviewer_pgid reviewer_pid_start reviewer_pg_start extra
    [[ -n "$file" && -f "$file" && ! -L "$file" && -O "$file" && -s "$file" ]] \
        || return 1
    IFS=' ' read -r reviewer_pid reviewer_pgid reviewer_pid_start reviewer_pg_start extra \
        <"$file" || return 1
    [[ "$reviewer_pid" =~ ^[1-9][0-9]*$ && "$reviewer_pgid" =~ ^[1-9][0-9]*$ ]] \
        || return 1
    [[ "$reviewer_pid_start" =~ ^[1-9][0-9]*$ && "$reviewer_pg_start" =~ ^[0-9]+$ \
       && -z "$extra" ]] || return 1
    printf '%s %s %s %s\n' "$reviewer_pid" "$reviewer_pgid" \
        "$reviewer_pid_start" "$reviewer_pg_start"
}

read_reviewer_state() {
    if [[ "${SESSION_REVIEWER_PID:-}" =~ ^[1-9][0-9]*$ \
          && "${SESSION_REVIEWER_PGID:-}" =~ ^[1-9][0-9]*$ \
          && "${SESSION_REVIEWER_PID_START:-}" =~ ^[1-9][0-9]*$ \
          && "${SESSION_REVIEWER_PG_START:-}" =~ ^[0-9]+$ ]]; then
        printf '%s %s %s %s\n' "$SESSION_REVIEWER_PID" "$SESSION_REVIEWER_PGID" \
            "$SESSION_REVIEWER_PID_START" "$SESSION_REVIEWER_PG_START"
        return 0
    fi
    # run_agent executes in a background subshell, so its in-memory copy is
    # not visible to the outer loop's TERM/KILL watchdog. Bridge that process
    # boundary through an agent-owned mode-0600 file outside EVAL_ROOT. The
    # distinct reviewer uid and Landlock domain cannot alter this copy.
    if [[ -n "${SUPERVISOR_REVIEWER_STATE_FILE:-}" \
          && -s "$SUPERVISOR_REVIEWER_STATE_FILE" ]]; then
        read_state_file "$SUPERVISOR_REVIEWER_STATE_FILE" || return 2
        return 0
    fi
    return 1
}

read_reviewer_handshake() {
    read_state_file "${REVIEWER_HANDSHAKE_FILE:-}"
}

reviewer_session_alive() {
    local state reviewer_pid reviewer_pgid reviewer_pid_start reviewer_pg_start rc=0
    state="$(read_reviewer_state)" || { rc=$?; return "$rc"; }
    read -r reviewer_pid reviewer_pgid reviewer_pid_start reviewer_pg_start <<<"$state"
    /usr/bin/timeout --kill-after=1 4 \
        /usr/bin/sudo -n "$REVIEWER_CONTROL" 0 \
        "$reviewer_pid" "$reviewer_pgid" "$reviewer_pid_start" "$reviewer_pg_start" \
        >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) return 0 ;;
        10) return 1 ;;
        *) REVIEWER_CONTROL_FAILED=true; return 2 ;;
    esac
}

session_group_alive() {
    local pid="$1" reviewer_rc=0
    kill -0 -- "-$pid" 2>/dev/null && return 0
    kill -0 "$pid" 2>/dev/null && return 0
    reviewer_session_alive || reviewer_rc=$?
    case "$reviewer_rc" in
        1) return 1 ;;
        *) return 0 ;; # alive or unknown: retain the bounded watchdog
    esac
}

signal_session_group() {
    local signal="$1" pid="$2" state reviewer_pid reviewer_pgid
    local reviewer_pid_start reviewer_pg_start state_rc=0 control_rc=0 alive_rc=0
    kill "-$signal" -- "-$pid" 2>/dev/null || kill "-$signal" "$pid" 2>/dev/null || true
    # Sudo runs the production evaluator under a distinct uid. A same-uid
    # verifier could kill a reviewer-owned signal helper, so only the fixed
    # root-owned controller enforces this second process-group boundary.
    state="$(read_reviewer_state)" || state_rc=$?
    if [[ "$state_rc" -eq 1 ]]; then
        return 0
    fi
    if [[ "$state_rc" -ne 0 || ! -x "$REVIEWER_CONTROL" ]]; then
        REVIEWER_CONTROL_FAILED=true
        return 1
    fi
    if [[ "$state_rc" -eq 0 ]]; then
        read -r reviewer_pid reviewer_pgid reviewer_pid_start reviewer_pg_start <<<"$state"
        /usr/bin/timeout --kill-after=1 4 \
            /usr/bin/sudo -n "$REVIEWER_CONTROL" "$signal" \
            "$reviewer_pid" "$reviewer_pgid" "$reviewer_pid_start" "$reviewer_pg_start" \
            >/dev/null 2>&1 || control_rc=$?
        case "$control_rc" in
            0|10) ;;
            *) REVIEWER_CONTROL_FAILED=true; return 1 ;;
        esac
        if [[ "$signal" == KILL ]]; then
            reviewer_session_alive || alive_rc=$?
            # Only rc=1 is a positive assertion that no authenticated reviewer
            # process remains. Alive and unknown both fail closed.
            if [[ "$alive_rc" -ne 1 ]]; then
                REVIEWER_CONTROL_FAILED=true
                return 1
            fi
        fi
    fi
    return 0
}

on_signal() {
    [[ "$SHUTDOWN" == true ]] \
        || log "shutdown requested — stopping the current agent session"
    SHUTDOWN=true
    [[ -n "$AGENT_PID" && -z "$WATCHDOG_PID" ]] || return 0
    signal_session_group TERM "$AGENT_PID" || true
    # An agent that ignores TERM is killed after the grace period; the loop
    # keeps waiting for it either way (see wait_agent).
    # run_agent has its own descendant-group watchdog. This outer deadline is
    # slightly later, giving that wrapper time to reap the group and return.
    { sleep "$((SHUTDOWN_GRACE + 2))"; signal_session_group KILL "$AGENT_PID"; } &
    WATCHDOG_PID=$!
}
trap on_signal TERM INT

# Wait for the backgrounded agent. A trap interrupts `wait`, which then
# returns 128+signal while the agent is still running; keep waiting until it
# has really exited so commit/check/revert never race a live agent.
wait_agent() {
    local finished_agent_pid="$AGENT_PID" attempt reviewer_rc=0 watchdog_rc=0
    rc=0
    until wait "$AGENT_PID"; do
        rc=$?
        kill -0 "$AGENT_PID" 2>/dev/null || break
        rc=0
    done
    # The wrapper is reaped. Mask the shared slot before any further cleanup:
    # a TERM in this window must not arm a new watchdog against a finished PID
    # that the kernel could later reuse. Remaining operations use the captured
    # immutable value above.
    AGENT_PID=""
    # run_interruptible helpers can return after starting an ordinary
    # background child. Drain the wrapper's direct process group before
    # accepting a baseline/check/metric result or canceling an outer watchdog.
    # The evaluator may also have a second sudo-owned group, handled below.
    if kill -0 -- "-$finished_agent_pid" 2>/dev/null; then
        kill -KILL -- "-$finished_agent_pid" 2>/dev/null || true
        for ((attempt = 0; attempt < 100; attempt++)); do
            kill -0 -- "-$finished_agent_pid" 2>/dev/null || break
            sleep 0.01
        done
    fi
    if [[ -n "$WATCHDOG_PID" ]]; then
        reviewer_session_alive || reviewer_rc=$?
        if [[ "$reviewer_rc" -eq 1 ]]; then
            kill -- "-$WATCHDOG_PID" 2>/dev/null \
                || kill "$WATCHDOG_PID" 2>/dev/null || true
            wait "$WATCHDOG_PID" 2>/dev/null || true
        else
            # Alive and unknown both retain the already-armed root-controller
            # deadline. A crashed wrapper must not cancel the only trusted KILL.
            wait "$WATCHDOG_PID" 2>/dev/null || watchdog_rc=$?
            if [[ "$watchdog_rc" -ne 0 ]]; then
                REVIEWER_CONTROL_FAILED=true
                rc=125
            fi
        fi
        WATCHDOG_PID=""
    fi
    reviewer_rc=0
    reviewer_session_alive || reviewer_rc=$?
    case "$reviewer_rc" in
        0)
            if ! signal_session_group KILL "$finished_agent_pid"; then
                REVIEWER_CONTROL_FAILED=true
                rc=125
            fi ;;
        1) ;;
        *) REVIEWER_CONTROL_FAILED=true; rc=125 ;;
    esac
    if [[ "$REVIEWER_CONTROL_FAILED" == false ]]; then
        [[ -z "$SUPERVISOR_REVIEWER_STATE_FILE" ]] \
            || : >"$SUPERVISOR_REVIEWER_STATE_FILE" 2>/dev/null || true
    fi
}

# Run any potentially slow post-session operation in an addressable process
# group. This gives the outer TERM/INT trap something to stop immediately;
# Bash otherwise defers its trap while a foreground child (a verifier, metric,
# or git filter/hook) is hung. The post-$! check closes the same launch race as
# the worker/evaluator sessions.
run_interruptible() {
    local rc=0
    [[ "$SHUTDOWN" == false ]] || return 125
    "$@" &
    AGENT_PID=$!
    [[ "$SHUTDOWN" == false ]] || on_signal
    wait_agent
    return "$rc"
}

# Interruptible sleep: a foreground `sleep` defers the TERM/INT trap until it
# ends, so a shutdown during LOOP_DELAY or the error backoff would start one
# more full agent session. Backgrounded, the trap runs at once.
pause() {
    # Reuse the tracked launch path: its pre-launch guard and post-$! signal
    # recheck close the narrow race where TERM arrived just before sleep began.
    run_interruptible sleep "$1" || true
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
# Resolve the selected executable before crossing the sudo boundary. Sudo's
# secure_path is deliberately not relaxed, and the sandbox helper must never
# rely on a caller-controlled PATH to choose the reviewer executable.
AGENT_BIN="$(command -v "$AGENT" 2>/dev/null || true)"
[[ -n "$AGENT_BIN" && -x "$AGENT_BIN" ]] || die "$AGENT executable not found"
if [[ "$AGENT_BIN" != /* ]]; then
    agent_bin_dir="$(cd -P -- "$(dirname -- "$AGENT_BIN")" && pwd)" \
        || die "cannot resolve $AGENT executable"
    AGENT_BIN="$agent_bin_dir/$(basename -- "$AGENT_BIN")"
fi
[[ "$EVALUATOR" != true || -f "$EVALUATOR_FILE" ]] \
    || die "EVALUATOR=true but no evaluator prompt at $EVALUATOR_FILE"
CODEX_AUTH_SNAPSHOT=""
if [[ "$EVALUATOR" == true && "$AGENT" == codex \
      && -e "$HOME/.codex/auth.json" ]]; then
    [[ -f "$HOME/.codex/auth.json" && ! -L "$HOME/.codex/auth.json" ]] \
        || die "Codex evaluator auth must be a regular non-symlink file"
    CODEX_AUTH_SNAPSHOT="$(cat "$HOME/.codex/auth.json")" \
        || die "could not snapshot Codex evaluator auth"
fi
if [[ "$EVALUATOR" == true && ! -x /usr/local/bin/landlock-exec ]]; then
    # The smoke suite exercises orchestration directly on non-Linux hosts. The
    # production entrypoint is always /loop.sh and must fail closed without its
    # kernel-enforced reviewer boundary.
    [[ "${_AGENTMILL_TEST_UNSANDBOXED_EVALUATOR:-}" == true \
       && "${BASH_SOURCE[0]}" != /loop.sh ]] \
        || die "EVALUATOR=true requires /usr/local/bin/landlock-exec"
fi
if [[ "$EVALUATOR" == true && -x /usr/local/bin/landlock-exec ]]; then
    /usr/bin/id -u agentmill-reviewer >/dev/null 2>&1 \
        || die "EVALUATOR=true requires the agentmill-reviewer user"
    /usr/bin/sudo -n -u agentmill-reviewer /usr/bin/true >/dev/null 2>&1 \
        || die "EVALUATOR=true cannot start the isolated reviewer user"
    [[ -x "$REVIEWER_CONTROL" ]] \
        || die "EVALUATOR=true requires $REVIEWER_CONTROL"
    reviewer_control_probe_rc=0
    /usr/bin/sudo -n "$REVIEWER_CONTROL" 0 1 2 1 0 \
        >/dev/null 2>&1 || reviewer_control_probe_rc=$?
    [[ "$reviewer_control_probe_rc" -eq 2 ]] \
        || die "EVALUATOR=true cannot invoke the root reviewer controller"
    unset reviewer_control_probe_rc
fi
case "$METRIC_DIRECTION" in
    min|max) ;;
    *) die "METRIC_DIRECTION must be min or max, got: $METRIC_DIRECTION" ;;
esac

cd "$REPO_DIR"
mkdir -p "$LOG_DIR"
EVALUATOR_SOURCE_EXCLUDE="${AGENTMILL_LOG_REPO_REL:-}"
if [[ "$LOG_DIR" == "$REPO_DIR/"* ]]; then
    EVALUATOR_SOURCE_EXCLUDE="${LOG_DIR#"$REPO_DIR/"}"
fi
if [[ -n "$EVALUATOR_SOURCE_EXCLUDE" ]]; then
    case "/$EVALUATOR_SOURCE_EXCLUDE/" in
        *'/../'*|*'/./'*|*'//'*)
            die "invalid repository-relative log exclusion: $EVALUATOR_SOURCE_EXCLUDE" ;;
    esac
    [[ "$EVALUATOR_SOURCE_EXCLUDE" != /* ]] \
        || die "repository-relative log exclusion must not be absolute"
fi

# The framework prompt belongs in claude's system prompt, not the user turn.
# Older CLIs only take it inline; probe the help text once — in a scratch
# directory, never the checkout, since a --help that is not a --help must not
# touch the repo — and fall back to the inline form whenever the probe fails.
CLAUDE_SYS_PROMPT_FILE=false
if [[ "$AGENT" == claude ]]; then
    probe_dir="$LOG_DIR/.probe"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir"
    if (cd "$probe_dir" && "${PROBE_CMD[@]}" "$AGENT_BIN" --help </dev/null 2>/dev/null) \
        | grep -q -- '--append-system-prompt-file'; then
        CLAUDE_SYS_PROMPT_FILE=true
    fi
    rm -rf "$probe_dir"
fi
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

# Operator drop-box: `.mill/STOP` brakes the loop, `.mill/STEER.md` injects a
# one-shot instruction into the next session (mill stop --soft / mill steer).
MILL_CTL_DIR="$REPO_DIR/.mill"
STOP_FILE="$MILL_CTL_DIR/STOP"
STEER_FILE="$MILL_CTL_DIR/STEER.md"

# The drop-box must be invisible to git: `git status` gates the loop's start
# and the ratchet reverts with `git clean -ffd`, which (having no -x) leaves
# excluded paths alone. --git-path so a linked worktree writes the exclude of
# the git dir it actually shares. Bounded and idempotent: one appended line.
exclude_mill_dir() {
    local exclude
    mkdir -p "$MILL_CTL_DIR" 2>/dev/null || true
    exclude="$(git rev-parse --git-path info/exclude 2>/dev/null || true)"
    [[ -n "$exclude" ]] || return 0
    mkdir -p "$(dirname "$exclude")" 2>/dev/null || return 0
    ! [[ -f "$exclude" ]] || ! grep -qxF -- '.mill/' "$exclude" || return 0
    # A file whose last line has no newline would otherwise swallow the entry.
    [[ ! -s "$exclude" || -z "$(tail -c1 "$exclude")" ]] || printf '\n' >> "$exclude"
    printf '.mill/\n' >> "$exclude" 2>/dev/null \
        || log "could not add .mill/ to $exclude — the drop-box will show up in git status"
}
exclude_mill_dir

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
    # The metric ratchet is invisible from inside the repo; name the target so
    # the session optimizes against the same number the loop judges it by.
    [[ -z "$METRIC_CMD" ]] || printf '\nCurrent best METRIC: %s (%s). Only strictly better results are kept.\n' \
        "$METRIC_BEST" "$METRIC_DIRECTION"
    # PROMPT.md names this machine-readable block instead of baking in the
    # default promise. JSON encoding keeps quotes, newlines, and tag-like text
    # in a configurable promise from changing the prompt's structure.
    printf '\n<completion-promise>\n%s\n</completion-promise>\n' "$DONE_PROMISE_JSON"
    echo "</loop-context>"
    # The operator's one-shot note, consumed by read_steer before this ran.
    [[ "$STEERED" != true ]] || printf '\n<operator-steer>\n%s\n\n%s\n</operator-steer>\n' \
        "A one-shot instruction from the operator, for THIS session only. It overrides the mission wherever the two conflict; the next session will not see it." \
        "$STEER_TEXT"
    # No PROGRESS.md means no session has run yet. Spend this one turning the
    # mission into the checklist every later session steers by, nothing else.
    [[ -f PROGRESS.md ]] && return 0
    cat <<'INIT'

<initializer>
This is the FIRST session of the loop: there is no PROGRESS.md yet. Do not
start feature work this session. Instead:

1. Read the mission below and the repo, then write PROGRESS.md with these
   sections, each holding markdown checkboxes (`- [ ]` / `- [x]`):
   Completed, In Progress, Blocked, Next Up, Failed approaches,
   Definition of done.
2. Break the mission into concrete, individually checkable items under
   Next Up and Definition of done. Be specific; a later session with no
   memory of this one must be able to pick the next item from it alone.
3. Make sure a verifier command exists (tests, build, lint). If none does,
   create a minimal one. Record the exact command in PROGRESS.md.
4. Commit PROGRESS.md (and the verifier, if you added one).
5. EXIT. Do not implement anything from the checklist yet — the loop
   respawns you with fresh context for that.
</initializer>
INIT
}

# The mission is re-read from the checkout every iteration, so editing
# MILL.md steers a running loop. Its frontmatter (settings) is mill's
# business and was applied at start; only the body is handed to the agent.
mission_body() {
    local rc=0
    awk '{ line = $0; sub(/\r$/, "", line) }
         NR == 1 && line == "---" { fm = 1; next }
         fm && line == "---"      { fm = 0; closed = 1; next }
         !fm                       { print line }
         END { if (fm && !closed) exit 42 }' "$MISSION_FILE" || rc=$?
    return "$rc"
}

MISSION_SUM=""
note_mission_changes() {
    local sum
    sum="$(cksum < "$MISSION_FILE" 2>/dev/null || true)"
    [[ -z "$MISSION_SUM" || "$sum" == "$MISSION_SUM" ]] \
        || log "$(basename "$MISSION_FILE") changed since the last iteration"
    MISSION_SUM="$sum"
}

# The steer file is one-shot: read it, delete it, and let this session's
# preamble carry it. Deleted even when empty, so a stray file cannot linger.
STEERED=false
STEER_TEXT=""
read_steer() {
    STEERED=false STEER_TEXT=""
    [[ -f "$STEER_FILE" ]] || return 0
    STEER_TEXT="$(cat "$STEER_FILE" 2>/dev/null || true)"
    rm -f "$STEER_FILE"
    [[ -n "$STEER_TEXT" ]] || return 0
    STEERED=true
    log "steer: $(printf '%s' "$STEER_TEXT" | head -1)"
}

# The operator's brake (mill stop --soft). Checked before a session starts and
# again once one ends, so a file dropped mid-session takes effect at once.
stop_file_requested() {
    [[ -f "$STOP_FILE" ]] || return 1
    log "stop file present — finishing after this iteration"
}

# For claude the framework prompt rides in the system prompt (see run_agent),
# leaving the user turn as just carry-forward plus the mission. codex exec has
# no system-prompt flag, so there it stays concatenated.
build_prompt() {
    if [[ "$AGENT" == claude ]]; then
        printf '%s\n\n<mission>\n%s\n</mission>\n' "$(preamble)" "$CURRENT_MISSION"
    else
        printf '%s\n\n%s\n\n<mission>\n%s\n</mission>\n' \
            "$(preamble)" "$(cat "$PROMPT_FILE")" "$CURRENT_MISSION"
    fi
}

# The reviewer gets its own prompt, the whole run's diff, the verifier it is
# expected to run, and the mission it is judging against — no carry-forward.
build_eval_prompt() {
    local range="${RUN_BASE:+$RUN_BASE..}HEAD"
    printf '%s\n\n<changes>\n' "$(cat "$EVALUATOR_FILE")"
    supervisor_git -C "$REPO_DIR" log --oneline "$range" 2>/dev/null || true
    printf '\n'
    supervisor_git -C "$REPO_DIR" diff --stat "$range" 2>/dev/null || true
    printf '</changes>\n\n<verifier>\n%s\n</verifier>\n\n<mission>\n%s\n</mission>\n' \
        "${DONE_CMD:-${CHECK_CMD:-none}}" "$CURRENT_MISSION"
}

# State used inside run_agent's background subshell. The timed command is
# itself backgrounded so this subshell handles TERM immediately while waiting.
SESSION_PID=""
SESSION_WATCHDOG_PID=""
SESSION_RC=0
SESSION_STOP_REQUESTED=false
SESSION_STATE_REQUIRED=false
SESSION_SETUP_FAILED=false
on_session_signal() {
    SESSION_STOP_REQUESTED=true
    [[ -n "$SESSION_PID" && -z "$SESSION_WATCHDOG_PID" ]] || return 0
    signal_session_group TERM "$SESSION_PID" || SESSION_SETUP_FAILED=true
    { sleep "$SHUTDOWN_GRACE"; signal_session_group KILL "$SESSION_PID"; } &
    SESSION_WATCHDOG_PID=$!
}

after_session_launch() {
    local attempt state reviewer_pid reviewer_pgid reviewer_pid_start reviewer_pg_start
    [[ "$SESSION_STOP_REQUESTED" == false ]] || on_session_signal
    [[ "$SESSION_STATE_REQUIRED" == true ]] || return 0
    for ((attempt = 0; attempt < 500; attempt++)); do
        if state="$(read_reviewer_handshake)"; then
            read -r reviewer_pid reviewer_pgid reviewer_pid_start reviewer_pg_start <<<"$state"
            # The run_agent subshell keeps the authoritative copy in memory.
            # Its signal trap and watchdog never depend on reviewer-writable
            # handshake files after this point.
            SESSION_REVIEWER_PID="$reviewer_pid"
            SESSION_REVIEWER_PGID="$reviewer_pgid"
            SESSION_REVIEWER_PID_START="$reviewer_pid_start"
            SESSION_REVIEWER_PG_START="$reviewer_pg_start"
            if [[ -z "$SUPERVISOR_REVIEWER_STATE_FILE" \
                  || ! -f "$SUPERVISOR_REVIEWER_STATE_FILE" \
                  || -L "$SUPERVISOR_REVIEWER_STATE_FILE" \
                  || ! -O "$SUPERVISOR_REVIEWER_STATE_FILE" ]] \
                || ! printf '%s %s %s %s\n' "$reviewer_pid" "$reviewer_pgid" \
                    "$reviewer_pid_start" "$reviewer_pg_start" \
                    >"$SUPERVISOR_REVIEWER_STATE_FILE"; then
                printf 'could not preserve reviewer process group for the outer watchdog\n' \
                    >>"$agent_log"
                SESSION_SETUP_FAILED=true
                signal_session_group KILL "$SESSION_PID" || true
                return 1
            fi
            if [[ ! -f "$REVIEWER_ACK_FILE" || -L "$REVIEWER_ACK_FILE" \
                  || ! -O "$REVIEWER_ACK_FILE" ]] \
                || ! printf 'ready\n' >"$REVIEWER_ACK_FILE"; then
                printf 'could not acknowledge reviewer process group; refusing to start evaluator\n' \
                    >>"$agent_log"
                SESSION_SETUP_FAILED=true
                signal_session_group KILL "$SESSION_PID" || true
                return 1
            fi
            # A signal may have arrived while sudo was still creating its
            # separate reviewer process group. Forward it again now that the
            # helper has published the exact PID/PGID.
            if [[ "$SESSION_STOP_REQUESTED" == true ]] \
                && ! signal_session_group TERM "$SESSION_PID"; then
                SESSION_SETUP_FAILED=true
            fi
            return 0
        fi
        kill -0 "$SESSION_PID" 2>/dev/null || break
        sleep 0.01
    done
    printf 'evaluator sandbox did not publish its process group\n' >>"$agent_log"
    SESSION_SETUP_FAILED=true
    signal_session_group KILL "$SESSION_PID" || true
    return 1
}

wait_session() {
    local finished_session_pid="$SESSION_PID" attempt reviewer_rc=0 watchdog_rc=0
    SESSION_RC=0
    until wait "$SESSION_PID"; do
        SESSION_RC=$?
        kill -0 "$SESSION_PID" 2>/dev/null || break
        SESSION_RC=0
    done
    # As in wait_agent, mask the shared trap slot immediately after reap. The
    # captured PID remains valid for the bounded cleanup below without exposing
    # a reused PID to a later TERM/INT.
    SESSION_PID=""
    if [[ -n "$SESSION_WATCHDOG_PID" ]]; then
        if session_group_alive "$finished_session_pid"; then
            # timeout may have exited before one of its descendants. Do not let
            # the wrapper return until the bounded group kill has completed.
            wait "$SESSION_WATCHDOG_PID" 2>/dev/null || watchdog_rc=$?
            [[ "$watchdog_rc" -eq 0 ]] || SESSION_SETUP_FAILED=true
        else
            kill -- "-$SESSION_WATCHDOG_PID" 2>/dev/null \
                || kill "$SESSION_WATCHDOG_PID" 2>/dev/null || true
            wait "$SESSION_WATCHDOG_PID" 2>/dev/null || true
        fi
        SESSION_WATCHDOG_PID=""
    fi
    # A CLI can exit while ordinary background jobs in its process group keep
    # running. Drain that group before checks or evaluator preparation; a
    # later session must never overlap residue from the one just reaped.
    if kill -0 -- "-$finished_session_pid" 2>/dev/null; then
        kill -KILL -- "-$finished_session_pid" 2>/dev/null || true
        for ((attempt = 0; attempt < 100; attempt++)); do
            kill -0 -- "-$finished_session_pid" 2>/dev/null || break
            sleep 0.01
        done
    fi
    # Sudo's command monitor may put the reviewer command in a different
    # process group and exit before a TERM-ignoring descendant. The in-memory
    # handshake keeps that group addressable; do not race cleanup against it.
    reviewer_session_alive || reviewer_rc=$?
    case "$reviewer_rc" in
        0) signal_session_group KILL "$finished_session_pid" \
               || SESSION_SETUP_FAILED=true ;;
        1) ;;
        *) SESSION_SETUP_FAILED=true ;;
    esac
    [[ "$REVIEWER_CONTROL_FAILED" == false ]] || SESSION_SETUP_FAILED=true
    [[ "$SESSION_SETUP_FAILED" == false ]] || SESSION_RC=125
    SESSION_REVIEWER_PID=""
    SESSION_REVIEWER_PGID=""
    SESSION_REVIEWER_PID_START=""
    SESSION_REVIEWER_PG_START=""
}

# One jq pass over claude's stream-json log: the metrics of the last result
# event as a tab-separated line, then the final message. A run without a
# result event prints nothing at all, which the loop reads as "unknown".
# shellcheck disable=SC2016  # jq program: $r and $ev are jq's, not the shell's
CLAUDE_RESULT_JQ='
  ([inputs | fromjson? | select(type == "object") | select(.type == "result")] | last) as $r
  | if $r == null then empty else
      ([ ($r.subtype // ""), (($r.is_error // false) | tostring),
         (($r.total_cost_usd // 0) | tostring), (($r.num_turns // "") | tostring),
         (($r.duration_ms // 0) | tostring),
         (($r.usage.input_tokens // "") | tostring),
         (($r.usage.output_tokens // "") | tostring) ] | @tsv),
      ($r.result // "")
    end'

# The validated structured reply of the same result event, compacted onto one
# line. Older CLIs put it in .result as a JSON string instead of
# .structured_output; a plain-text answer yields nothing, i.e. "no schema".
# shellcheck disable=SC2016  # jq program, not shell expansion
CLAUDE_STRUCT_JQ='
  ([inputs | fromjson? | select(type == "object") | select(.type == "result")] | last) as $r
  | if $r == null then empty
    elif ($r.structured_output // null) != null then ($r.structured_output | tojson)
    else (($r.result // "") | fromjson? | select(type == "object") | tojson)
    end'

# The same for codex --json (JSONL, no cost reported): usage comes from the
# final turn.completed, turns are the completed items, and an error event or a
# turn that never completed marks the session failed.
# shellcheck disable=SC2016  # jq program, not shell expansion
CODEX_RESULT_JQ='
  [inputs | fromjson? | select(type == "object")] as $ev
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

# Where one session's artifacts live. Set by the caller before run_agent,
# because run_agent itself runs in a background subshell: "work" is the loop's
# own agent, "review" the evaluator, and neither may clobber the other's files.
REVIEW_ARTIFACT_DIR=""
session_files() {
    local stem
    case "$1" in
        work)   SUPERVISOR_REVIEWER_STATE_FILE=""
                agent_log="$iter_log"
                agent_metrics="$LOG_DIR/.last-metrics"
                agent_struct="$LOG_DIR/.last-struct"
                agent_schema="$LOG_DIR/.schema.json"
                agent_msg="$msg_file"
                codex_msg="$LOG_DIR/.codex-last-msg" ;;
        review) REVIEW_ARTIFACT_DIR="$(mktemp -d "$LOG_DIR/.eval-${iter}.XXXXXX")" \
                    || return 1
                chmod 755 "$REVIEW_ARTIFACT_DIR" || return 1
                stem="${iter_log##*/}"
                stem="${stem%.log}"
                agent_log="$REVIEW_ARTIFACT_DIR/$stem.eval.log"
                agent_metrics="$REVIEW_ARTIFACT_DIR/metrics"
                agent_struct="$REVIEW_ARTIFACT_DIR/struct"
                agent_schema="$REVIEW_ARTIFACT_DIR/schema.json"
                agent_msg="$REVIEW_ARTIFACT_DIR/message"
                SUPERVISOR_REVIEWER_STATE_FILE="$REVIEW_ARTIFACT_DIR/reviewer-state"
                : >"$agent_log" && : >"$agent_metrics" \
                    && : >"$agent_struct" && : >"$agent_msg" \
                    && : >"$SUPERVISOR_REVIEWER_STATE_FILE" \
                    && printf '%s\n' "$SCHEMA_EVAL" >"$agent_schema" \
                    && chmod 644 "$agent_schema" \
                    && chmod 600 "$SUPERVISOR_REVIEWER_STATE_FILE" \
                    || return 1
                # prepare_evaluator_checkout sets the Codex output path after
                # its unpredictable scratch root has been allocated.
                codex_msg="" ;;
    esac
}

# The evaluator may run arbitrary verifier commands, and those commands often
# need a writable checkout for build products. Give both backends an isolated,
# disposable snapshot and put the whole reviewer process under Landlock: writes
# are permitted only beneath EVAL_ROOT, including when a command names the real
# checkout directly or follows an escaping symlink. Removing origin also
# prevents an accidental push back into the source checkout.
EVAL_ROOT=""
EVAL_REPO_DIR=""
isolated_git() {
    # The preceding worker had arbitrary shell access as `agent` and may have
    # poisoned ~/.gitconfig, GIT_* variables, templates, filters, fsmonitor,
    # or hooks. Use only compiled Git defaults plus explicit inert config.
    /usr/bin/env -i \
        HOME="$EVAL_ROOT/home" \
        PATH=/usr/bin:/bin \
        LANG=C LC_ALL=C \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_ATTR_NOSYSTEM=1 \
        /usr/bin/git \
        -c core.hooksPath=/dev/null \
        -c core.fsmonitor=false \
        "$@"
}

supervisor_git() {
    /usr/bin/env -i \
        HOME=/tmp PATH=/usr/bin:/bin LANG=C LC_ALL=C GIT_OPTIONAL_LOCKS=0 \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1 \
        /usr/bin/git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

checkout_tree_digest() {
    local checkout="$1"
    # Canonicalize traversal and deliberately omit uid/gid/timestamps:
    # a non-root copy cannot preserve foreign ownership, while Landlock plus
    # seccomp independently deny evaluator metadata changes in the source.
    # Paths, types, rwx permission bits, link targets, device numbers, and
    # regular-file bytes remain attested. Bytes paths avoid locale and
    # surrogate-escape ambiguities.
    # shellcheck disable=SC2016  # Python program, not shell expansion
    /usr/bin/python3 -I -c '
import hashlib, os, stat, sys

root = os.fsencode(sys.argv[1])
excluded = os.fsencode(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
digest = hashlib.sha256()

def field(value):
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)

def visit(path, relative):
    info = os.lstat(path)
    field(relative)
    field((stat.S_IMODE(info.st_mode) & 0o777).to_bytes(2, "big"))
    if stat.S_ISDIR(info.st_mode):
        field(b"directory")
        entries = sorted(os.scandir(path), key=lambda entry: entry.name)
        for entry in entries:
            if entry.name in (b".git", b".mill"):
                continue
            child_relative = entry.name if relative == b"." else relative + b"/" + entry.name
            if excluded is not None and child_relative == excluded:
                continue
            visit(entry.path, child_relative)
    elif stat.S_ISREG(info.st_mode):
        field(b"regular")
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            opened = os.fstat(descriptor)
            if not stat.S_ISREG(opened.st_mode):
                raise RuntimeError("file type changed during evaluator attestation")
            field(opened.st_size.to_bytes(8, "big"))
            remaining = opened.st_size
            while remaining:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    raise RuntimeError("file shrank during evaluator attestation")
                digest.update(chunk)
                remaining -= len(chunk)
            if os.read(descriptor, 1):
                raise RuntimeError("file grew during evaluator attestation")
        finally:
            os.close(descriptor)
    elif stat.S_ISLNK(info.st_mode):
        field(b"symlink")
        field(os.readlink(path))
    else:
        field(b"special")
        field(stat.S_IFMT(info.st_mode).to_bytes(4, "big"))
        field(info.st_rdev.to_bytes(8, "big"))

visit(root, b".")
print(digest.hexdigest())
' "$checkout" "$EVALUATOR_SOURCE_EXCLUDE"
}

capture_evaluator_source_state() {
    local label="$1"
    local head_file="$REVIEW_ARTIFACT_DIR/source-$label-head"
    local tree_file="$REVIEW_ARTIFACT_DIR/source-$label-tree"
    if ! supervisor_git -C "$REPO_DIR" rev-parse --verify HEAD >"$head_file" 2>/dev/null; then
        : >"$head_file"
    fi
    checkout_tree_digest "$REPO_DIR" >"$tree_file"
}

copy_evaluator_worktree() {
    local exclude_args=()
    # Overlay ignored setup products (node_modules, virtualenvs, generated
    # fixtures, etc.) so the verifier sees the same runnable tree. Never copy
    # git/control metadata: the snapshot gets a fresh independent .git
    # directory and .mill remains the operator's live control channel.
    if [[ -n "$EVALUATOR_SOURCE_EXCLUDE" ]]; then
        exclude_args+=(--exclude="./$EVALUATOR_SOURCE_EXCLUDE"
                       --exclude="./$EVALUATOR_SOURCE_EXCLUDE/*")
    fi
    (cd "$REPO_DIR" && /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/tar \
        --exclude='./.git' --exclude='./.git/*' \
        --exclude='*/.git' --exclude='*/.git/*' \
        --exclude='./.mill' --exclude='./.mill/*' \
        --exclude='*/.mill' --exclude='*/.mill/*' \
        ${exclude_args[@]+"${exclude_args[@]}"} \
        -cf - .) | (cd "$EVAL_REPO_DIR" \
            && /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/tar -xpf -)
}

capture_evaluator_copy_state() {
    # Bind the disposable tree to the exact source state captured before the
    # copy. A second source snapshot also detects a change that landed while
    # tar was walking the checkout.
    checkout_tree_digest "$EVAL_REPO_DIR" \
        >"$REVIEW_ARTIFACT_DIR/snapshot-tree"
    capture_evaluator_source_state copied
}

prepare_evaluator_runtime() {
    local eval_home="$EVAL_ROOT/home"
    mkdir -p "$eval_home/.claude" "$eval_home/.codex" \
        "$EVAL_ROOT/tmp" "$EVAL_ROOT/cache" "$EVAL_ROOT/config" \
        "$EVAL_ROOT/data" "$EVAL_ROOT/state"

    # Build the reviewer's complete environment in a protected scratch file.
    # The pre-sandbox sudo command starts under env -i, and landlock-exec reads
    # this JSON into memory before confinement, so BASH_ENV/LD_PRELOAD and
    # arbitrary worker/frontmatter variables never reach reviewer setup or CLI.
    /usr/bin/python3 -I -c '
from collections import deque
import json, os, stat, sys

path, root, repo, codex_config_path = sys.argv[1:]
environment = {
    "HOME": root + "/home",
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "CI": "true",
    "REPO_DIR": repo,
    "TMPDIR": root + "/tmp",
    "TMP": root + "/tmp",
    "TEMP": root + "/tmp",
    "XDG_CACHE_HOME": root + "/cache",
    "XDG_CONFIG_HOME": root + "/config",
    "XDG_DATA_HOME": root + "/data",
    "XDG_STATE_HOME": root + "/state",
    "CODEX_HOME": root + "/home/.codex",
    "CLAUDE_CONFIG_DIR": root + "/home/.claude",
    "GIT_CONFIG_GLOBAL": root + "/home/.gitconfig",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_ATTR_NOSYSTEM": "1",
}
allowed = (
    "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY",
    "ANTHROPIC_BASE_URL", "OPENAI_BASE_URL",
    "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "no_proxy",
    "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR",
    "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "NO_COLOR",
)
for key in allowed:
    if key in os.environ:
        environment[key] = os.environ[key]
if os.environ.get("AGENTMILL_EVALUATOR_TEST_MODE") == "true":
    for key in ("EVAL_MODE", "REAL_REPO"):
        if key in os.environ:
            environment[key] = os.environ[key]
descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
os.fchmod(descriptor, 0o644)
with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
    json.dump(environment, stream, separators=(",", ":"))

# Codex discovers repository skills even for an untrusted project, and hiding
# its automatic skills list does not prevent an explicit named invocation.
# Mirror the bounded recursive discovery used by Codex 0.147 and disable both
# the logical and canonical identity of every discoverable repository skill.
# Any incomplete traversal aborts evaluator setup instead of leaving a skill
# enabled. Directory symlinks are followed, while file symlinks and hidden
# directories below the root are ignored to match Codex discovery.
MAX_SCAN_DEPTH = 6
MAX_DIRECTORIES = 2000
MAX_ENTRIES = 20000


def toml_string(value):
    if any(0xD800 <= ord(character) <= 0xDFFF for character in value):
        raise ValueError("filesystem path is not valid UTF-8")
    return json.dumps(value, ensure_ascii=False)


def repository_skill_paths(skill_root):
    try:
        root_stat = os.stat(skill_root, follow_symlinks=True)
    except FileNotFoundError:
        return set()
    except OSError as error:
        raise RuntimeError(f"cannot inspect skill root {skill_root!r}: {error}")
    if not stat.S_ISDIR(root_stat.st_mode):
        return set()

    queue = deque([(skill_root, 0)])
    visited = {(root_stat.st_dev, root_stat.st_ino)}
    directory_count = 1
    entry_count = 0
    paths = set()

    while queue:
        directory, depth = queue.popleft()
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(iterator, key=lambda entry: os.fsencode(entry.name))
        except OSError as error:
            raise RuntimeError(f"cannot scan skill directory {directory!r}: {error}")

        for entry in entries:
            entry_count += 1
            if entry_count > MAX_ENTRIES:
                raise RuntimeError(f"skill scan entry limit reached under {skill_root!r}")
            try:
                is_symlink = entry.is_symlink()
                is_directory = entry.is_dir(follow_symlinks=True)
                is_file = entry.is_file(follow_symlinks=True)
            except OSError as error:
                raise RuntimeError(f"cannot inspect skill path {entry.path!r}: {error}")

            # Codex follows directory symlinks but ignores file symlinks.
            if is_symlink and not is_directory:
                continue
            if is_directory:
                if depth >= MAX_SCAN_DEPTH or entry.name.startswith("."):
                    continue
                try:
                    child_stat = entry.stat(follow_symlinks=True)
                except OSError as error:
                    raise RuntimeError(
                        f"cannot inspect skill directory {entry.path!r}: {error}"
                    )
                identity = (child_stat.st_dev, child_stat.st_ino)
                if identity in visited:
                    continue
                directory_count += 1
                if directory_count > MAX_DIRECTORIES:
                    raise RuntimeError(
                        f"skill scan directory limit reached under {skill_root!r}"
                    )
                visited.add(identity)
                queue.append((entry.path, depth + 1))
                continue
            if not is_file or entry.name != "SKILL.md":
                continue

            logical = os.path.abspath(entry.path)
            canonical = os.path.realpath(logical)
            try:
                target_stat = os.stat(canonical, follow_symlinks=True)
            except OSError as error:
                raise RuntimeError(f"cannot resolve skill path {logical!r}: {error}")
            if not stat.S_ISREG(target_stat.st_mode):
                raise RuntimeError(f"skill path is not a regular file: {logical!r}")
            paths.add(logical)
            paths.add(canonical)
    return paths


disabled_skills = set()
for candidate in (
    os.path.join(repo, ".agents", "skills"),
    os.path.join(repo, ".codex", "skills"),
):
    disabled_skills.update(repository_skill_paths(candidate))

config_lines = [
    "project_doc_max_bytes = 0",
    "project_doc_fallback_filenames = []",
    "default_permissions = \"agentmill-reviewer\"",
    "",
    f"[projects.{toml_string(repo)}]",
    "trust_level = \"untrusted\"",
    "",
    "[permissions.agentmill-reviewer.filesystem]",
    "\":root\" = \"write\"",
    "",
    "[permissions.agentmill-reviewer.network]",
    "enabled = false",
    "",
    "[skills]",
    "include_instructions = false",
    "",
    "[skills.bundled]",
    "enabled = false",
]
for skill_path in sorted(disabled_skills, key=os.fsencode):
    config_lines.extend(
        ("", "[[skills.config]]", f"path = {toml_string(skill_path)}", "enabled = false")
    )
descriptor = os.open(
    codex_config_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644
)
os.fchmod(descriptor, 0o644)
with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
    stream.write("\n".join(config_lines) + "\n")
' "$EVAL_ROOT/reviewer-env.json" "$EVAL_ROOT" "$EVAL_REPO_DIR" \
    "$eval_home/.codex/config.toml"

    # Never inherit worker-writable hooks, MCP/provider settings, or CLI
    # instructions. Authentication was snapshotted in supervisor memory before
    # iteration 1; all reviewer preferences are generated from fixed literals.
    printf '%s\n' '{"hasCompletedOnboarding":true}' >"$eval_home/.claude.json"
    printf '%s\n' '{"permissions":{"defaultMode":"dontAsk"}}' \
        >"$eval_home/.claude/settings.json"
    if [[ -n "${CODEX_AUTH_SNAPSHOT:-}" ]]; then
        printf '%s\n' "$CODEX_AUTH_SNAPSHOT" >"$eval_home/.codex/auth.json"
    fi
    # The reviewed tree is evidence, never an instruction source. The fixed
    # config above disables project config/hooks/rules, AGENTS.md discovery,
    # bundled skills, automatic skill instructions, and every repository skill
    # path found by the fail-closed snapshot scan.
    # Codex's named reviewer profile deliberately grants its inner sandbox a
    # root-wide filesystem view: Agent Mill's already-active outer Landlock
    # boundary is authoritative for writes. Keeping network disabled still
    # makes Codex install its child-network seccomp filter. This exact split
    # avoids both bubblewrap namespaces and legacy workspace-policy projection.
    printf '[safe]\n\tdirectory = %s\n' "$EVAL_REPO_DIR" >"$eval_home/.gitconfig"
    : >"$EVAL_ROOT/.codex-eval-msg"
    : >"$REVIEWER_HANDSHAKE_FILE"
    : >"$REVIEWER_ACK_FILE"

    # The production reviewer has a distinct uid as defense in depth. Only its
    # scratch subtrees are writable; the EVAL_ROOT directory itself remains
    # agent-owned so the handshake files cannot be renamed by reviewer code.
    if [[ -x /usr/local/bin/landlock-exec ]]; then
        chmod -R a+rwX "$EVAL_REPO_DIR" "$eval_home" \
            "$EVAL_ROOT/tmp" "$EVAL_ROOT/cache" "$EVAL_ROOT/config" \
            "$EVAL_ROOT/data" "$EVAL_ROOT/state"
        chmod a+rx "$EVAL_ROOT" "$EVAL_ROOT/empty-git-template"
        chmod 666 "$EVAL_ROOT/.codex-eval-msg" "$REVIEWER_HANDSHAKE_FILE"
        chmod 644 "$REVIEWER_ACK_FILE"
    fi
}

initialize_evaluator_snapshot() {
    local template="$EVAL_ROOT/empty-git-template"
    if [[ -x /usr/local/bin/landlock-exec ]]; then
        # Git needs chmod while creating its private repository. Run it as the
        # reviewer uid (which owns nothing outside EVAL_ROOT) with data writes
        # Landlock-confined and process/ioctl escape paths still seccomp-denied.
        # shellcheck disable=SC2016  # $1/$2 belong to the fixed bash -c program
        /usr/bin/timeout --kill-after=1 30 \
            /usr/bin/sudo -n -u agentmill-reviewer \
            /usr/bin/env -i HOME="$EVAL_ROOT/home" PATH=/usr/bin:/bin \
            /usr/bin/python3 -I /usr/local/bin/landlock-exec \
            --write-root "$EVAL_ROOT" --allow-device /dev/null \
            --allow-metadata --max-processes 448 -- \
            /usr/bin/env -i \
            HOME="$EVAL_ROOT/home" PATH=/usr/bin:/bin LANG=C LC_ALL=C \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
            GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1 \
            /bin/bash -ceu '
                repo="$1"; template="$2"
                /usr/bin/git -c safe.directory="$repo" \
                    -c core.hooksPath=/dev/null -c core.fsmonitor=false \
                    -C "$repo" init -q --template="$template"
                /usr/bin/git -c safe.directory="$repo" \
                    -c core.hooksPath=/dev/null -c core.fsmonitor=false \
                    -C "$repo" add -A
                /usr/bin/git -c safe.directory="$repo" \
                    -c core.hooksPath=/dev/null -c core.fsmonitor=false \
                    -c user.name=AgentMill -c user.email=agentmill@localhost \
                    -c commit.gpgSign=false -C "$repo" \
                    commit --allow-empty --no-verify -qm "evaluator snapshot"
            ' agentmill-snapshot "$EVAL_REPO_DIR" "$template"
        return
    fi

    isolated_git -c safe.directory="$EVAL_REPO_DIR" \
            -C "$EVAL_REPO_DIR" init -q --template="$template" \
        && isolated_git -c safe.directory="$EVAL_REPO_DIR" \
            -C "$EVAL_REPO_DIR" add -A \
        && isolated_git -c safe.directory="$EVAL_REPO_DIR" \
            -c user.name=AgentMill -c user.email=agentmill@localhost \
            -c commit.gpgSign=false -C "$EVAL_REPO_DIR" \
            commit --allow-empty --no-verify -qm "evaluator snapshot"
}

prepare_evaluator_checkout() {
    local source_head source_tree source_head_copied source_tree_copied snapshot_tree
    EVAL_ROOT="$(mktemp -d /tmp/agentmill-evaluator.XXXXXX)" \
        || { log "evaluator: could not create an isolated checkout"; return 1; }
    EVAL_REPO_DIR="$EVAL_ROOT/repo"
    codex_msg="$EVAL_ROOT/.codex-eval-msg"
    REVIEWER_HANDSHAKE_FILE="$EVAL_ROOT/.reviewer-session"
    REVIEWER_ACK_FILE="$EVAL_ROOT/.reviewer-session-ack"
    mkdir -p "$EVAL_REPO_DIR" "$EVAL_ROOT/home" "$EVAL_ROOT/empty-git-template" \
        || { log "evaluator: could not prepare isolated Git state"; cleanup_evaluator_checkout; return 1; }
    if [[ "$SHUTDOWN" == false ]] \
        && ! run_interruptible copy_evaluator_worktree >/dev/null 2>&1; then
        log "evaluator: could not populate the isolated checkout"
        cleanup_evaluator_checkout
        return 1
    fi
    # Compare before changing permissions or creating .git: both operations
    # legitimately alter tar metadata in the disposable tree. This immediate
    # check also closes the gap between the pre-copy source snapshot and copy.
    if [[ "$SHUTDOWN" == false ]] \
        && ! run_interruptible capture_evaluator_copy_state; then
        log "evaluator: could not attest the isolated snapshot"
        cleanup_evaluator_checkout
        return 1
    fi
    source_head="$(cat "$REVIEW_ARTIFACT_DIR/source-before-head")"
    source_tree="$(cat "$REVIEW_ARTIFACT_DIR/source-before-tree")"
    source_head_copied="$(cat "$REVIEW_ARTIFACT_DIR/source-copied-head")"
    source_tree_copied="$(cat "$REVIEW_ARTIFACT_DIR/source-copied-tree")"
    snapshot_tree="$(cat "$REVIEW_ARTIFACT_DIR/snapshot-tree")"
    if [[ "$source_head_copied" != "$source_head" \
          || "$source_tree_copied" != "$source_tree" \
          || "$snapshot_tree" != "$source_tree" ]]; then
        log "evaluator: source changed while creating its snapshot — rejecting completion"
        cleanup_evaluator_checkout
        return 1
    fi
    if [[ "$SHUTDOWN" == false ]] \
        && ! run_interruptible prepare_evaluator_runtime >/dev/null 2>&1; then
        log "evaluator: could not prepare isolated CLI state"
        cleanup_evaluator_checkout
        return 1
    fi
    if [[ "$SHUTDOWN" == false ]] \
        && ! run_interruptible initialize_evaluator_snapshot >/dev/null 2>&1; then
        log "evaluator: could not initialize isolated snapshot"
        cleanup_evaluator_checkout
        return 1
    fi
    if [[ "$SHUTDOWN" == true ]]; then
        cleanup_evaluator_checkout
        return 1
    fi
}

cleanup_evaluator_checkout() {
    local checkout="$EVAL_ROOT"
    EVAL_ROOT=""
    EVAL_REPO_DIR=""
    REVIEWER_HANDSHAKE_FILE=""
    REVIEWER_ACK_FILE=""
    [[ -n "$checkout" ]] || return 0
    case "$checkout" in
        /tmp/agentmill-evaluator.*)
            # /tmp disappears with the container. Once shutdown starts, do not
            # stack another 20-second deletion ahead of checkout cleanup.
            [[ "$SHUTDOWN" == true ]] \
                || run_interruptible remove_evaluator_checkout "$checkout" || true
            ;;
        *) log "evaluator: refusing to remove unexpected path: $checkout" ;;
    esac
}

remove_evaluator_checkout() {
    # Reviewer-created directories may be mode 0700. Let their owner make them
    # traversable first; then the agent-owned top-level tree can be removed.
    if [[ -x /usr/local/bin/landlock-exec ]]; then
        /usr/bin/sudo -n -u agentmill-reviewer /usr/bin/chmod -R a+rwX "$1" \
            >/dev/null 2>&1 || true
        chmod -R u+rwX "$1" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$1"
}

# Runs one agent session. Prints the agent's final message; exit code is the
# agent's. Full event stream goes to $agent_log, session metrics (one
# tab-separated line, empty when unparseable) to $agent_metrics, and the
# validated structured reply (empty when the CLI produced none) to
# $agent_struct. $1 = prompt, $2 = mode: work | review (isolated reviewer).
run_agent() {
    local mode="$2" rc=0 args=() review_exec=() claude_schema="$CLAUDE_SCHEMA_WORK"
    local session_repo_dir="$REPO_DIR"
    local session_timeout=("${TIMEOUT_CMD[@]}")
    [[ "$mode" != review ]] || claude_schema="$SCHEMA_EVAL"
    [[ "$mode" != review ]] || session_repo_dir="$EVAL_REPO_DIR"
    SESSION_PID="" SESSION_WATCHDOG_PID="" SESSION_RC=0 SESSION_STOP_REQUESTED=false
    SESSION_REVIEWER_PID="" SESSION_REVIEWER_PGID=""
    SESSION_REVIEWER_PID_START="" SESSION_REVIEWER_PG_START=""
    REVIEWER_CONTROL_FAILED=false
    SESSION_STATE_REQUIRED=false SESSION_SETUP_FAILED=false
    : > "$agent_log"
    : > "$agent_metrics"
    : > "$agent_struct"
    trap on_session_signal TERM INT
    cd "$session_repo_dir" || return 1
    # Do not leak the real checkout's path to a verifier subprocess.
    export REPO_DIR="$session_repo_dir"
    unset OLDPWD
    if [[ "$mode" == review ]]; then
        unset MISSION_FILE
        # Neutralize inherited path controls. Sudo filters TMPDIR even with -E,
        # so the same assignments are also supplied explicitly on its command
        # line below (all are non-secret paths inside the disposable root).
        unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
        unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT
        unset GIT_CONFIG_PARAMETERS
        # A reviewer must never inherit access to mill's privileged DinD
        # sidecar or worker-controlled Docker client configuration.
        unset DOCKER_HOST DOCKER_CONTEXT DOCKER_CERT_PATH DOCKER_TLS_VERIFY DOCKER_CONFIG
        export HOME="$EVAL_ROOT/home" TMPDIR="$EVAL_ROOT/tmp"
        export TMP="$EVAL_ROOT/tmp" TEMP="$EVAL_ROOT/tmp"
        export XDG_CACHE_HOME="$EVAL_ROOT/cache" XDG_CONFIG_HOME="$EVAL_ROOT/config"
        export XDG_DATA_HOME="$EVAL_ROOT/data" XDG_STATE_HOME="$EVAL_ROOT/state"
        export CODEX_HOME="$EVAL_ROOT/home/.codex"
        export CLAUDE_CONFIG_DIR="$EVAL_ROOT/home/.claude"
        export GIT_CONFIG_GLOBAL="$EVAL_ROOT/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
        if [[ -x /usr/local/bin/landlock-exec ]]; then
            # Keep the trusted deadline outside sudo and under the supervisor
            # uid. Reviewer code can signal same-uid ancestors, so an inner
            # timeout could be SIGSTOPed to disable ITER_TIMEOUT.
            review_exec=(/usr/bin/timeout
                         "--kill-after=$TIMEOUT_KILL_AFTER" "$ITER_TIMEOUT"
                         /usr/bin/sudo -n -u agentmill-reviewer
                         /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin
                         /usr/bin/python3 -I /usr/local/bin/landlock-exec
                         --write-root "$EVAL_ROOT"
                         --environment-file "$EVAL_ROOT/reviewer-env.json"
                         --max-processes 448
                         --session-state "$REVIEWER_HANDSHAKE_FILE"
                         --session-ack "$REVIEWER_ACK_FILE"
                         --allow-device /dev/null)
            [[ ! -e /dev/tty ]] || review_exec+=(--allow-device /dev/tty)
            review_exec+=(--)
            session_timeout=()
        fi
    fi
    case "$AGENT" in
        claude)
            [[ -n "$MODEL" ]] && args=(--model "$MODEL")
            [[ -n "$FALLBACK_MODEL" ]] && args+=(--fallback-model "$FALLBACK_MODEL")
            [[ "$MAX_TURNS" -gt 0 ]] && args+=(--max-turns "$MAX_TURNS")
            [[ -n "$MAX_BUDGET_USD" ]] && args+=(--max-budget-usd "$MAX_BUDGET_USD")
            # No session state on disk; --bare additionally skips CLAUDE.md and
            # hook discovery, which plenty of repos deliberately rely on.
            args+=(--no-session-persistence --json-schema "$claude_schema")
            if [[ "$mode" == review ]]; then
                # Bash stays allowed: the reviewer has to run the verifier.
                # --bare also prevents worker-authored CLAUDE.md and project
                # hooks/settings from becoming higher-priority instructions.
                args+=(--bare
                       --disable-slash-commands
                       --allowedTools Bash
                       --disallowedTools "Write,Edit,MultiEdit,NotebookEdit"
                       --permission-mode dontAsk
                       --append-system-prompt "You are a reviewer, not an implementer. Do not intentionally edit source or implement fixes. Verifier-generated artifacts in this disposable checkout are allowed.")
            else
                [[ "$CLAUDE_BARE" == true ]] && args+=(--bare)
                if [[ "$CLAUDE_SYS_PROMPT_FILE" == true ]]; then
                    args+=(--dangerously-skip-permissions --append-system-prompt-file "$PROMPT_FILE")
                else
                    args+=(--dangerously-skip-permissions --append-system-prompt "$(cat "$PROMPT_FILE")")
                fi
            fi
            [[ "${#review_exec[@]}" -eq 0 ]] || SESSION_STATE_REQUIRED=true
            ${review_exec[@]+"${review_exec[@]}"} \
                ${session_timeout[@]+"${session_timeout[@]}"} "$AGENT_BIN" -p "$1" \
                ${args[@]+"${args[@]}"} \
                --output-format stream-json --verbose >>"$agent_log" 2>&1 &
            SESSION_PID=$!
            after_session_launch || true
            wait_session
            rc="$SESSION_RC"
            jq -Rnr "$CLAUDE_RESULT_JQ" "$agent_log" >"$parse_file" 2>/dev/null || : > "$parse_file"
            jq -Rnr "$CLAUDE_STRUCT_JQ" "$agent_log" >"$agent_struct" 2>/dev/null || : > "$agent_struct"
            head -1 "$parse_file" > "$agent_metrics"
            tail -n +2 "$parse_file"
            ;;
        codex)
            [[ -n "$MODEL" ]] && args=(-m "$MODEL")
            # MAX_TURNS/MAX_BUDGET_USD have no codex equivalent; ignored, not an error.
            args+=(--ephemeral --output-schema "$agent_schema")
            if [[ "$mode" == review ]]; then
                # The disposable checkout is writable so verifiers can build,
                # cache, and emit reports without touching the real checkout.
                # The fixed named profile grants Codex a root-wide filesystem
                # view because our outer Landlock boundary is authoritative.
                # Its disabled network permission still applies Codex's child
                # seccomp filter. Full filesystem access takes Codex's direct
                # no-bubblewrap path, so no namespace support is required.
                # Command-line settings cannot be overridden by project config,
                # and fixed settings suppress its hooks.
                args+=(--ignore-rules
                       --disable plugins
                       -c project_doc_max_bytes=0
                       -c 'project_doc_fallback_filenames=[]'
                       -c skills.include_instructions=false
                       -c skills.bundled.enabled=false
                       -c 'approval_policy="never"'
                       -c 'default_permissions="agentmill-reviewer"')
            else
                args+=(--dangerously-bypass-approvals-and-sandbox)
            fi
            # Truncate first: a run that exits without a final message would
            # otherwise replay the previous iteration's (maybe DONE_PROMISE).
            : > "$codex_msg"
            [[ "${#review_exec[@]}" -eq 0 ]] || SESSION_STATE_REQUIRED=true
            ${review_exec[@]+"${review_exec[@]}"} \
                ${session_timeout[@]+"${session_timeout[@]}"} "$AGENT_BIN" exec "$1" \
                ${args[@]+"${args[@]}"} -C "$session_repo_dir" --json \
                -o "$codex_msg" >>"$agent_log" 2>&1 &
            SESSION_PID=$!
            after_session_launch || true
            wait_session
            rc="$SESSION_RC"
            jq -Rnr "$CODEX_RESULT_JQ" "$agent_log" >"$agent_metrics" 2>/dev/null \
                || : > "$agent_metrics"
            # With --output-schema the last message IS the JSON object.
            jq -c 'select(type == "object")' "$codex_msg" >"$agent_struct" 2>/dev/null \
                || : > "$agent_struct"
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

# State snapshots used after a session and again before writing its ledger row.
# They run through run_interruptible so a stuck status filter or rev walk cannot
# hide TERM from the loop. The bounded shutdown cleaner writes the same files.
capture_iteration_state() {
    git status --porcelain --untracked-files=all >"$state_status_file" || return 1
    head_oid >"$state_head_file"
    count_iteration_commits >"$state_count_file"
}

load_iteration_state() {
    WORKTREE_STATUS="$(cat "$state_status_file" 2>/dev/null || true)"
    current_head="$(cat "$state_head_file" 2>/dev/null || true)"
    new_commits="$(cat "$state_count_file" 2>/dev/null || true)"
    [[ "$new_commits" =~ ^[0-9]+$ ]] || new_commits=0
}

refresh_iteration_state() {
    if ! run_interruptible capture_iteration_state; then
        if [[ "$SHUTDOWN" == true ]]; then
            shutdown_clean_checkout
        else
            die "could not read repository state after iteration $iter"
        fi
    fi
    load_iteration_state
}

# Session metrics from run_agent's tab-separated line. Every field may be
# empty ("unknown"); nothing here is allowed to abort the loop.
read_metrics() {
    m_subtype="" m_is_error="" m_cost="" m_turns="" m_duration_ms="" m_tokens_in="" m_tokens_out=""
    [[ -s "$1" ]] || return 0
    IFS=$'\t' read -r m_subtype m_is_error m_cost m_turns m_duration_ms m_tokens_in m_tokens_out \
        < "$1" || true
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

# Just the cost column of a metrics line, for a session whose other numbers the
# loop does not track (the evaluator). Unknown reads as free, never as an error.
metrics_cost() {
    local c=""
    [[ ! -s "$1" ]] || c="$(cut -f3 "$1" 2>/dev/null || true)"
    [[ "$c" =~ ^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] || c=0
    printf '%s' "$c"
}

# Evaluator verdicts are usable only when the surrounding CLI session was
# healthy. Missing metrics are also a failure: both backends emit them from the
# same terminal event that carries or validates the structured verdict.
session_metrics_failed() {
    local subtype="" is_error=""
    [[ -s "$1" ]] || return 0
    IFS=$'\t' read -r subtype is_error _ <"$1" || return 0
    [[ "$is_error" == true || "$subtype" == error* ]]
}

# One field of a structured reply, empty when the file, the object, or the key
# is missing. Nothing a model returned is ever allowed to abort the loop.
json_field() {
    [[ -s "$1" ]] || return 0
    jq -r --arg k "$2" 'select(type == "object") | select(has($k)) | .[$k] | tostring' \
        "$1" 2>/dev/null || true
}

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
        if [[ "$SHUTDOWN" == true ]]; then
            printf '(details skipped during shutdown)\n'
        else
            [[ -z "$range" ]] || git log --oneline "$range" 2>/dev/null || true
        fi
        printf '\nfiles changed:\n'
        if [[ "$SHUTDOWN" == true ]]; then
            printf '(details skipped during shutdown)\n'
        else
            [[ -z "$range" ]] || git diff --stat "$range" 2>/dev/null || true
        fi
        printf '\nfinal message:\n%s\n' "$last_msg"
    } > "${iter_log%.log}.summary" 2>/dev/null || true
}

# Restore every initialized submodule to the commit recorded by the current
# superproject, then discard tracked and untracked changes at every depth.
restore_submodules() {
    # Clean first so an untracked path cannot block checkout of the recorded
    # commit, then clean again after the recursive update at the restored tree.
    # Every step is best-effort: this runs mid-revert under set -e, and a
    # fetch or .gitmodules failure here must not abort the loop with the
    # checkout half-restored — leftover dirt is caught by the next iteration.
    git submodule foreach -q --recursive \
        'git reset -q --hard && git clean -q -ffd' || true
    git submodule sync -q --recursive || true
    git submodule update -q --recursive --force \
        || log "warning: submodule restore incomplete (network or .gitmodules problem?)"
    git submodule foreach -q --recursive \
        'git reset -q --hard && git clean -q -ffd' || true
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

# A verifier validates the checkpoint; its own test artifacts must not become
# the next iteration's dirty baseline.
clean_check_artifacts() {
    refresh_worktree_status
    [[ -n "$WORKTREE_STATUS" ]] || return 0
    git reset -q --hard HEAD
    restore_submodules
    git clean -q -ffd
}

checkpoint_leftovers() {
    local status
    status="$(git status --porcelain --untracked-files=all)" || return 1
    [[ -n "$status" ]] || return 0
    git add -A \
        && git -c commit.gpgSign=false commit --no-verify -qm \
            "[wip] agent leftovers from iteration $iter"
}

restore_iteration_interruptible() {
    if ! run_interruptible restore_iteration; then
        if [[ "$SHUTDOWN" == true ]]; then
            shutdown_clean_checkout
            return 0
        fi
        die "could not restore iteration $iter"
    fi
}

clean_check_artifacts_interruptible() {
    if run_interruptible clean_check_artifacts; then
        return 0
    fi
    if [[ "$SHUTDOWN" == true ]]; then
        shutdown_clean_checkout
        return 1
    fi
    die "could not clean verifier artifacts in iteration $iter"
}

# Docker gives the loop a fixed cleanup window after forwarding TERM. Do not
# spend that window running user-controlled checks or metrics, and do not let a
# slow git hook/filter/submodule operation run until Docker resorts to SIGKILL.
# Commits the agent completed before TERM remain at HEAD; only uncommitted
# residue is discarded. GNU timeout is guaranteed in the image (the env
# fallback exists solely for the host-side smoke tests).
shutdown_clean_checkout() {
    [[ "${shutdown_cleanup_done:-false}" != true ]] || return 0
    shutdown_cleanup_done=true
    log "shutdown: skipping checkpoint/check/metric and discarding uncommitted leftovers"
    : >"$state_head_file"
    : >"$state_status_file"
    : >"$state_count_file"
    # shellcheck disable=SC2016  # positional parameters belong to bash -c
    if ! "${SHUTDOWN_CLEANUP_CMD[@]}" bash -c '
        repo=$1
        head_file=$2
        status_file=$3
        count_file=$4
        start_ref=$5
        cd "$repo" || exit 1
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
            git reset -q --hard HEAD || exit 1
            git submodule foreach -q --recursive \
                '\''git reset -q --hard && git clean -q -ffd'\'' || true
            git submodule update -q --recursive --force || true
            git submodule foreach -q --recursive \
                '\''git reset -q --hard && git clean -q -ffd'\'' || true
        else
            git read-tree --empty || exit 1
        fi
        git clean -q -ffd
        git rev-parse --verify HEAD >"$head_file" 2>/dev/null || : >"$head_file"
        git status --porcelain --untracked-files=all >"$status_file" || exit 1
        if [ -n "$start_ref" ]; then
            git rev-list --count "${start_ref}..HEAD" >"$count_file" 2>/dev/null || echo 0 >"$count_file"
        else
            git rev-list --count HEAD >"$count_file" 2>/dev/null || echo 0 >"$count_file"
        fi
    ' agentmill-shutdown-clean "$REPO_DIR" "$state_head_file" "$state_status_file" \
        "$state_count_file" "$start_ref"; then
        log "warning: shutdown cleanup did not finish within 20 seconds"
    fi
}

# --- metric ratchet ------------------------------------------------------
# METRIC_CMD prints a score; the loop keeps an iteration only when that score
# is strictly better than the best seen so far. The shell has no floats, so
# awk parses and compares.
METRIC_BEST=""

# The last line of a metric run, as a number. Ints, floats, and negatives are
# accepted; anything else yields nothing, which the caller reads as "revert".
metric_number() {
    local last
    last="$(tail -1 "$1" 2>/dev/null | tr -d '\r' || true)"
    last="${last#"${last%%[![:space:]]*}"}"
    last="${last%"${last##*[![:space:]]}"}"
    [[ "$last" =~ ^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$ ]] || return 0
    printf '%s' "$last"
}

# Runs METRIC_CMD with its output appended to $1 (the iteration log) and
# prints the parsed score. Nothing is printed when the command failed or its
# last line is not a number.
# Its stdout is the score, so nothing else may be printed here — the log line
# belongs to the caller.
run_metric() {
    local out="$LOG_DIR/.metric-out" rc=0
    bash -c "$METRIC_CMD" >"$out" 2>>"$1" || rc=$?
    cat "$out" >>"$1" 2>/dev/null || true
    [[ "$rc" -eq 0 ]] || return 0
    metric_number "$out"
}

metric_better() {   # $1 strictly better than $2 in METRIC_DIRECTION?
    awk -v a="$1" -v b="$2" -v d="$METRIC_DIRECTION" \
        'BEGIN { exit !(d == "max" ? a + 0 > b + 0 : a + 0 < b + 0) }'
}

# The run's ledger in the Karpathy results.tsv shape: one row per iteration,
# next to results.jsonl. The summary column is the agent's own one-liner.
write_metric_row() {
    local tsv="$LOG_DIR/metrics.tsv" summary
    [[ -f "$tsv" ]] || printf 'iter\tsha\tmetric\tbest\tstatus\tsummary\n' > "$tsv"
    summary="${last_msg%%$'\n'*}"
    summary="${summary//$'\t'/}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$iter" \
        "${current_head:0:7}" \
        "$metric_value" "$METRIC_BEST" "$status" "$summary" >> "$tsv"
}

# Append a line (or block) under a heading in PROGRESS.md, creating the file
# and the heading when they are missing. An existing heading gets the entry
# right beneath it, so the note cannot land under some later section.
progress_append() {
    local heading="$1" body="$2" tmp="$LOG_DIR/.progress.tmp"
    [[ -f PROGRESS.md ]] || printf '# Progress\n' > PROGRESS.md
    if grep -qxF -- "$heading" PROGRESS.md; then
        h="$heading" b="$body" \
            awk '{ print } $0 == ENVIRON["h"] { print ENVIRON["b"] }' PROGRESS.md > "$tmp" \
            && mv "$tmp" PROGRESS.md
    else
        printf '\n%s\n\n%s\n' "$heading" "$body" >> PROGRESS.md
    fi
}

# The loop's own commits touch nothing but PROGRESS.md.
commit_loop_note() {
    if ! git add -- PROGRESS.md >/dev/null 2>&1 \
        || ! git -c commit.gpgSign=false commit --no-verify -qm "$1" -- PROGRESS.md \
                >/dev/null 2>&1; then
        log "could not commit: $1"
    fi
}

record_verifier_failure() {
    progress_append '## Verifier failures' "$1"
    commit_loop_note '[loop] verifier rejected completion claim'
}

record_evaluator_findings() {
    progress_append "## Evaluator findings (iteration $iter)" "$1"
    commit_loop_note '[loop] evaluator: needs work'
}

# One extra isolated session that reviews the whole run with fresh context.
# Its cost joins the total. PASS lets the claim through; anything else (a
# NEEDS_WORK verdict, an unparseable reply) is a rejection — default-fail.
run_evaluator() {
    local rc=0 verdict findings eval_cost eval_prompt eval_prompt_file
    local source_head source_tree source_head_after source_tree_after
    local attestation_failed=false
    # Pessimistic until a healthy, parseable verdict and unchanged source have
    # both been established. The outer loop classifies infrastructure failures.
    EVALUATOR_SESSION_FAILED=true
    [[ "$SHUTDOWN" != true ]] || return 1
    if ! session_files review; then
        log "evaluator: could not create protected review artifacts"
        return 1
    fi
    # Capture the source before copying it. The copied snapshot and a second
    # source capture below must both match this state before review can start.
    if ! run_interruptible capture_evaluator_source_state before; then
        return 1
    fi
    source_head="$(cat "$REVIEW_ARTIFACT_DIR/source-before-head")"
    source_tree="$(cat "$REVIEW_ARTIFACT_DIR/source-before-tree")"
    if ! prepare_evaluator_checkout; then
        return 1
    fi
    if [[ "$SHUTDOWN" == true ]]; then
        cleanup_evaluator_checkout
        return 1
    fi
    : >"$agent_log"
    : >"$agent_metrics"
    : >"$agent_struct"
    : >"$codex_msg"
    log "evaluator: reviewing the run in a fresh isolated session"
    eval_prompt_file="$REVIEW_ARTIFACT_DIR/prompt"
    : >"$eval_prompt_file"
    if ! run_interruptible build_eval_prompt >"$eval_prompt_file"; then
        cleanup_evaluator_checkout
        return 1
    fi
    eval_prompt="$(cat "$eval_prompt_file" 2>/dev/null || true)"
    if [[ "$SHUTDOWN" == true ]]; then
        cleanup_evaluator_checkout
        return 1
    fi
    REVIEWER_CONTROL_FAILED=false
    run_agent "$eval_prompt" review >"$agent_msg" &
    AGENT_PID=$!
    # A TERM/INT can land after the pre-launch check but before $! is assigned.
    # Re-run the forwarding path once the process group is addressable.
    [[ "$SHUTDOWN" == false ]] || on_signal
    wait_agent
    if [[ "$REVIEWER_CONTROL_FAILED" == true ]]; then
        die "reviewer controller could not confirm process-group cleanup"
    fi
    eval_cost="$(metrics_cost "$agent_metrics")"
    total_cost="$(add_cost "$total_cost" "$eval_cost")"
    verdict="$(json_field "$agent_struct" verdict)"
    findings="$(json_field "$agent_struct" findings)"
    [[ -n "$findings" ]] || findings="$(cat "$agent_msg" 2>/dev/null || true)"
    if [[ "$rc" -ne 0 ]] || session_metrics_failed "$agent_metrics"; then
        log "evaluator: reviewer session failed — rejecting completion"
        verdict=""
        findings=""
    fi
    if ! run_interruptible capture_evaluator_source_state after; then
        cleanup_evaluator_checkout
        return 1
    fi
    source_head_after="$(cat "$REVIEW_ARTIFACT_DIR/source-after-head")"
    source_tree_after="$(cat "$REVIEW_ARTIFACT_DIR/source-after-tree")"
    if [[ "$source_head_after" != "$source_head" \
          || "$source_tree_after" != "$source_tree" ]]; then
        attestation_failed=true
        verdict=NEEDS_WORK
        findings="The real checkout changed while the isolated evaluator was running; completion cannot be attested."
        log "evaluator: real checkout changed during review — rejecting completion"
    fi
    log "evaluator: ${verdict:-unparseable} (\$$(fmt_cost "$eval_cost"); total \$$(fmt_cost "$total_cost"))"
    cleanup_evaluator_checkout
    session_files work
    if [[ "$verdict" == PASS && "$attestation_failed" == false ]]; then
        EVALUATOR_SESSION_FAILED=false
        return 0
    fi
    # Still default-fail on an empty verdict, but that means the review
    # session itself broke — there are no findings worth committing.
    if [[ "$attestation_failed" == true ]]; then
        log "evaluator: source attestation failed — rejecting the claim"
    elif [[ -n "$verdict" ]]; then
        EVALUATOR_SESSION_FAILED=false
        log "evaluator: needs work — continuing"
        if ! run_interruptible record_evaluator_findings "$findings"; then
            [[ "$SHUTDOWN" != true ]] || shutdown_clean_checkout
        fi
    else
        log "evaluator: no verdict — rejecting the claim, nothing to record"
    fi
    return 1
}

# Everything that must hold before a done claim may stop the loop: the
# completion verifier (DONE_CMD, else a CHECK_CMD green on this iteration) and,
# when enabled, the evaluator. A rejection is recorded in PROGRESS.md so the
# next session knows why its predecessor's claim did not stick.
verify_done_claim() {
    local out="$LOG_DIR/.done-check" label="" cmd="" ok=true failure_note=""
    if [[ -n "$DONE_CMD" ]]; then
        label=DONE_CMD cmd="$DONE_CMD"
    elif [[ -n "$CHECK_CMD" && "$check_passed" != true ]]; then
        label=CHECK_CMD cmd="$CHECK_CMD"
    fi
    if [[ -n "$cmd" ]]; then
        log "$label: $cmd"
        run_interruptible bash -c "$cmd" >"$out" 2>&1 || ok=false
        if [[ "$SHUTDOWN" == true ]]; then
            shutdown_clean_checkout
            return 1
        fi
        cat "$out" >>"$iter_log" 2>/dev/null || true
        # Clean on both paths, and before the rejection note: the verifier's
        # leftovers must not become the next iteration's dirty baseline, and
        # clean_check_artifacts hard-resets the tree, which would eat an
        # uncommitted PROGRESS.md edit ($out lives in $LOG_DIR, it survives).
        if ! clean_check_artifacts_interruptible; then
            return 1
        fi
        if [[ "$ok" != true ]]; then
            log "agent claimed done but $label failed — continuing"
            failure_note="- iteration $iter: $label failed: $(head -3 "$out" | tr '\n' ' ')"
            if ! run_interruptible record_verifier_failure "$failure_note"; then
                [[ "$SHUTDOWN" != true ]] || shutdown_clean_checkout
            fi
            return 1
        fi
    fi
    [[ "$EVALUATOR" == true ]] || return 0
    run_evaluator
}

# Structured final messages. claude takes the schema inline and returns the
# validated object in the result event; codex takes a file and insists on
# additionalProperties:false with every property required — hence the second,
# stricter copy of the same shape (the prompt says `blocked` may be false).
CLAUDE_SCHEMA_WORK='{"type":"object","properties":{"done":{"type":"boolean"},"summary":{"type":"string"},"blocked":{"type":"boolean"}},"required":["done","summary"],"additionalProperties":false}'
CODEX_SCHEMA_WORK='{"type":"object","properties":{"done":{"type":"boolean"},"summary":{"type":"string"},"blocked":{"type":"boolean"}},"required":["done","summary","blocked"],"additionalProperties":false}'
SCHEMA_EVAL='{"type":"object","properties":{"verdict":{"type":"string","enum":["PASS","NEEDS_WORK"]},"findings":{"type":"string"}},"required":["verdict","findings"],"additionalProperties":false}'
printf '%s\n' "$CODEX_SCHEMA_WORK" > "$LOG_DIR/.schema.json"
DONE_PROMISE_JSON="$(jq -nr --arg promise "$DONE_PROMISE" \
    '$promise | tojson | gsub("<"; "\\u003c") | gsub(">"; "\\u003e")')" \
    || die "could not encode DONE_PROMISE"

log "starting loop: agent=$AGENT model=${MODEL:-<cli default>} max_iterations=$MAX_ITERATIONS"
results_log="$LOG_DIR/results.jsonl"
msg_file="$LOG_DIR/.last-msg"
parse_file="$LOG_DIR/.last-parse"
iter=0 errors=0 noops=0 stop_reason="" total_cost=0
RUN_BASE="$(head_oid)"                   # what the evaluator diffs the run against
CURRENT_MISSION=""

# Baseline measurement happens before iteration 1, but it has the same
# shutdown/cleanup contract as an iteration: a hung metric or git cleanup must
# be addressable by the signal trap, and interrupted artifacts must be removed
# without turning an operator shutdown into a fatal missing-metric error.
start_ref="$RUN_BASE"
start_head_ref="$(git symbolic-ref -q HEAD 2>/dev/null || true)"
shutdown_cleanup_done=false
state_head_file="$LOG_DIR/.iteration-head"
state_status_file="$LOG_DIR/.iteration-status"
state_count_file="$LOG_DIR/.iteration-count"
: >"$state_head_file"
: >"$state_status_file"
: >"$state_count_file"

# The baseline is what iteration 1 has to beat. Measured on the clean tree,
# before any session runs; without it there is nothing to ratchet against, so
# a metric that cannot be read here is fatal rather than silently disabled.
if [[ -n "$METRIC_CMD" ]]; then
    log "metric: $METRIC_CMD"
    baseline_value_file="$LOG_DIR/.metric-baseline-value"
    : >"$baseline_value_file"
    if ! run_interruptible run_metric "$LOG_DIR/metric-baseline.log" >"$baseline_value_file"; then
        if [[ "$SHUTDOWN" != true ]]; then
            die "METRIC_CMD baseline execution failed"
        fi
    fi
    if [[ "$SHUTDOWN" == true ]]; then
        shutdown_clean_checkout
    elif ! run_interruptible clean_check_artifacts; then
        if [[ "$SHUTDOWN" == true ]]; then
            shutdown_clean_checkout
        else
            die "could not clean METRIC_CMD baseline artifacts"
        fi
    fi
    if [[ "$SHUTDOWN" != true ]]; then
        METRIC_BEST="$(cat "$baseline_value_file" 2>/dev/null || true)"
        [[ -n "$METRIC_BEST" ]] || die "METRIC_CMD produced no baseline number — cannot ratchet"
        log "baseline metric: $METRIC_BEST"
    fi
fi

while true; do
    if [[ "$SHUTDOWN" == true ]]; then stop_reason="shutdown signal"; break; fi
    if stop_file_requested; then stop_reason="stop file"; break; fi
    if ! CURRENT_MISSION="$(mission_body)"; then
        die "$(basename "$MISSION_FILE") has an opening frontmatter fence but no closing ---"
    fi
    iter=$((iter + 1))
    # --verify so an unborn HEAD leaves start_ref empty instead of the literal "HEAD".
    start_ref="$(head_oid)"
    start_head_ref="$(git symbolic-ref -q HEAD 2>/dev/null || true)"
    iter_log="$LOG_DIR/iter-${iter}-$(git rev-parse --short=7 --verify HEAD 2>/dev/null || echo init).log"
    log "==== iteration $iter ===="

    status=kept rc=0 check_passed=false metric_ran=false metric_value=""
    shutdown_cleanup_done=false
    state_head_file="$LOG_DIR/.iteration-head"
    state_status_file="$LOG_DIR/.iteration-status"
    state_count_file="$LOG_DIR/.iteration-count"
    : >"$state_head_file"
    : >"$state_status_file"
    : >"$state_count_file"
    : > "$msg_file"
    read_steer
    [[ -f PROGRESS.md ]] || log "initializer session (no PROGRESS.md)"
    # Backgrounded so TERM/INT is handled while the agent runs, not after it.
    note_mission_changes
    session_files work
    # Truncate synchronously: a pending shutdown may kill the background
    # wrapper before run_agent reaches its own defensive truncation.
    : >"$agent_log"
    : >"$agent_metrics"
    : >"$agent_struct"
    : >"$codex_msg"
    work_prompt_file="$LOG_DIR/.work-prompt"
    : >"$work_prompt_file"
    if ! run_interruptible build_prompt >"$work_prompt_file"; then
        if [[ "$SHUTDOWN" != true ]]; then
            die "could not build the iteration prompt"
        fi
    fi
    work_prompt="$(cat "$work_prompt_file" 2>/dev/null || true)"
    if [[ "$SHUTDOWN" == true ]]; then
        stop_reason="shutdown signal"
        iter=$((iter - 1))
        break
    fi
    started_at="$(date +%s)"
    if [[ "$SHUTDOWN" == true ]]; then
        stop_reason="shutdown signal"
        iter=$((iter - 1))
        break
    fi
    run_agent "$work_prompt" work >"$msg_file" &
    AGENT_PID=$!
    # A TERM/INT can land after the pre-launch check but before $! is assigned.
    # Re-run the forwarding path once the process group is addressable.
    [[ "$SHUTDOWN" == false ]] || on_signal
    wait_agent
    duration_s=$(( $(date +%s) - started_at ))
    last_msg="$(cat "$msg_file" 2>/dev/null || true)"
    read_metrics "$agent_metrics"

    # The agent answers against a schema: `done` is the completion claim and
    # `summary` replaces the raw final message everywhere. DONE_PROMISE stays
    # the fallback for CLIs (or runs) that produced no structured reply.
    agent_done=false agent_blocked=false
    struct_done="$(json_field "$agent_struct" 'done')"
    if [[ -n "$struct_done" ]]; then
        struct_summary="$(json_field "$agent_struct" summary)"
        [[ -z "$struct_summary" ]] || last_msg="$struct_summary"
        [[ "$struct_done" != true ]] || agent_done=true
        [[ "$(json_field "$agent_struct" blocked)" != true ]] || agent_blocked=true
    elif [[ -n "$DONE_PROMISE" && "$last_msg" == *"$DONE_PROMISE"* ]]; then
        agent_done=true
    fi
    cost="${m_cost:-0}"
    total_cost="$(add_cost "$total_cost" "$cost")"
    # The CLI can report failure with exit 0 (max turns, an execution error);
    # trust the result event over the exit code.
    agent_error=false classified_failure=false
    [[ "$m_is_error" == true || "$m_subtype" == error* ]] && agent_error=true
    if [[ "$rc" -ne 0 || "$agent_error" == true ]]; then
        classified_failure=true
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
    if [[ "$SHUTDOWN" == true ]]; then
        shutdown_clean_checkout
    elif ! run_interruptible checkpoint_leftovers; then
        if [[ "$SHUTDOWN" == true ]]; then
            shutdown_clean_checkout
        else
            snapshot_failed=true
            log "could not checkpoint iteration $iter leftovers"
        fi
    fi

    refresh_iteration_state
    mutated=false
    [[ "$current_head" != "$start_ref" || -n "$WORKTREE_STATUS" ]] && mutated=true

    # Ratchet: keep the iteration only if CHECK_CMD passes (Carlini pattern —
    # kept history is always green, a bad iteration costs only tokens). Runs
    # whenever the repo changed, including after an agent error or timeout:
    # that is exactly when the tree is most likely half-finished.
    if [[ "$SHUTDOWN" != true && "$mutated" == true && "$snapshot_failed" == true ]]; then
        log "checkpoint failed — reverting iteration $iter"
        restore_iteration_interruptible
        new_commits=0
        status=reverted
    elif [[ "$SHUTDOWN" != true && "$mutated" == true && -n "$CHECK_CMD" ]]; then
        log "check: $CHECK_CMD"
        if ! run_interruptible bash -c "$CHECK_CMD" >>"$iter_log" 2>&1; then
            if [[ "$SHUTDOWN" == true ]]; then
                shutdown_clean_checkout
            else
                log "check failed — reverting iteration $iter"
                restore_iteration_interruptible
                new_commits=0
                status=reverted
            fi
        elif [[ "$SHUTDOWN" == true ]]; then
            shutdown_clean_checkout
        else
            check_passed=true
            clean_check_artifacts_interruptible || true
        fi
        if [[ "$SHUTDOWN" == true ]]; then
            # The cleaner preserves agent commits but removes verifier output.
            check_passed=false
        elif [[ "$check_passed" != true && "$status" != reverted ]]; then
            log "check failed — reverting iteration $iter"
            restore_iteration_interruptible
            new_commits=0
            status=reverted
        fi
    fi

    # Metric ratchet: a green check only says the tree is not broken. When
    # METRIC_CMD is set the iteration must also move the number the right way
    # — anything else, including a score that cannot be read, is reverted.
    if [[ "$SHUTDOWN" != true && -n "$METRIC_CMD" && "$mutated" == true \
          && "$status" != reverted ]]; then
        metric_ran=true
        log "metric: $METRIC_CMD"
        metric_out="$LOG_DIR/.metric-value"
        : > "$metric_out"
        run_interruptible run_metric "$iter_log" >"$metric_out" || true
        metric_value="$(cat "$metric_out" 2>/dev/null || true)"
        if [[ "$SHUTDOWN" == true ]]; then
            shutdown_clean_checkout
            metric_ran=false
        elif ! clean_check_artifacts_interruptible; then
            metric_ran=false
        elif [[ -z "$metric_value" ]]; then
            log "metric unparseable — reverting"
            restore_iteration_interruptible
            new_commits=0
            status=reverted
        elif metric_better "$metric_value" "$METRIC_BEST"; then
            log "iteration $iter: kept (metric $metric_value → best $METRIC_BEST)"
            METRIC_BEST="$metric_value"
        else
            log "metric $metric_value not better than $METRIC_BEST — reverting"
            restore_iteration_interruptible
            new_commits=0
            status=reverted
        fi
    fi

    # Health check: a session that "succeeded" in a couple of turns without
    # touching the repo is almost always a broken key or model, not a genuine
    # no-op — count it as an error so MAX_ERRORS trips fast instead of burning
    # MAX_NOOPS iterations. Skipped when the turn count is unknown.
    if [[ "$classified_failure" == false && "$mutated" == false && -n "$m_turns" \
          && "$MIN_TURNS" -gt 0 && "$m_turns" -lt "$MIN_TURNS" ]]; then
        classified_failure=true
        errors=$((errors + 1))
        status=error
        log "agent produced no work in $m_turns turns — treating as error (consecutive errors: $errors/$MAX_ERRORS)"
    fi
    # Repeated reverts make no progress either, so they count toward MAX_NOOPS.
    if [[ "$status" == kept && "$mutated" == false ]]; then
        status=noop
    fi

    # A completion claim only stops the loop once the verifier — and, when
    # enabled, the fresh-context evaluator — has confirmed it.
    completion_ok=false
    EVALUATOR_SESSION_FAILED=false
    if [[ "$SHUTDOWN" != true && "$agent_done" == true \
          && "$status" != error && "$status" != reverted ]]; then
        if verify_done_claim; then completion_ok=true; fi
        refresh_iteration_state                    # a rejection commits a note
        [[ "$SHUTDOWN" != true ]] || completion_ok=false
    fi
    if [[ "$EVALUATOR_SESSION_FAILED" == true ]]; then
        classified_failure=true
        errors=$((errors + 1))
        status=error
        log "evaluator infrastructure failed (consecutive errors: $errors/$MAX_ERRORS)"
    fi
    # A successful iteration is not healthy until every late classifier,
    # including its completion evaluator, has passed.
    [[ "$classified_failure" == true ]] || errors=0

    # A blocked agent made no headway either, whatever it committed.
    [[ "$agent_blocked" != true ]] || log "agent reports blocked"
    case "$status" in
        noop|reverted) noops=$((noops + 1)) ;;
        kept) if [[ "$agent_blocked" == true ]]; then noops=$((noops + 1)); else noops=0; fi ;;
    esac

    # Refresh after a ratchet restore or evaluator note so the ledger describes
    # the final checkout, not the pre-checkpoint state.
    refresh_iteration_state

    # Fields the agent CLI did not report are simply left out, never guessed.
    extra=""
    [[ "$STEERED" != true ]] || extra+=",\"steered\":true"
    [[ "$metric_ran" != true ]] \
        || extra+=",\"metric\":${metric_value:-null},\"best\":$METRIC_BEST"
    [[ -z "$m_turns" ]]      || extra+=",\"turns\":$m_turns"
    [[ -z "$m_tokens_in" ]]  || extra+=",\"tokens_in\":$m_tokens_in"
    [[ -z "$m_tokens_out" ]] || extra+=",\"tokens_out\":$m_tokens_out"
    result_head="${current_head:0:7}"
    [[ -n "$result_head" ]] || result_head=none
    printf '{"iter":%d,"agent":"%s","status":"%s","commits":%d,"head":"%s","ts":"%s"' \
        "$iter" "$AGENT" "$status" "$new_commits" \
        "$result_head" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$results_log"
    printf ',"subtype":"%s","cost_usd":%s,"duration_s":%d,"done":%s,"blocked":%s%s}\n' \
        "$m_subtype" "$(add_cost "$cost" 0)" "$duration_s" \
        "$agent_done" "$agent_blocked" "$extra" >>"$results_log"
    log "iteration $iter: $status ($new_commits commits, \$$(fmt_cost "$cost"), ${m_turns:-?} turns, ${duration_s}s; total \$$(fmt_cost "$total_cost"))"
    if [[ "$SHUTDOWN" == true ]]; then
        write_summary
        [[ -z "$METRIC_CMD" ]] || write_metric_row
    else
        if ! run_interruptible write_summary; then
            [[ "$SHUTDOWN" != true ]] || shutdown_clean_checkout
        fi
        if [[ -n "$METRIC_CMD" ]] && ! run_interruptible write_metric_row; then
            [[ "$SHUTDOWN" != true ]] || shutdown_clean_checkout
        fi
    fi

    if [[ "$completion_ok" == true ]]; then
        if [[ "$EVALUATOR" == true ]]; then
            stop_reason="agent signaled done, evaluator PASS"
        else
            stop_reason="agent signaled $DONE_PROMISE"
        fi
        break
    fi
    if stop_file_requested; then stop_reason="stop file"; break; fi
    if [[ -n "$MAX_TOTAL_BUDGET_USD" ]] && cost_reached "$total_cost" "$MAX_TOTAL_BUDGET_USD"; then
        stop_reason="budget exhausted (\$$(fmt_cost "$total_cost") of \$$(fmt_cost "$MAX_TOTAL_BUDGET_USD"))"
        break
    fi
    [[ "$MAX_ERRORS" -gt 0 && "$errors" -ge "$MAX_ERRORS" ]] && { stop_reason="$MAX_ERRORS consecutive errors"; break; }
    [[ "$MAX_NOOPS" -gt 0 && "$noops" -ge "$MAX_NOOPS" ]] && { stop_reason="$MAX_NOOPS consecutive no-progress iterations"; break; }
    [[ "$MAX_ITERATIONS" -gt 0 && "$iter" -ge "$MAX_ITERATIONS" ]] && { stop_reason="max iterations"; break; }
    [[ "$SHUTDOWN" == true ]] && { stop_reason="shutdown signal"; break; }

    if [[ "$classified_failure" == true ]]; then
        # 60s, 120s, 240s ... at the default base, capped so an unbounded
        # MAX_ERRORS neither sleeps for hours nor overflows the arithmetic.
        backoff=$((ERROR_BACKOFF * 2 ** (errors < 16 ? errors : 16)))
        [[ "$backoff" -le "$MAX_BACKOFF" ]] || backoff="$MAX_BACKOFF"
        pause "$backoff"
    else
        pause "$LOOP_DELAY"
    fi
done

# The brake is spent once honored; leaving it would stop the next run at once.
rm -f "$STOP_FILE"

log "loop finished after $iter iterations: $stop_reason"
log "total cost: \$$(fmt_cost "$total_cost") across $iter iterations"
