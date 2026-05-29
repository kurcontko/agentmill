#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "SKIP test_smoke_integration (ANTHROPIC_API_KEY not set)"
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP test_smoke_integration (docker not found)"
    exit 0
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "SKIP test_smoke_integration (docker compose unavailable)"
    exit 0
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

repo="$TMPDIR/repo"
mkdir -p "$repo"
cp -R "$REPO_ROOT/tests/fixtures/repo/." "$repo/"
git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
git -C "$repo" add README.md TASK.md
git -C "$repo" commit -q -m smoke-fixture

run_id="smoke-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
stdout="$TMPDIR/stdout.log"
stderr="$TMPDIR/stderr.log"
timeout_seconds="${AGENTMILL_SMOKE_TIMEOUT_SECONDS:-420}"

set +e
(
    cd "$REPO_ROOT"
    AGENTMILL_RUN_ID="$run_id" \
    AUTO_COMMIT=off \
    LOOP_DELAY=0 \
    MAX_WALL_SECONDS="${AGENTMILL_SMOKE_MAX_WALL_SECONDS:-300}" \
    timeout "$timeout_seconds" ./mill run "$repo" --iterations 1 --model haiku-4-5
) >"$stdout" 2>"$stderr"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
    echo "mill smoke command failed with exit code $rc" >&2
    echo "--- stdout tail ---" >&2
    tail -80 "$stdout" >&2 || true
    echo "--- stderr tail ---" >&2
    tail -80 "$stderr" >&2 || true
    exit "$rc"
fi

python3 - "$REPO_ROOT/logs/events.jsonl" "$run_id" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
run_id = sys.argv[2]
events = []
if path.exists():
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("run_id") == run_id:
                events.append(event)

types = [event["type"] for event in events]
assert "run.configured" in types, types
assert "iteration.started" in types, types
assert "claude.completed" in types, types
assert "iteration.completed" in types, types
assert "run.completed" in types, types

configured = next(event for event in events if event["type"] == "run.configured")
assert configured["payload"]["model"] == "claude-haiku-4-5-20251001", configured
assert configured["payload"]["model_raw"] == "haiku-4-5", configured
assert configured["payload"]["max_iterations"] == 1, configured

completed = next(event for event in reversed(events) if event["type"] == "run.completed")
assert completed["payload"]["iterations"] >= 1, completed
PY

echo "PASS test_smoke_integration"
