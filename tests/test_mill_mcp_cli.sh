#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

manifest="$TMPDIR/mcp-manifest-test-agent.json"
cat > "$manifest" <<'JSON'
{
  "version": 1,
  "run_id": "run-123",
  "agent_id": "agent",
  "role": "researcher-depth",
  "profile": "standard",
  "mcp_allowlist": ["BrightData"],
  "enable_all_project_mcp": true,
  "manifest_hash": "abc123",
  "servers": [
    {"name": "BrightData", "source": "claude.json:mcpServers", "config_hash": "hash1", "transport": "stdio", "command": "sh", "command_path_kind": "path"},
    {"name": "DeployTool", "source": "project:/workspace/repo:mcpServers", "config_hash": "hash2", "transport": "stdio", "command": "deploy-tool", "command_path_kind": "path"}
  ]
}
JSON

list_output="$("$REPO_ROOT/mill" mcp list --manifest "$manifest")"
[[ "$list_output" == *"BrightData"*"claude.json:mcpServers"* ]]
[[ "$list_output" == *"DeployTool"*"project:/workspace/repo:mcpServers"* ]]

json_output="$("$REPO_ROOT/mill" mcp list --manifest "$manifest" --json)"
python3 - "$json_output" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
assert data["run_id"] == "run-123"
assert [server["name"] for server in data["servers"]] == ["BrightData", "DeployTool"]
PY

"$REPO_ROOT/mill" mcp test BrightData --manifest "$manifest" >/tmp/agentmill-mcp-test.out
grep -q "OK BrightData" /tmp/agentmill-mcp-test.out
"$REPO_ROOT/mill" mcp test BrightData --manifest "$manifest" --require-reachable >/tmp/agentmill-mcp-reachable.out
grep -q "stdio command: sh" /tmp/agentmill-mcp-reachable.out

if "$REPO_ROOT/mill" mcp test DeployTool --manifest "$manifest" >/tmp/agentmill-mcp-denied.out 2>&1; then
    echo "expected non-allowlisted server test to fail" >&2
    exit 1
fi
grep -q "not in manifest allowlist" /tmp/agentmill-mcp-denied.out

echo "PASS test_mill_mcp_cli"
