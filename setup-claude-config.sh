#!/usr/bin/env bash
# Merges host Claude config into the container's ~/.claude.json
# and sets up plugins/skills/agents with corrected paths.
set -euo pipefail

TARGET_CONFIG="$HOME/.claude.json"
HOST_PLUGINS="/home/agent/.host-plugins"
TARGET_PLUGINS="/home/agent/.claude/plugins"
HOST_SKILLS="/home/agent/.host-skills"
TARGET_SKILLS="/home/agent/.claude/skills"
HOST_AGENTS="/home/agent/.host-agents"
TARGET_AGENTS="/home/agent/.claude/agents"

# --- Merge ~/.claude.json and settings.json in one Python pass ----------------
python3 << 'PYEOF' 2>/dev/null || true
import json, re, os

def load(path):
    return json.load(open(path)) if os.path.exists(path) else {}

def save(path, data):
    json.dump(data, open(path, "w"), indent=2)

def rewrite_plugin_paths(data):
    """Replace any host home dir paths with container path."""
    s = json.dumps(data)
    s = re.sub(r'"[^"]*?/\.claude/plugins/', '"/home/agent/.claude/plugins/', s)
    return json.loads(s)

# --- claude.json: merge MCP servers and trusted project config ----------------
host_cfg = load(os.environ.get("HOST_CONFIG", "/home/agent/.host-claude.json"))
target_cfg = load(os.environ.get("TARGET_CONFIG", os.path.expanduser("~/.claude.json")))
target_cfg["hasCompletedOnboarding"] = True

if "mcpServers" in host_cfg:
    target_cfg["mcpServers"] = host_cfg["mcpServers"]

# Merge all trusted host projects into a single config overlay
merged = {}
for hp in host_cfg.get("projects", {}).values():
    if not hp.get("hasTrustDialogAccepted"):
        continue
    for key in ("allowedTools", "mcpContextUris", "mcpServers",
                "enabledMcpjsonServers", "disabledMcpjsonServers",
                "hasClaudeMdExternalIncludesApproved",
                "hasClaudeMdExternalIncludesWarningShown"):
        val = hp.get(key)
        if val is None:
            continue
        if isinstance(val, dict):
            merged.setdefault(key, {}).update(val)
        elif isinstance(val, list):
            existing = merged.setdefault(key, [])
            existing.extend(i for i in val if i not in existing)
        else:
            merged[key] = val

projects = target_cfg.get("projects", {})
for path in "/workspace/repo /workspace/upstream".split():
    proj = dict(projects.get(path, {}))
    for k, v in merged.items():
        if k not in proj:
            proj[k] = v
    proj["hasTrustDialogAccepted"] = True
    proj["hasTrustDialogHooksAccepted"] = True

    mcp_json = os.path.join(path, ".mcp.json")
    if os.path.isfile(mcp_json):
        try:
            servers = json.load(open(mcp_json)).get("mcpServers", {})
            enabled = proj.get("enabledMcpjsonServers", [])
            enabled.extend(n for n in servers if n not in enabled)
            if enabled:
                proj["enabledMcpjsonServers"] = enabled
        except (json.JSONDecodeError, OSError):
            pass
    projects[path] = proj

target_cfg["projects"] = projects
save(os.path.expanduser("~/.claude.json"), target_cfg)

# --- settings.json: permissions + plugins + hooks ----------------------------
host_settings = load("/home/agent/.claude/settings.host.json")
if host_settings:
    target_settings = load("/home/agent/.claude/settings.json")
    perms = target_settings.get("permissions", {})
    perms["defaultMode"] = "bypassPermissions"
    perms["allow"] = list(set(
        perms.get("allow", []) + host_settings.get("permissions", {}).get("allow", [])
    ))
    target_settings["permissions"] = perms
    target_settings["skipDangerousModePermissionPrompt"] = True
    target_settings["enableAllProjectMcpServers"] = True

    for key in ("enabledPlugins", "hooks"):
        if key in host_settings:
            target_settings[key] = host_settings[key]
    if "env" in host_settings:
        env = target_settings.get("env", {})
        env.update(host_settings["env"])
        target_settings["env"] = env

    save("/home/agent/.claude/settings.json", target_settings)
PYEOF

# Fallback: ensure claude.json exists
if [[ ! -f "$TARGET_CONFIG" ]]; then
    echo '{"hasCompletedOnboarding":true}' > "$TARGET_CONFIG"
fi

# --- Copy and fix plugins -----------------------------------------------------
if [[ -d "$HOST_PLUGINS" ]] && [[ "$(ls -A "$HOST_PLUGINS" 2>/dev/null)" ]]; then
    mkdir -p "$TARGET_PLUGINS"
    cp -a "$HOST_PLUGINS"/. "$TARGET_PLUGINS"/ 2>/dev/null || true

    # Fix paths in plugin manifests
    for manifest in "$TARGET_PLUGINS/installed_plugins.json" "$TARGET_PLUGINS/known_marketplaces.json"; do
        [[ -f "$manifest" ]] || continue
        python3 -c "
import json, re
data = json.load(open('$manifest'))
fixed = json.loads(re.sub(r'\"[^\"]*?/\.claude/plugins/', '\"/home/agent/.claude/plugins/', json.dumps(data)))
json.dump(fixed, open('$manifest', 'w'), indent=2)
" 2>/dev/null || true
    done
fi

# --- Copy user skills and agents ---------------------------------------------
for pair in "$HOST_SKILLS:$TARGET_SKILLS" "$HOST_AGENTS:$TARGET_AGENTS"; do
    src="${pair%%:*}" dst="${pair##*:}"
    if [[ -d "$src" ]] && [[ "$(ls -A "$src" 2>/dev/null)" ]]; then
        mkdir -p "$dst"
        cp -a "$src"/. "$dst"/ 2>/dev/null || true
    fi
done
