#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="client-home"
export AGENTMILL_RUN_ID="client-home-test"
cat > "$TMPDIR/setup-claude-config.sh" <<SH
#!/usr/bin/env bash
exec bash "$REPO_ROOT/setup-claude-config.sh"
SH
chmod +x "$TMPDIR/setup-claude-config.sh"
export AGENTMILL_SETUP_CLAUDE_CONFIG="$TMPDIR/setup-claude-config.sh"

mkdir -p "$HOME/.claude" "$TMPDIR/host-plugins/plugin-a" "$TMPDIR/host-skills/skill-a"
cat > "$HOME/.claude.json" <<'JSON'
{"hasCompletedOnboarding": true, "existing": "host-home-default"}
JSON
cat > "$HOME/.claude/settings.json" <<'JSON'
{"permissions": {"allow": ["Read"], "defaultMode": "acceptEdits"}}
JSON
cat > "$TMPDIR/host-claude.json" <<'JSON'
{
  "mcpServers": {
    "BrightData": {"command": "brightdata"},
    "DeployTool": {"command": "deploy"}
  },
  "projects": {
    "/host/project": {
      "hasTrustDialogAccepted": true,
      "allowedTools": ["Bash(curl:*)"],
      "enabledMcpjsonServers": ["BrightData", "DeployTool"],
      "mcpServers": {
        "BrightData": {"command": "brightdata-project"},
        "DeployTool": {"command": "deploy-project"}
      }
    }
  }
}
JSON
cat > "$TMPDIR/settings.host.json" <<'JSON'
{
  "permissions": {"allow": ["Bash(curl:*)"], "defaultMode": "bypassPermissions"},
  "enabledPlugins": ["plugin-a"],
  "env": {"HOST_SECRET": "not-forwarded"}
}
JSON
printf 'plugin\n' > "$TMPDIR/host-plugins/plugin-a/plugin.txt"
printf 'skill\n' > "$TMPDIR/host-skills/skill-a/SKILL.md"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

export HOST_CONFIG="$TMPDIR/host-claude.json"
export HOST_SETTINGS="$TMPDIR/settings.host.json"
export HOST_PLUGINS="$TMPDIR/host-plugins"
export HOST_SKILLS="$TMPDIR/host-skills"
export AGENTMILL_CLIENT=claude
export AGENTMILL_PROFILE_LEVEL=standard
export AGENTMILL_MCP_ALLOWLIST=BrightData
client_select claude
client_prepare_home

selected="$HOME/.agentmill/clients/claude"
[[ -f "$selected/.claude.json" ]]
[[ -f "$selected/.claude/settings.json" ]]
[[ -L "$HOME/.claude.json" ]]
[[ -L "$HOME/.claude/settings.json" ]]
[[ "$(readlink "$HOME/.claude.json")" == "$selected/.claude.json" ]]
[[ "$(readlink "$HOME/.claude/settings.json")" == "$selected/.claude/settings.json" ]]

python3 - "$selected/.claude.json" "$selected/.claude/settings.json" <<'PY'
import json
import sys

cfg = json.load(open(sys.argv[1], encoding="utf-8"))
settings = json.load(open(sys.argv[2], encoding="utf-8"))

assert cfg["existing"] == "host-home-default", cfg
assert set(cfg["mcpServers"]) == {"BrightData"}, cfg
project = cfg["projects"]["/workspace/repo"]
assert set(project["mcpServers"]) == {"BrightData"}, project
assert project["enabledMcpjsonServers"] == ["BrightData"], project
assert "allowedTools" not in project, project

assert settings["permissions"]["defaultMode"] == "acceptEdits", settings
assert settings["permissions"]["allow"] == ["Read"], settings
assert "enabledPlugins" not in settings, settings
assert "env" not in settings, settings
PY

[[ ! -e "$HOME/.claude/plugins" ]]
[[ ! -e "$HOME/.claude/skills" ]]

AGENTMILL_CLIENT=fake
AGENTMILL_CLIENT_HOME=
AGENTMILL_CLIENT_HOME_ROOT="$TMPDIR/fake-root"
client_select fake
client_prepare_home
[[ "$AGENTMILL_CLIENT_HOME" == "$TMPDIR/fake-root/fake" ]]
[[ -d "$AGENTMILL_CLIENT_HOME" ]]

echo "PASS test_client_home_isolation"
