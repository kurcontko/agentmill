#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export MEMORY_DIR="$TMPDIR/memory"
export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENTMILL_RUN_ID="memory-concurrent"
export AGENTMILL_PROFILE_LEVEL="standard"
mkdir -p "$MEMORY_DIR" "$LOG_DIR"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

pids=()
for i in $(seq 1 30); do
    (
        export AGENT_ID="writer-$i"
        memory_write concurrent "$(printf 'BEGIN:%s\nEND:%s' "$i" "$i")" "$AGENT_ID"
    ) &
    pids+=("$!")
done

for pid in "${pids[@]}"; do
    wait "$pid"
done

python3 - "$MEMORY_DIR/concurrent.md" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
assert text.startswith("---\ntype: decisions\ncreated: "), text
assert "\nlast_iteration: 0\n---\n" in text, text
entries = re.findall(
    r"\n---\nagent: writer-(\d+)\ntimestamp: [^\n]+\n---\nBEGIN:(\d+)\nEND:(\d+)\n",
    text,
)

assert len(entries) == 30, (len(entries), text)
seen = set()
for agent_id, begin_id, end_id in entries:
    assert agent_id == begin_id == end_id, (agent_id, begin_id, end_id)
    seen.add(int(agent_id))
assert seen == set(range(1, 31)), seen
assert text.count("\n---\n") == 61, text
PY

echo "PASS test_memory_concurrent"
