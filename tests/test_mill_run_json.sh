#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
repo="$TMPDIR/repo"
mkdir -p "$harness/logs" "$TMPDIR/bin"
cp "$REPO_ROOT/mill" "$REPO_ROOT/docker-compose.yml" "$harness/"
chmod +x "$harness/mill"

git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m base

cat > "$TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
    exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
    compose_file=""
    prev=""
    for arg in "$@"; do
        if [[ "$prev" == "-f" ]]; then
            compose_file="$arg"
            break
        fi
        prev="$arg"
    done
    harness_dir="$(cd "$(dirname "$compose_file")" && pwd)"
    mkdir -p "$harness_dir/logs"
    printf 'compose progress must stay on stderr\n'
    python3 - "$harness_dir/logs/events.jsonl" "${AGENTMILL_RUN_ID:?}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
run_id = sys.argv[2]
events = [
    {
        "version": 1,
        "timestamp": "2026-05-29T00:00:00Z",
        "run_id": run_id,
        "agent_id": "1",
        "profile": "trusted",
        "iteration": 1,
        "type": "iteration.started",
        "payload": {"prompt_file": "/prompts/PROMPT.md"},
    },
    {
        "version": 1,
        "timestamp": "2026-05-29T00:00:01Z",
        "run_id": run_id,
        "agent_id": "1",
        "profile": "trusted",
        "iteration": 1,
        "type": "iteration.completed",
        "payload": {"status": "noop", "commits": 0},
    },
]
with path.open("a", encoding="utf-8") as handle:
    for event in events:
        print(json.dumps(event, sort_keys=True), file=handle)
PY
    exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
SH
chmod +x "$TMPDIR/bin/docker"

stdout="$TMPDIR/stdout.jsonl"
stderr="$TMPDIR/stderr.log"
PATH="$TMPDIR/bin:$PATH" "$harness/mill" run "$repo" --json --profile-level trusted --iterations 1 >"$stdout" 2>"$stderr"

grep -q 'compose progress must stay on stderr' "$stderr"
if grep -q 'compose progress must stay on stderr' "$stdout"; then
    echo "compose progress leaked to JSON stdout" >&2
    exit 1
fi

python3 - "$stdout" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
types = [event["type"] for event in events]

assert types == ["iteration.started", "iteration.completed", "mill.run.completed"], types
assert len({event["run_id"] for event in events}) == 1, events
assert events[-1]["agent_id"] == "cli"
assert events[-1]["payload"]["exit_code"] == 0
assert events[-1]["payload"]["status"] == "ok"
PY

set +e
detach_output="$(PATH="$TMPDIR/bin:$PATH" "$harness/mill" run "$repo" --json -d 2>&1)"
detach_rc=$?
set -e
[[ "$detach_rc" -ne 0 ]] || { echo "expected --json --detach to fail" >&2; exit 1; }
[[ "$detach_output" == *"cannot be combined with --detach"* ]]

echo "PASS test_mill_run_json"
