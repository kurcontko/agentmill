#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

repo="$TMPDIR/repo"
logs="$TMPDIR/logs"
prompts="$TMPDIR/prompts"
home="$TMPDIR/home"
mkdir -p "$repo" "$logs" "$prompts" "$home"

git -C "$repo" init -q -b main
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m base

cat > "$prompts/PROMPT.md" <<'PROMPT'
# Test Ralph Task

When complete, signal the harness.
PROMPT

cat > "$TMPDIR/setup-claude-config.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.claude"
SH
chmod +x "$TMPDIR/setup-claude-config.sh"

cat > "$TMPDIR/setup-repo-env.sh" <<'SH'
#!/usr/bin/env bash
return 0 2>/dev/null || exit 0
SH
chmod +x "$TMPDIR/setup-repo-env.sh"

cat > "$TMPDIR/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
    printf 'Claude Code 2.1.111\n'
    exit 0
fi
echo "fake claude should not run when AUTO_RALPH uses auto-trust" >&2
exit 1
SH
chmod +x "$TMPDIR/claude"

cat > "$TMPDIR/auto-trust.exp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${CLAUDE_INITIAL_PROMPT:-}" in
    *"/ralph-loop:ralph-loop"*"--completion-promise TASK_COMPLETE"*) ;;
    *)
        echo "missing Ralph loop prompt" >&2
        exit 2
        ;;
esac
grep -q '<promise>TASK_COMPLETE</promise>' .claude/rules/agentmill-ralph-task.md
touch "$DONE_FILE"
SH
chmod +x "$TMPDIR/auto-trust.exp"

set +e
HOME="$home" \
PATH="$TMPDIR:$PATH" \
REPO_DIR="$repo" \
UPSTREAM_DIR="$TMPDIR/no-upstream" \
LOG_DIR="$logs" \
MEMORY_DIR="$TMPDIR/memory" \
RESULTS_LOG="$logs/results.tsv" \
CONVERGENCE_LOG="$logs/convergence.tsv" \
USAGE_LOG="$logs/usage.tsv" \
PROMPT_FILE="$prompts/PROMPT.md" \
AGENT_ID="ralph" \
AGENTMILL_RUN_ID="ralph-completion-test" \
AGENTMILL_ENTRYPOINT_COMMON="$REPO_ROOT/entrypoint-common.sh" \
AGENTMILL_SETUP_CLAUDE_CONFIG="$TMPDIR/setup-claude-config.sh" \
AGENTMILL_SETUP_REPO_ENV="$TMPDIR/setup-repo-env.sh" \
AGENTMILL_CLAUDE_COMMAND="$TMPDIR/claude" \
AGENTMILL_AUTO_TRUST_COMMAND="$TMPDIR/auto-trust.exp" \
ANTHROPIC_API_KEY="test-key" \
AUTO_RALPH=true \
AUTO_RALPH_MAX_ITERATIONS=2 \
AUTO_RALPH_COMPLETION_PROMISE=TASK_COMPLETE \
RESPAWN=true \
AUTO_COMMIT=off \
DONE_FILE="$TMPDIR/done" \
SENTINEL_SIGNAL_FLAG_FILE="$TMPDIR/sentinel" \
    bash "$REPO_ROOT/entrypoint-tui.sh" > "$TMPDIR/stdout.log" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { cat "$TMPDIR/stdout.log" >&2; exit "$rc"; }

[[ ! -e "$repo/.claude/settings.local.json" ]]
[[ ! -e "$repo/.claude/rules/agentmill-ralph-task.md" ]]

python3 - "$logs/events.jsonl" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]

configured = [event for event in events if event["type"] == "run.configured"]
assert configured, events
assert configured[-1]["payload"]["auto_ralph"] is True, configured[-1]

convergence = [event for event in events if event["type"] == "convergence.evaluated"]
assert convergence, events
assert convergence[-1]["payload"]["gate"] == "done_file", convergence[-1]
assert convergence[-1]["payload"]["passed"] is True, convergence[-1]

stops = [event for event in events if event["type"] == "loop.stopped"]
assert stops, events
assert stops[-1]["payload"]["reason"] == "completion", stops[-1]
assert stops[-1]["payload"]["mode"] == "tui", stops[-1]
assert stops[-1]["payload"]["gate"] == "done_file", stops[-1]

completed = [event for event in events if event["type"] == "run.completed"]
assert completed, events
assert completed[-1]["payload"]["iterations"] == 1, completed[-1]
PY

echo "PASS test_ralph_completion_gate"
