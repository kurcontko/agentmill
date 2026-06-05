#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="risk"
export ITERATION=1
export AGENTMILL_RUN_ID="risk-test"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

repo="$TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'safe\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m init
cd "$repo"

printf 'normal\n' >> README.md
AGENTMILL_PROFILE_LEVEL=standard AGENTMILL_ALLOW_HIGH_RISK_CHANGES=false enforce_high_risk_change_policy

mkdir -p .github/workflows
printf 'name: ci\n' > .github/workflows/ci.yml
if AGENTMILL_PROFILE_LEVEL=standard AGENTMILL_ALLOW_HIGH_RISK_CHANGES=false enforce_high_risk_change_policy; then
    echo "expected high-risk workflow change to be denied for standard profile" >&2
    exit 1
fi

AGENTMILL_PROFILE_LEVEL=trusted AGENTMILL_ALLOW_HIGH_RISK_CHANGES=false enforce_high_risk_change_policy
AGENTMILL_PROFILE_LEVEL=standard AGENTMILL_ALLOW_HIGH_RISK_CHANGES=true enforce_high_risk_change_policy

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1])]
assert any(event["type"] == "policy.denied" and event["payload"]["reason"] == "high_risk_changes" for event in events), events
assert any(event["type"] == "policy.allowed" and event["payload"]["reason"] == "high_risk_changes_allowed" for event in events), events
assert any("ci-workflow" in event["payload"].get("categories", "") for event in events), events
PY

echo "PASS test_high_risk_policy"
