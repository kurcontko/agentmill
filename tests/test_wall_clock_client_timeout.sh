#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="wall"
export AGENTMILL_RUN_ID="wall-clock-test"
export AGENTMILL_CLIENT=claude
export AGENTMILL_CLAUDE_OUTPUT_FORMAT=text
export MAX_WALL_SECONDS=1
export RUN_START_TIME="$(date +%s)"
export WALL_CLOCK_SIGNAL_FLAG_FILE="$TMPDIR/wall-clock.flag"

mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec sleep 10
SH
chmod +x "$TMPDIR/bin/claude"
export AGENTMILL_CLAUDE_COMMAND="$TMPDIR/bin/claude"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

started="$(date +%s)"
set +e
client_run_headless "slow prompt" "$TMPDIR/session.log"
rc=$?
set -e
elapsed=$(( $(date +%s) - started ))

[[ "$rc" -ne 0 ]]
[[ "$elapsed" -lt 5 ]]
[[ -f "$WALL_CLOCK_SIGNAL_FLAG_FILE" ]]

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
wall = [event for event in events if event["type"] == "budget.exhausted" and event["payload"].get("budget") == "wall_seconds"]
assert wall, events
assert wall[-1]["payload"]["scope"] == "client", wall[-1]
PY

echo "PASS test_wall_clock_client_timeout"
