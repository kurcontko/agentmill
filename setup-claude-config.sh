#!/usr/bin/env bash
# Merges host Claude config into the container's ~/.claude.json
# and sets up plugins/skills/agents with corrected paths.
set -euo pipefail

HOST_CONFIG="${HOST_CONFIG:-/home/agent/.host-claude.json}"
TARGET_CONFIG="${TARGET_CONFIG:-$HOME/.claude.json}"
HOST_SETTINGS="${HOST_SETTINGS:-/home/agent/.claude/settings.host.json}"
TARGET_SETTINGS="${TARGET_SETTINGS:-/home/agent/.claude/settings.json}"
HOST_PLUGINS="/home/agent/.host-plugins"
TARGET_PLUGINS="/home/agent/.claude/plugins"
HOST_SKILLS="/home/agent/.host-skills"
TARGET_SKILLS="/home/agent/.claude/skills"
HOST_AGENTS="/home/agent/.host-agents"
TARGET_AGENTS="/home/agent/.claude/agents"
DEFAULT_TRUSTED_PATHS="${DEFAULT_TRUSTED_PATHS:-/workspace/repo /workspace/upstream}"

export HOST_CONFIG TARGET_CONFIG HOST_SETTINGS TARGET_SETTINGS DEFAULT_TRUSTED_PATHS

# --- Merge ~/.claude.json and settings.json in one Python pass ----------------
merge_error_file="$(mktemp)"
if ! python3 2>"$merge_error_file" << 'PYEOF'
import json, os, sys

def load(path):
    if not os.path.isfile(path):
        return {}
    with open(path) as f:
        return json.load(f)

def save(path, data):
    json.dump(data, open(path, "w"), indent=2)

def ensure_dict(value):
    return value if isinstance(value, dict) else {}

def warn(message):
    print(f"WARN: {message}", file=sys.stderr)

# --- claude.json: merge MCP servers and trusted project config ----------------
try:
    host_cfg = ensure_dict(load(os.environ["HOST_CONFIG"]))
    target_config_path = os.environ["TARGET_CONFIG"]
    target_cfg = ensure_dict(load(target_config_path))
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

    projects = ensure_dict(target_cfg.get("projects", {}))
    for path in os.environ["DEFAULT_TRUSTED_PATHS"].split():
        proj = dict(projects.get(path, {}))
        for k, v in merged.items():
            if k not in proj:
                proj[k] = v
        proj["hasTrustDialogAccepted"] = True
        proj["hasTrustDialogHooksAccepted"] = True

        mcp_json = os.path.join(path, ".mcp.json")
        if os.path.isfile(mcp_json):
            try:
                servers = ensure_dict(load(mcp_json)).get("mcpServers", {})
                enabled = proj.get("enabledMcpjsonServers", [])
                enabled.extend(n for n in servers if n not in enabled)
                if enabled:
                    proj["enabledMcpjsonServers"] = enabled
            except (json.JSONDecodeError, OSError) as exc:
                warn(f"skipping malformed MCP config {mcp_json}: {exc}")
        projects[path] = proj

    target_cfg["projects"] = projects
    save(target_config_path, target_cfg)
except (json.JSONDecodeError, OSError, TypeError) as exc:
    warn(f"failed to merge claude.json: {exc}")

# --- settings.json: permissions + plugins + hooks ----------------------------
try:
    host_settings_path = os.environ["HOST_SETTINGS"]
    target_settings_path = os.environ["TARGET_SETTINGS"]
    if os.path.isfile(host_settings_path):
        host_settings = ensure_dict(load(host_settings_path))
        target_settings = ensure_dict(load(target_settings_path))
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

        save(target_settings_path, target_settings)
except (json.JSONDecodeError, OSError, TypeError) as exc:
    warn(f"failed to merge settings.json: {exc}")
PYEOF
then
    echo "[setup-claude-config] WARN: failed to merge host Claude config/settings:" >&2
fi
if [[ -s "$merge_error_file" ]]; then
    sed 's/^/[setup-claude-config]   /' "$merge_error_file" >&2 || true
fi
rm -f "$merge_error_file"

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
        if ! python3 - "$manifest" <<'PY'
import json, re
import sys

manifest = sys.argv[1]
data = json.load(open(manifest))
if manifest.endswith("/installed_plugins.json"):
    for entries in data.get("plugins", {}).values():
        for entry in entries:
            path = entry.get("installPath", "")
            entry["installPath"] = re.sub(
                r"^.*/\.claude/plugins/",
                "/home/agent/.claude/plugins/",
                path,
            )
elif manifest.endswith("/known_marketplaces.json"):
    for marketplace in data.values():
        path = marketplace.get("installLocation", "")
        marketplace["installLocation"] = re.sub(
            r"^.*/\.claude/plugins/",
            "/home/agent/.claude/plugins/",
            path,
        )
json.dump(data, open(manifest, "w"), indent=2)
PY
        then
            echo "[setup-claude-config] WARN: failed to rewrite plugin manifest paths: $manifest" >&2
        fi
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
