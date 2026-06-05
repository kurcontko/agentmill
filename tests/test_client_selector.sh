#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

selector_output="$(
    LOG_DIR="$TMPDIR/logs-selector" \
    AGENT_ID=selector \
    AGENTMILL_CLIENT=fake \
    bash -c '. "$0"; client_select "${AGENTMILL_CLIENT:-${AGENTMILL_PROVIDER:-claude}}"; printf "%s\n" "$AGENTMILL_CLIENT"' "$REPO_ROOT/entrypoint-common.sh"
)"
[[ "$selector_output" == *"fake" ]]

provider_output="$(
    LOG_DIR="$TMPDIR/logs-provider" \
    AGENT_ID=provider \
    AGENTMILL_PROVIDER=fake \
    bash -c '. "$0"; client_select "${AGENTMILL_CLIENT:-${AGENTMILL_PROVIDER:-claude}}"; printf "%s\n" "$AGENTMILL_CLIENT"' "$REPO_ROOT/entrypoint-common.sh"
)"
[[ "$provider_output" == *"fake" ]]

set +e
bad_output="$(
    LOG_DIR="$TMPDIR/logs-bad" \
    AGENT_ID=bad \
    AGENTMILL_CLIENT=unknown \
    bash -c '. "$0"; client_select "${AGENTMILL_CLIENT:-${AGENTMILL_PROVIDER:-claude}}"' "$REPO_ROOT/entrypoint-common.sh" 2>&1
)"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]]
[[ "$bad_output" == *"Unknown AGENTMILL_CLIENT"* ]]

echo "PASS test_client_selector"
