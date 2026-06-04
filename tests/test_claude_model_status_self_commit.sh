#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

repo="$TMPDIR/repo"
logs="$TMPDIR/logs"
prompts="$TMPDIR/prompts"
home="$TMPDIR/home"
mkdir -p "$repo" "$logs" "$prompts" "$home" "$TMPDIR/memory"

git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m base

cat > "$prompts/PROMPT.md" <<'PROMPT'
Make one committed change and signal completion.
PROMPT

cat > "$TMPDIR/setup-claude-config.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.claude"
SH
cat > "$TMPDIR/setup-repo-env.sh" <<'SH'
#!/usr/bin/env bash
return 0 2>/dev/null || exit 0
SH
chmod +x "$TMPDIR/setup-claude-config.sh" "$TMPDIR/setup-repo-env.sh"

cat > "$TMPDIR/claude-headless" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
    printf 'Claude Code 2.1.154\n'
    exit 0
fi
printf '%s\n' "$@" > "${CLAUDE_ARGS_LOG:?}"
printf 'self committed\n' > self-committed.txt
git add self-committed.txt
git commit -q -m "agent: self commit"
touch "${DONE_FILE:?}"
exit 143
SH
chmod +x "$TMPDIR/claude-headless"

set +e
REPO_DIR="$repo" \
HOME="$home" \
UPSTREAM_DIR="$TMPDIR/no-upstream" \
LOG_DIR="$logs" \
MEMORY_DIR="$TMPDIR/memory" \
RESULTS_LOG="$logs/results.tsv" \
CONVERGENCE_LOG="$logs/convergence.tsv" \
USAGE_LOG="$logs/usage.tsv" \
PROMPT_FILE="$prompts/PROMPT.md" \
AGENT_ID="claude" \
AGENTMILL_RUN_ID="claude-model-status-test" \
AGENTMILL_ENTRYPOINT_COMMON="$REPO_ROOT/entrypoint-common.sh" \
AGENTMILL_SETUP_CLAUDE_CONFIG="$TMPDIR/setup-claude-config.sh" \
AGENTMILL_SETUP_REPO_ENV="$TMPDIR/setup-repo-env.sh" \
AGENTMILL_CLIENT=claude \
AGENTMILL_CLAUDE_COMMAND="$TMPDIR/claude-headless" \
ANTHROPIC_API_KEY="test-key" \
MODEL=opus \
AUTO_COMMIT=off \
MAX_ITERATIONS=1 \
LOOP_DELAY=0 \
DONE_FILE="$TMPDIR/done" \
CLAUDE_ARGS_LOG="$TMPDIR/claude-headless-args.log" \
    bash "$REPO_ROOT/entrypoint.sh" > "$TMPDIR/headless-stdout.log" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { cat "$TMPDIR/headless-stdout.log" >&2; exit "$rc"; }

grep -Fx -- '--model' "$TMPDIR/claude-headless-args.log"
grep -Fx -- 'claude-opus-4-8' "$TMPDIR/claude-headless-args.log"
[[ "$(git -C "$repo" show HEAD:self-committed.txt)" == "self committed" ]]

python3 - "$logs/results.tsv" "$logs/status-claude.json" "$logs/events.jsonl" <<'PY'
import csv
import json
import sys
from pathlib import Path

rows = list(csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8"), delimiter="\t"))
assert rows[-1]["commits"] == "1", rows
assert int(rows[-1]["files_changed"]) >= 1, rows
assert rows[-1]["status"] == "kept", rows
assert rows[-1]["description"] == "done", rows

status = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
assert status["agent"] == "claude", status
assert status["iteration"] == 1, status
assert status["max_iterations"] == 1, status
assert status["state"] == "kept", status
assert status["detail"] == "done", status
assert status["model"] == "claude-opus-4-8", status

events = [json.loads(line) for line in open(sys.argv[3], encoding="utf-8")]
configured = next(event for event in events if event["type"] == "run.configured")
assert configured["payload"]["model"] == "claude-opus-4-8", configured
completed = next(event for event in events if event["type"] == "iteration.completed")
assert completed["payload"]["commits"] == 1, completed
assert completed["payload"]["status"] == "kept", completed
assert not any(event["type"] == "iteration.failed" for event in events), events
PY

cat > "$TMPDIR/claude-tui" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${TUI_ARGS_LOG:?}"
SH
chmod +x "$TMPDIR/claude-tui"

export HOME="$TMPDIR/tui-home"
export LOG_DIR="$TMPDIR/tui-logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="tui"
export AGENTMILL_RUN_ID="claude-tui-model-test"
export AGENTMILL_CLIENT=claude
export AGENTMILL_CLIENT_TRANSPORT=native
export AGENTMILL_CLAUDE_COMMAND="$TMPDIR/claude-tui"
export MODEL="claude-sonnet-4-6"
export SKIP_PROMPT=true
export TUI_ARGS_LOG="$TMPDIR/claude-tui-args.log"
mkdir -p "$HOME" "$LOG_DIR"

# shellcheck source=../entrypoint-common.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/entrypoint-common.sh"
client_run_tui
grep -Fx -- '--model' "$TUI_ARGS_LOG"
grep -Fx -- 'claude-sonnet-4-6' "$TUI_ARGS_LOG"

echo "PASS test_claude_model_status_self_commit"
