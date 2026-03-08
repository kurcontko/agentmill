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

trusted_source = None
for project in host_projects.values():
    if project.get('hasTrustDialogAccepted'):
        trusted_source = project
        break

for path in '$DEFAULT_TRUSTED_PATHS'.split():
    project = dict(projects.get(path, {}))
    if trusted_source is not None:
        for key in (
            'allowedTools',
            'mcpContextUris',
            'mcpServers',
            'enabledMcpjsonServers',
            'disabledMcpjsonServers',
            'hasClaudeMdExternalIncludesApproved',
            'hasClaudeMdExternalIncludesWarningShown',
        ):
            if key in trusted_source and key not in project:
                project[key] = trusted_source[key]
    project['hasTrustDialogAccepted'] = True
    project['hasTrustDialogHooksAccepted'] = True
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

if 'enabledPlugins' in host:
    target['enabledPlugins'] = host['enabledPlugins']

json.dump(target, open('$TARGET_SETTINGS', 'w'), indent=2)
" 2>/dev/null || true
fi

# --- Copy plugins and fix paths ---------------------------------------------
if [[ -d "$HOST_PLUGINS" ]] && [[ -n "$(ls -A "$HOST_PLUGINS" 2>/dev/null)" ]]; then
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
