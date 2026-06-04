#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

write_fixture() {
    local case_dir="$1"
    mkdir -p \
        "$case_dir/home/.claude" \
        "$case_dir/workspace/repo/.claude/skills/skill-a" \
        "$case_dir/workspace/repo/.claude/agents" \
        "$case_dir/host-plugins/plugin-a" \
        "$case_dir/host-skills/skill-a" \
        "$case_dir/host-skills/skill-b" \
        "$case_dir/host-agents/agent-a" \
        "$case_dir/host-commands"

    printf 'plugin\n' > "$case_dir/host-plugins/plugin-a/plugin.txt"
    printf 'skill\n' > "$case_dir/host-skills/skill-a/SKILL.md"
    printf 'skill\n' > "$case_dir/host-skills/skill-b/SKILL.md"
    printf 'agent\n' > "$case_dir/host-agents/agent-a/agent.md"
    printf 'command\n' > "$case_dir/host-commands/release.md"
    printf 'project skill\n' > "$case_dir/workspace/repo/.claude/skills/skill-a/SKILL.md"
    printf 'project agent\n' > "$case_dir/workspace/repo/.claude/agents/agent-a.md"
    cat > "$case_dir/host-plugins/installed_plugins.json" <<'JSON'
{
  "plugins": [
    {
      "name": "plugin-a",
      "installPath": "/Users/test/.claude/plugins/plugin-a"
    },
    {
      "name": "plugin-b",
      "installLocation": "/Users/test/.claude/plugins/plugin-b/.claude/plugins/nested",
      "note": "/Users/test/.claude/plugins/should-not-change"
    }
  ],
  "note": "/Users/test/.claude/plugins/should-not-change"
}
JSON

    cat > "$case_dir/host-claude.json" <<'JSON'
{
  "mcpServers": {
    "BrightData": {"command": "brightdata"},
    "DeployTool": {"command": "deploy"}
  },
  "projects": {
    "/host/project": {
      "hasTrustDialogAccepted": true,
      "allowedTools": ["Bash(curl:*)", "mcp__DeployTool__*"],
      "hasClaudeMdExternalIncludesApproved": true,
      "hasClaudeMdExternalIncludesWarningShown": true,
      "enabledMcpjsonServers": ["BrightData", "DeployTool"],
      "mcpServers": {
        "BrightData": {"command": "brightdata-project"},
        "DeployTool": {"command": "deploy-project"}
      }
    }
  }
}
JSON

    cat > "$case_dir/settings.host.json" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(curl:*)"],
    "deny": ["Bash(rm -rf:*)"],
    "defaultMode": "bypassPermissions"
  },
  "enabledPlugins": ["plugin-a"],
  "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": []}]},
  "env": {"HOST_SECRET": "should-not-forward-by-default"}
}
JSON

    cat > "$case_dir/home/.claude/settings.json" <<'JSON'
{"permissions": {"allow": ["Read"], "defaultMode": "acceptEdits"}}
JSON
}

run_setup_case() {
    local case_name="$1"
    shift
    local case_dir="$TMPDIR/$case_name"
    write_fixture "$case_dir"

    env \
        HOME="$case_dir/home" \
        HOST_CONFIG="$case_dir/host-claude.json" \
        TARGET_CONFIG="$case_dir/home/.claude.json" \
        HOST_SETTINGS="$case_dir/settings.host.json" \
        TARGET_SETTINGS="$case_dir/home/.claude/settings.json" \
        HOST_PLUGINS="$case_dir/host-plugins" \
        TARGET_PLUGINS="$case_dir/home/.claude/plugins" \
        HOST_SKILLS="$case_dir/host-skills" \
        TARGET_SKILLS="$case_dir/home/.claude/skills" \
        HOST_AGENTS="$case_dir/host-agents" \
        TARGET_AGENTS="$case_dir/home/.claude/agents" \
        HOST_COMMANDS="$case_dir/host-commands" \
        TARGET_COMMANDS="$case_dir/home/.claude/commands" \
        "$@" \
        bash "$REPO_ROOT/setup-claude-config.sh"

    printf '%s\n' "$case_dir"
}

standard_dir="$(run_setup_case standard \
    AGENTMILL_PROFILE_LEVEL=standard \
    AGENTMILL_MCP_ALLOWLIST=BrightData)"

explicit_dir="$(run_setup_case explicit \
    AGENTMILL_PROFILE_LEVEL=standard \
    AGENTMILL_MCP_ALLOWLIST=BrightData \
    AGENTMILL_FORWARD_HOST_TOOLS=true \
    AGENTMILL_FORWARD_HOST_HOOKS=true \
    AGENTMILL_FORWARD_HOST_ENV=true \
    AGENTMILL_FORWARD_HOST_EXTENSIONS=true \
    AGENTMILL_SKILL_ALLOWLIST=skill-a)"

unscoped_extensions_dir="$(run_setup_case unscoped-extensions \
    AGENTMILL_PROFILE_LEVEL=standard \
    AGENTMILL_MCP_ALLOWLIST=BrightData \
    AGENTMILL_FORWARD_HOST_EXTENSIONS=true)"

trusted_dir="$(run_setup_case trusted AGENTMILL_PROFILE_LEVEL=trusted)"

python3 - "$standard_dir" "$explicit_dir" "$unscoped_extensions_dir" "$trusted_dir" <<'PY'
import json
import sys
from pathlib import Path


def load(case_dir: str):
    root = Path(case_dir)
    return (
        json.loads((root / "home/.claude.json").read_text()),
        json.loads((root / "home/.claude/settings.json").read_text()),
        root,
    )


standard_cfg, standard_settings, standard_root = load(sys.argv[1])
explicit_cfg, explicit_settings, explicit_root = load(sys.argv[2])
unscoped_cfg, unscoped_settings, unscoped_root = load(sys.argv[3])
trusted_cfg, trusted_settings, trusted_root = load(sys.argv[4])

for root in (standard_root, explicit_root, unscoped_root, trusted_root):
    assert (root / "workspace/repo/.claude/skills/skill-a/SKILL.md").read_text() == "project skill\n"
    assert (root / "workspace/repo/.claude/agents/agent-a.md").read_text() == "project agent\n"

standard_project = standard_cfg["projects"]["/workspace/repo"]
assert "allowedTools" not in standard_project, standard_project
assert standard_project["hasTrustDialogHooksAccepted"] is False
assert set(standard_project["mcpServers"]) == {"BrightData"}
assert standard_project["enabledMcpjsonServers"] == ["BrightData"]
assert set(standard_cfg["mcpServers"]) == {"BrightData"}
assert standard_settings["permissions"]["allow"] == ["Read"], standard_settings
assert standard_settings["permissions"]["defaultMode"] == "acceptEdits"
assert "enabledPlugins" not in standard_settings
assert "hooks" not in standard_settings
assert "env" not in standard_settings
assert not (standard_root / "home/.claude/plugins").exists()
assert not (standard_root / "home/.claude/skills").exists()
assert not (standard_root / "home/.claude/agents").exists()
assert not (standard_root / "home/.claude/commands").exists()

explicit_project = explicit_cfg["projects"]["/workspace/repo"]
assert "Bash(curl:*)" in explicit_project["allowedTools"], explicit_project
assert explicit_project["hasTrustDialogHooksAccepted"] is True
assert explicit_settings["permissions"]["defaultMode"] == "acceptEdits"
assert "Bash(curl:*)" in explicit_settings["permissions"]["allow"]
assert "Bash(rm -rf:*)" in explicit_settings["permissions"]["deny"]
assert explicit_settings["enabledPlugins"] == ["plugin-a"]
assert "hooks" in explicit_settings
assert explicit_settings["env"]["HOST_SECRET"] == "should-not-forward-by-default"
assert (explicit_root / "home/.claude/plugins/plugin-a/plugin.txt").is_file()
plugin_manifest = json.loads((explicit_root / "home/.claude/plugins/installed_plugins.json").read_text())
plugin_a, plugin_b = plugin_manifest["plugins"]
assert plugin_a["installPath"] == "/home/agent/.claude/plugins/plugin-a", plugin_manifest
assert plugin_b["installLocation"] == "/home/agent/.claude/plugins/nested", plugin_manifest
assert plugin_b["note"] == "/Users/test/.claude/plugins/should-not-change", plugin_manifest
assert plugin_manifest["note"] == "/Users/test/.claude/plugins/should-not-change", plugin_manifest
assert (explicit_root / "home/.claude/skills/skill-a/SKILL.md").is_file()
assert not (explicit_root / "home/.claude/skills/skill-b/SKILL.md").exists()
assert (explicit_root / "home/.claude/agents/agent-a/agent.md").is_file()
assert (explicit_root / "home/.claude/commands/release.md").is_file()

unscoped_project = unscoped_cfg["projects"]["/workspace/repo"]
assert "allowedTools" not in unscoped_project, unscoped_project
assert unscoped_settings["enabledPlugins"] == ["plugin-a"]
assert (unscoped_root / "home/.claude/plugins/plugin-a/plugin.txt").is_file()
assert not (unscoped_root / "home/.claude/skills").exists()
assert (unscoped_root / "home/.claude/agents/agent-a/agent.md").is_file()
assert (unscoped_root / "home/.claude/commands/release.md").is_file()

trusted_project = trusted_cfg["projects"]["/workspace/repo"]
assert "Bash(curl:*)" in trusted_project["allowedTools"], trusted_project
assert trusted_project["hasTrustDialogHooksAccepted"] is True
assert trusted_settings["permissions"]["defaultMode"] == "bypassPermissions"
assert set(trusted_cfg["mcpServers"]) == {"BrightData", "DeployTool"}
assert (trusted_root / "home/.claude/plugins/plugin-a/plugin.txt").is_file()
assert (trusted_root / "home/.claude/skills/skill-a/SKILL.md").is_file()
assert (trusted_root / "home/.claude/skills/skill-b/SKILL.md").is_file()
assert (trusted_root / "home/.claude/commands/release.md").is_file()
PY

grep -q '~/.claude/commands:/home/agent/.host-commands:ro' "$REPO_ROOT/docker-compose.yml"

empty_settings_dir="$TMPDIR/empty-settings"
mkdir -p "$empty_settings_dir/home/.claude"
printf '{}\n' > "$empty_settings_dir/host-claude.json"
printf '{}\n' > "$empty_settings_dir/settings.host.json"
env \
    HOME="$empty_settings_dir/home" \
    HOST_CONFIG="$empty_settings_dir/host-claude.json" \
    TARGET_CONFIG="$empty_settings_dir/home/.claude.json" \
    HOST_SETTINGS="$empty_settings_dir/settings.host.json" \
    TARGET_SETTINGS="$empty_settings_dir/home/.claude/settings.json" \
    AGENTMILL_PROFILE_LEVEL=trusted \
    bash "$REPO_ROOT/setup-claude-config.sh"
python3 - "$empty_settings_dir/home/.claude/settings.json" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1]))
assert settings["permissions"]["defaultMode"] == "bypassPermissions", settings
assert settings["skipDangerousModePermissionPrompt"] is True, settings
assert settings["enableAllProjectMcpServers"] is True, settings
PY

bad_dir="$TMPDIR/bad-config"
mkdir -p "$bad_dir/home/.claude"
printf '{not json\n' > "$bad_dir/host-claude.json"
printf '{}\n' > "$bad_dir/settings.host.json"
set +e
bad_output="$(
    env \
        HOME="$bad_dir/home" \
        HOST_CONFIG="$bad_dir/host-claude.json" \
        TARGET_CONFIG="$bad_dir/home/.claude.json" \
        HOST_SETTINGS="$bad_dir/settings.host.json" \
        TARGET_SETTINGS="$bad_dir/home/.claude/settings.json" \
        AGENTMILL_PROFILE_LEVEL=trusted \
        bash "$REPO_ROOT/setup-claude-config.sh" 2>&1
)"
bad_rc=$?
set -e
[[ "$bad_rc" -eq 0 ]] || { echo "setup should warn, not fail, on unreadable host config" >&2; printf '%s\n' "$bad_output" >&2; exit 1; }
[[ "$bad_output" == *"[setup-claude-config] WARN: failed to load"* ]] || {
    echo "expected visible host config merge warning" >&2
    printf '%s\n' "$bad_output" >&2
    exit 1
}
[[ -f "$bad_dir/home/.claude.json" ]]
python3 - "$bad_dir/home/.claude/settings.json" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1]))
assert settings["permissions"]["defaultMode"] == "bypassPermissions", settings
assert settings["skipDangerousModePermissionPrompt"] is True, settings
assert settings["enableAllProjectMcpServers"] is True, settings
PY

echo "PASS test_host_config_forwarding"
