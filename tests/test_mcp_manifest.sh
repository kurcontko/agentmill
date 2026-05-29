#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="mcp"
export ITERATION=0
export AGENTMILL_RUN_ID="mcp-test"
export AGENTMILL_ROLE="researcher-depth"
export AGENTMILL_PROFILE_LEVEL="standard"
export AGENTMILL_MCP_ALLOWLIST="BrightData"
export MCP_FAKE_TOOL_DESCRIPTION="stable search tool"

mkdir -p "$HOME/.claude" "$TMPDIR/bin"
export PATH="$TMPDIR/bin:$PATH"
cat > "$TMPDIR/bin/brightdata" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

for line in sys.stdin:
    try:
        message = json.loads(line)
    except json.JSONDecodeError:
        continue
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        print(json.dumps({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "brightdata-test", "version": "1"},
            },
        }), flush=True)
    elif method == "tools/list":
        print(json.dumps({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "tools": [
                    {
                        "name": "search_engine",
                        "description": os.environ.get("MCP_FAKE_TOOL_DESCRIPTION", "stable search tool"),
                        "inputSchema": {
                            "type": "object",
                            "properties": {"query": {"type": "string"}},
                            "required": ["query"],
                        },
                    }
                ]
            },
        }), flush=True)
PY
chmod +x "$TMPDIR/bin/brightdata"

cat > "$HOME/.claude.json" <<'JSON'
{
  "mcpServers": {
    "BrightData": {"command": "brightdata", "args": ["mcp"]},
    "DeployTool": {"command": "deploy", "args": ["--token", "secret"]}
  },
  "projects": {
    "/workspace/repo": {
      "enabledMcpjsonServers": ["BrightData"],
      "mcpServers": {
        "BrightData": {"command": "brightdata-project"}
      }
    }
  }
}
JSON
cat > "$HOME/.claude/settings.json" <<'JSON'
{"enableAllProjectMcpServers": true}
JSON

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

enforce_mcp_manifest_stability
baseline="$(mcp_manifest_baseline_file)"
[[ -f "$baseline" ]]
enforce_mcp_manifest_stability

manifest="$LOG_DIR/mcp-manifest-mcp-test-mcp.json"
[[ -f "$manifest" ]]

python3 - "$manifest" "$EVENT_LOG" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
events = [json.loads(line) for line in open(sys.argv[2])]

assert manifest["run_id"] == "mcp-test"
assert manifest["agent_id"] == "mcp"
assert manifest["role"] == "researcher-depth"
assert manifest["profile"] == "standard"
assert manifest["mcp_allowlist"] == ["BrightData"]
assert manifest["enable_all_project_mcp"] is True
bright = next(server for server in manifest["servers"] if server["name"] == "BrightData")
assert bright["transport"] == "stdio"
assert bright["command"] == "brightdata"
assert bright["command_path_kind"] == "path"
assert bright["tool_snapshot_status"] == "ok"
assert bright["tool_count"] == 1
assert bright["tools"][0]["name"] == "search_engine"
assert "description" not in bright["tools"][0]
assert "inputSchema" not in bright["tools"][0]
assert any(server["name"] == "DeployTool" for server in manifest["servers"])
assert all("args" not in server for server in manifest["servers"])
assert "secret" not in json.dumps(manifest)

event = next(event for event in events if event["type"] == "mcp.manifest")
assert event["payload"]["server_count"] == len(manifest["servers"])
assert event["payload"]["manifest_hash"] == manifest["manifest_hash"]

allowed = [event for event in events if event["type"] == "policy.allowed"]
assert any(event["payload"]["reason"] == "mcp_manifest_baseline" for event in allowed)
assert any(event["payload"]["reason"] == "mcp_manifest_stable" for event in allowed)
PY

export MCP_FAKE_TOOL_DESCRIPTION="changed search tool"
if enforce_mcp_manifest_stability; then
    echo "expected MCP live tool metadata drift to be denied" >&2
    exit 1
fi

python3 - "$manifest" "$EVENT_LOG" "$baseline" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
events = [json.loads(line) for line in open(sys.argv[2])]
baseline_hash = open(sys.argv[3]).read().strip()

bright = next(server for server in manifest["servers"] if server["name"] == "BrightData")
assert bright["tool_snapshot_status"] == "ok"
assert bright["tool_count"] == 1
denied = [event for event in events if event["type"] == "policy.denied"]
changed = [event for event in denied if event["payload"]["reason"] == "mcp_manifest_changed"]
assert changed, denied
event = changed[-1]
assert event["payload"]["baseline_hash"] == baseline_hash
assert event["payload"]["manifest_hash"] == manifest["manifest_hash"]
assert event["payload"]["manifest_hash"] != baseline_hash
assert event["payload"]["snapshot_file"] == sys.argv[1]
PY

export MCP_FAKE_TOOL_DESCRIPTION="stable search tool"
python3 - "$HOME/.claude.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
config = json.loads(path.read_text())
config["mcpServers"]["DeployTool"]["command"] = "deploy-v2"
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
PY

if enforce_mcp_manifest_stability; then
    echo "expected MCP manifest drift to be denied" >&2
    exit 1
fi

python3 - "$manifest" "$EVENT_LOG" "$baseline" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
events = [json.loads(line) for line in open(sys.argv[2])]
baseline_hash = open(sys.argv[3]).read().strip()

denied = [event for event in events if event["type"] == "policy.denied"]
changed = [event for event in denied if event["payload"]["reason"] == "mcp_manifest_changed"]
assert changed, denied
event = changed[-1]
assert event["payload"]["baseline_hash"] == baseline_hash
assert event["payload"]["manifest_hash"] == manifest["manifest_hash"]
assert event["payload"]["manifest_hash"] != baseline_hash
assert event["payload"]["snapshot_file"] == sys.argv[1]
PY

echo "PASS test_mcp_manifest"
