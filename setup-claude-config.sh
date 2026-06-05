#!/usr/bin/env bash
# Merges host Claude config into the container's ~/.claude.json
# and sets up plugins/skills/agents with corrected paths.
set -euo pipefail

TARGET_CONFIG="${TARGET_CONFIG:-$HOME/.claude.json}"
HOST_PLUGINS="${HOST_PLUGINS:-/home/agent/.host-plugins}"
TARGET_PLUGINS="${TARGET_PLUGINS:-/home/agent/.claude/plugins}"
HOST_SKILLS="${HOST_SKILLS:-/home/agent/.host-skills}"
TARGET_SKILLS="${TARGET_SKILLS:-/home/agent/.claude/skills}"
HOST_AGENTS="${HOST_AGENTS:-/home/agent/.host-agents}"
TARGET_AGENTS="${TARGET_AGENTS:-/home/agent/.claude/agents}"
HOST_COMMANDS="${HOST_COMMANDS:-/home/agent/.host-commands}"
TARGET_COMMANDS="${TARGET_COMMANDS:-/home/agent/.claude/commands}"
HOST_SETTINGS="${HOST_SETTINGS:-/home/agent/.claude/settings.host.json}"
TARGET_SETTINGS="${TARGET_SETTINGS:-/home/agent/.claude/settings.json}"

export TARGET_CONFIG HOST_PLUGINS TARGET_PLUGINS HOST_SKILLS TARGET_SKILLS HOST_AGENTS TARGET_AGENTS HOST_COMMANDS TARGET_COMMANDS HOST_SETTINGS TARGET_SETTINGS

# --- Merge ~/.claude.json and settings.json in one Python pass ----------------
merge_error_file="$(mktemp)"
if ! python3 2>"$merge_error_file" << 'PYEOF'
import json, os, sys

def load(path):
    if not os.path.isfile(path):
        return {}
    try:
        with open(path) as handle:
            data = json.load(handle)
    except (json.JSONDecodeError, OSError) as exc:
        print(f"[setup-claude-config] WARN: failed to load {path}: {exc}", file=sys.stderr)
        return {}
    if not isinstance(data, dict):
        print(f"[setup-claude-config] WARN: ignoring non-object JSON in {path}", file=sys.stderr)
        return {}
    return data

def save(path, data):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w") as handle:
        json.dump(data, handle, indent=2)

# --- claude.json: merge MCP servers and trusted project config ----------------
def truthy(name):
    return os.environ.get(name, "").lower() in {"1", "true", "yes", "on"}


profile_level = os.environ.get("AGENTMILL_PROFILE_LEVEL", "trusted").lower()
is_trusted = profile_level == "trusted"
forward_host_mcp = truthy("AGENTMILL_FORWARD_HOST_MCP")
allow_host_tools = is_trusted or truthy("AGENTMILL_FORWARD_HOST_TOOLS")
allow_host_hooks = is_trusted or truthy("AGENTMILL_FORWARD_HOST_HOOKS")
allow_host_env = is_trusted or truthy("AGENTMILL_FORWARD_HOST_ENV")
allow_host_extensions = is_trusted or truthy("AGENTMILL_FORWARD_HOST_EXTENSIONS")
mcp_allowlist = {
    item.strip()
    for item in os.environ.get("AGENTMILL_MCP_ALLOWLIST", "").split(",")
    if item.strip()
}
allow_host_mcp = is_trusted or forward_host_mcp or bool(mcp_allowlist)

def filter_mcp_dict(value):
    if not mcp_allowlist or not isinstance(value, dict):
        return value
    return {name: cfg for name, cfg in value.items() if name in mcp_allowlist}

def filter_mcp_list(value):
    if not mcp_allowlist or not isinstance(value, list):
        return value
    return [name for name in value if name in mcp_allowlist]

host_cfg = load(os.environ.get("HOST_CONFIG", "/home/agent/.host-claude.json"))
target_config_path = os.environ.get("TARGET_CONFIG", os.path.expanduser("~/.claude.json"))
target_cfg = load(target_config_path)
target_cfg["hasCompletedOnboarding"] = True

if allow_host_mcp and "mcpServers" in host_cfg:
    target_cfg["mcpServers"] = filter_mcp_dict(host_cfg["mcpServers"])

# Merge all trusted host projects into a single config overlay
merged = {}
for hp in host_cfg.get("projects", {}).values():
    if not hp.get("hasTrustDialogAccepted"):
        continue
    merge_keys = []
    if allow_host_tools:
        merge_keys.extend([
            "allowedTools",
            "hasClaudeMdExternalIncludesApproved",
            "hasClaudeMdExternalIncludesWarningShown",
        ])
    if allow_host_mcp:
        merge_keys.extend(["mcpContextUris", "mcpServers",
                           "enabledMcpjsonServers", "disabledMcpjsonServers"])
    for key in merge_keys:
        val = hp.get(key)
        if val is None:
            continue
        if key == "mcpServers":
            val = filter_mcp_dict(val)
        elif key in {"enabledMcpjsonServers", "disabledMcpjsonServers"}:
            val = filter_mcp_list(val)
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
    proj["hasTrustDialogHooksAccepted"] = bool(allow_host_hooks)

    mcp_json = os.path.join(path, ".mcp.json")
    if allow_host_mcp and os.path.isfile(mcp_json):
        try:
            servers = filter_mcp_dict(json.load(open(mcp_json)).get("mcpServers", {}))
            enabled = proj.get("enabledMcpjsonServers", [])
            enabled.extend(n for n in servers if n not in enabled)
            if enabled:
                proj["enabledMcpjsonServers"] = enabled
        except (json.JSONDecodeError, OSError):
            pass
    projects[path] = proj

target_cfg["projects"] = projects
save(target_config_path, target_cfg)

# --- settings.json: permissions + plugins + hooks ----------------------------
host_settings_path = os.environ.get("HOST_SETTINGS", "/home/agent/.claude/settings.host.json")
host_settings = load(host_settings_path)
if os.path.isfile(host_settings_path):
    target_settings_path = os.environ.get("TARGET_SETTINGS", "/home/agent/.claude/settings.json")
    target_settings = load(target_settings_path)
    perms = target_settings.get("permissions", {})
    host_permissions = host_settings.get("permissions", {})
    if is_trusted:
        perms["defaultMode"] = "bypassPermissions"
    if allow_host_tools:
        perms["allow"] = list(set(
            perms.get("allow", []) + host_permissions.get("allow", [])
        ))
        if host_permissions.get("deny"):
            perms["deny"] = list(set(perms.get("deny", []) + host_permissions.get("deny", [])))
    target_settings["permissions"] = perms
    target_settings["skipDangerousModePermissionPrompt"] = True
    target_settings["enableAllProjectMcpServers"] = allow_host_mcp

    if allow_host_extensions and "enabledPlugins" in host_settings:
        target_settings["enabledPlugins"] = host_settings["enabledPlugins"]
    if allow_host_hooks and "hooks" in host_settings:
        target_settings["hooks"] = host_settings["hooks"]
    if allow_host_env and "env" in host_settings:
        env = target_settings.get("env", {})
        env.update(host_settings["env"])
        target_settings["env"] = env

    save(target_settings_path, target_settings)
PYEOF
then
    echo "[setup-claude-config] WARN: failed to merge host Claude config/settings:" >&2
    sed 's/^/[setup-claude-config]   /' "$merge_error_file" >&2 || true
elif [[ -s "$merge_error_file" ]]; then
    cat "$merge_error_file" >&2 || true
fi
rm -f "$merge_error_file"

# Fallback: ensure claude.json exists
if [[ ! -f "$TARGET_CONFIG" ]]; then
    echo '{"hasCompletedOnboarding":true}' > "$TARGET_CONFIG"
fi

truthy() {
    case "${1:-}" in
        true|TRUE|True|1|yes|YES|Yes|on|ON|On) return 0 ;;
    esac
    return 1
}

host_extensions_allowed() {
    local profile
    profile="$(printf '%s' "${AGENTMILL_PROFILE_LEVEL:-trusted}" | tr '[:upper:]' '[:lower:]')"
    [[ "$profile" == "trusted" ]] || truthy "${AGENTMILL_FORWARD_HOST_EXTENSIONS:-}"
}

profile_is_trusted() {
    local profile
    profile="$(printf '%s' "${AGENTMILL_PROFILE_LEVEL:-trusted}" | tr '[:upper:]' '[:lower:]')"
    [[ "$profile" == "trusted" ]]
}

trim_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

skill_allowlist_configured() {
    local item trimmed
    local -a items
    IFS=',' read -r -a items <<< "${AGENTMILL_SKILL_ALLOWLIST:-}"
    for item in "${items[@]}"; do
        trimmed="$(trim_value "$item")"
        [[ -n "$trimmed" ]] && return 0
    done
    return 1
}

skill_allowed() {
    local name="$1" item trimmed
    local -a items
    IFS=',' read -r -a items <<< "${AGENTMILL_SKILL_ALLOWLIST:-}"
    for item in "${items[@]}"; do
        trimmed="$(trim_value "$item")"
        [[ "$trimmed" == "$name" ]] && return 0
    done
    return 1
}

copy_tree_contents() {
    local src="$1" dst="$2"
    if [[ -d "$src" ]] && [[ "$(ls -A "$src" 2>/dev/null)" ]]; then
        mkdir -p "$dst"
        cp -a "$src"/. "$dst"/ 2>/dev/null || true
    fi
}

copy_host_skills() {
    [[ -d "$HOST_SKILLS" ]] && [[ "$(ls -A "$HOST_SKILLS" 2>/dev/null)" ]] || return 0

    if skill_allowlist_configured; then
        local src name
        mkdir -p "$TARGET_SKILLS"
        for src in "$HOST_SKILLS"/* "$HOST_SKILLS"/.[!.]* "$HOST_SKILLS"/..?*; do
            [[ -e "$src" ]] || continue
            name="${src##*/}"
            if skill_allowed "$name"; then
                cp -a "$src" "$TARGET_SKILLS"/ 2>/dev/null || true
            fi
        done
        return 0
    fi

    if profile_is_trusted; then
        copy_tree_contents "$HOST_SKILLS" "$TARGET_SKILLS"
    fi
}

# --- Copy and fix plugins -----------------------------------------------------
if host_extensions_allowed && [[ -d "$HOST_PLUGINS" ]] && [[ "$(ls -A "$HOST_PLUGINS" 2>/dev/null)" ]]; then
    mkdir -p "$TARGET_PLUGINS"
    cp -a "$HOST_PLUGINS"/. "$TARGET_PLUGINS"/ 2>/dev/null || true

    # Fix paths in plugin manifests
    for manifest in "$TARGET_PLUGINS/installed_plugins.json" "$TARGET_PLUGINS/known_marketplaces.json"; do
        [[ -f "$manifest" ]] || continue
        if ! python3 - "$manifest" <<'PY'
import json
import sys

manifest = sys.argv[1]
plugin_path_keys = {"installPath", "installLocation"}
plugin_path_marker = "/.claude/plugins/"

def rewrite_plugin_value(value):
    if isinstance(value, str) and plugin_path_marker in value:
        return "/home/agent/.claude/plugins/" + value.rsplit(plugin_path_marker, 1)[1]
    return value

def rewrite_manifest_paths(value):
    if isinstance(value, dict):
        return {
            key: rewrite_plugin_value(item) if key in plugin_path_keys else rewrite_manifest_paths(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [rewrite_manifest_paths(item) for item in value]
    return value

with open(manifest) as handle:
    data = json.load(handle)
fixed = rewrite_manifest_paths(data)
with open(manifest, 'w') as handle:
    json.dump(fixed, handle, indent=2)
PY
        then
            echo "[setup-claude-config] WARN: failed to rewrite plugin manifest paths: $manifest" >&2
        fi
    done
fi

# --- Copy user skills and agents ---------------------------------------------
if host_extensions_allowed; then
    copy_host_skills
    for pair in "$HOST_AGENTS:$TARGET_AGENTS" "$HOST_COMMANDS:$TARGET_COMMANDS"; do
        src="${pair%%:*}" dst="${pair##*:}"
        copy_tree_contents "$src" "$dst"
    done
fi
