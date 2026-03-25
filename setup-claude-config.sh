#!/usr/bin/env bash
# Merges host Claude config into the container's ~/.claude.json
# and sets up plugins with corrected paths.
# Called from entrypoints before launching Claude Code.
set -euo pipefail

HOST_CONFIG="/home/agent/.host-claude.json"
TARGET_CONFIG="$HOME/.claude.json"
HOST_SETTINGS="/home/agent/.claude/settings.host.json"
TARGET_SETTINGS="/home/agent/.claude/settings.json"
HOST_PLUGINS="/home/agent/.host-plugins"
TARGET_PLUGINS="/home/agent/.claude/plugins"
HOST_SKILLS="/home/agent/.host-skills"
TARGET_SKILLS="/home/agent/.claude/skills"
HOST_AGENTS="/home/agent/.host-agents"
TARGET_AGENTS="/home/agent/.claude/agents"
DEFAULT_TRUSTED_PATHS="/workspace/repo /workspace/upstream"

# --- Merge ~/.claude.json (MCP servers, plugins) ----------------------------
if [[ -f "$HOST_CONFIG" ]]; then
    python3 -c "
import json, os

host = json.load(open('$HOST_CONFIG'))
target = {}
if os.path.exists('$TARGET_CONFIG'):
    target = json.load(open('$TARGET_CONFIG'))

target['hasCompletedOnboarding'] = True

if 'mcpServers' in host:
    target['mcpServers'] = host['mcpServers']

projects = target.get('projects', {})
host_projects = host.get('projects', {})

# Merge values from ALL trusted host projects (not just the first).
# For dict keys (mcpServers etc.), later projects add to earlier ones.
merged_trusted = {}
for hp in host_projects.values():
    if not hp.get('hasTrustDialogAccepted'):
        continue
    for key in (
        'allowedTools',
        'mcpContextUris',
        'mcpServers',
        'enabledMcpjsonServers',
        'disabledMcpjsonServers',
        'hasClaudeMdExternalIncludesApproved',
        'hasClaudeMdExternalIncludesWarningShown',
    ):
        if key not in hp:
            continue
        val = hp[key]
        if isinstance(val, dict):
            merged_trusted.setdefault(key, {}).update(val)
        elif isinstance(val, list):
            existing = merged_trusted.setdefault(key, [])
            for item in val:
                if item not in existing:
                    existing.append(item)
        else:
            merged_trusted[key] = val

for path in '$DEFAULT_TRUSTED_PATHS'.split():
    project = dict(projects.get(path, {}))
    for key, val in merged_trusted.items():
        if key not in project:
            project[key] = val
    project['hasTrustDialogAccepted'] = True
    project['hasTrustDialogHooksAccepted'] = True

    # Auto-enable project .mcp.json servers so agents skip trust prompts
    mcp_json = os.path.join(path, '.mcp.json')
    if os.path.isfile(mcp_json):
        try:
            mcp_data = json.load(open(mcp_json))
            mcp_servers = mcp_data.get('mcpServers', {})
            enabled = project.get('enabledMcpjsonServers', [])
            for name in mcp_servers:
                if name not in enabled:
                    enabled.append(name)
            if enabled:
                project['enabledMcpjsonServers'] = enabled
        except (json.JSONDecodeError, OSError):
            pass

    projects[path] = project

target['projects'] = projects

json.dump(target, open('$TARGET_CONFIG', 'w'), indent=2)
" 2>/dev/null || {
        if [[ ! -f "$TARGET_CONFIG" ]]; then
            echo '{"hasCompletedOnboarding":true}' > "$TARGET_CONFIG"
        fi
    }
fi

# --- Merge settings.json (permissions + plugin config) ----------------------
if [[ -f "$HOST_SETTINGS" ]]; then
    python3 -c "
import json, os

host = json.load(open('$HOST_SETTINGS'))
target = {}
if os.path.exists('$TARGET_SETTINGS'):
    target = json.load(open('$TARGET_SETTINGS'))

perms = target.get('permissions', {})
perms['defaultMode'] = 'bypassPermissions'

host_allow = host.get('permissions', {}).get('allow', [])
target_allow = perms.get('allow', [])
perms['allow'] = list(set(target_allow + host_allow))
target['permissions'] = perms
target['skipDangerousModePermissionPrompt'] = True
target['enableAllProjectMcpServers'] = True

if 'enabledPlugins' in host:
    target['enabledPlugins'] = host['enabledPlugins']

json.dump(target, open('$TARGET_SETTINGS', 'w'), indent=2)
" 2>/dev/null || true
fi

# --- Copy plugins and fix paths ---------------------------------------------
if [[ -d "$HOST_PLUGINS" ]] && [[ "$(ls -A "$HOST_PLUGINS" 2>/dev/null)" ]]; then
    # Copy plugin files to writable location
    mkdir -p "$TARGET_PLUGINS"
    cp -a "$HOST_PLUGINS"/. "$TARGET_PLUGINS"/ 2>/dev/null || true

    # Fix installed_plugins.json - rewrite host home path to container home
    MANIFEST="$TARGET_PLUGINS/installed_plugins.json"
    if [[ -f "$MANIFEST" ]]; then
        python3 -c "
import json, re, os

manifest = json.load(open('$MANIFEST'))

# Find and replace any home directory paths with container path
for plugin_id, entries in manifest.get('plugins', {}).items():
    for entry in entries:
        path = entry.get('installPath', '')
        # Replace host .claude/plugins path with container path
        entry['installPath'] = re.sub(
            r'^.*/\.claude/plugins/',
            '/home/agent/.claude/plugins/',
            path
        )

json.dump(manifest, open('$MANIFEST', 'w'), indent=2)
" 2>/dev/null || true
    fi

    MARKETPLACES="$TARGET_PLUGINS/known_marketplaces.json"
    if [[ -f "$MARKETPLACES" ]]; then
        python3 -c "
import json, re, os

marketplaces = json.load(open('$MARKETPLACES'))

for marketplace in marketplaces.values():
    install_path = marketplace.get('installLocation', '')
    marketplace['installLocation'] = re.sub(
        r'^.*/\.claude/plugins/',
        '/home/agent/.claude/plugins/',
        install_path
    )

json.dump(marketplaces, open('$MARKETPLACES', 'w'), indent=2)
" 2>/dev/null || true
    fi
fi

# --- Copy user skills ----------------------------------------------------------
if [[ -d "$HOST_SKILLS" ]] && [[ "$(ls -A "$HOST_SKILLS" 2>/dev/null)" ]]; then
    mkdir -p "$TARGET_SKILLS"
    cp -a "$HOST_SKILLS"/. "$TARGET_SKILLS"/ 2>/dev/null || true
fi

# --- Copy user agents ----------------------------------------------------------
if [[ -d "$HOST_AGENTS" ]] && [[ "$(ls -A "$HOST_AGENTS" 2>/dev/null)" ]]; then
    mkdir -p "$TARGET_AGENTS"
    cp -a "$HOST_AGENTS"/. "$TARGET_AGENTS"/ 2>/dev/null || true
fi
