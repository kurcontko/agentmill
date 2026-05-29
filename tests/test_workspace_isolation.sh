#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="workspace"
export ITERATION="0"
export AGENTMILL_RUN_ID="workspace-test"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

assert_denies_direct_standard() {
    AGENTMILL_PROFILE_LEVEL=standard
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_ALLOW_DIRECT_HOST_REPO=false
    if enforce_workspace_isolation false >/dev/null; then
        echo "expected standard direct host repo mode to be denied" >&2
        exit 1
    fi
}

assert_allows_readonly_clone() {
    AGENTMILL_PROFILE_LEVEL=standard
    AGENTMILL_WORKSPACE_MODE=readonly-clone
    AGENTMILL_ALLOW_DIRECT_HOST_REPO=false
    enforce_workspace_isolation true >/dev/null
}

assert_allows_explicit_direct_override() {
    AGENTMILL_PROFILE_LEVEL=untrusted
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_ALLOW_DIRECT_HOST_REPO=true
    enforce_workspace_isolation false >/dev/null
}

assert_denies_direct_standard
assert_allows_readonly_clone
assert_allows_explicit_direct_override

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1])]
denied = [event for event in events if event["type"] == "policy.denied"]
allowed = [event for event in events if event["type"] == "policy.allowed"]

assert any(event["payload"]["reason"] == "direct_host_repo_disallowed" for event in denied), events
assert any(event["payload"]["reason"] == "workspace_isolation" for event in allowed), events
assert any(event["payload"]["reason"] == "direct_host_repo_override" for event in allowed), events
PY

echo "PASS test_workspace_isolation"
