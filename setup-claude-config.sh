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
    target='{}'
    if [[ -f "$TARGET_CONFIG" ]]; then
        target="$(cat "$TARGET_CONFIG")"
    fi

    # Build trusted paths array for jq
    trusted_paths_json='[]'
    for path in $DEFAULT_TRUSTED_PATHS; do
        trusted_paths_json="$(echo "$trusted_paths_json" | jq --arg p "$path" '. + [$p]')"
    done

    merged="$(jq -n \
        --argjson host "$(cat "$HOST_CONFIG")" \
        --argjson target "$target" \
        --argjson trusted_paths "$trusted_paths_json" \
        '
        $target
        | .hasCompletedOnboarding = true
        | if ($host | has("mcpServers")) then .mcpServers = $host.mcpServers else . end
        | .projects as $existing_projects
        | (
            # Find first trusted project from host config
            ($host.projects // {} | to_entries | map(select(.value.hasTrustDialogAccepted == true)) | first // null) as $trusted_source
            | reduce $trusted_paths[] as $path (
                ($existing_projects // {});
                . as $projects
                | ($projects[$path] // {}) as $project
                | ($project
                    | if $trusted_source != null then
                        reduce ("allowedTools","mcpContextUris","mcpServers","enabledMcpjsonServers",
                                "disabledMcpjsonServers","hasClaudeMdExternalIncludesApproved",
                                "hasClaudeMdExternalIncludesWarningShown") as $key (
                            .;
                            if (has($key) | not) and ($trusted_source.value | has($key))
                            then .[$key] = $trusted_source.value[$key]
                            else .
                            end
                        )
                      else .
                      end
                    | .hasTrustDialogAccepted = true
                    | .hasTrustDialogHooksAccepted = true
                ) as $updated
                | $projects + {($path): $updated}
            )
        ) as $merged_projects
        | .projects = $merged_projects
        '
    )" 2>/dev/null || {
        if [[ ! -f "$TARGET_CONFIG" ]]; then
            echo '{"hasCompletedOnboarding":true}' > "$TARGET_CONFIG"
        fi
        merged=""
    }

    if [[ -n "$merged" ]]; then
        echo "$merged" > "$TARGET_CONFIG"
    fi
fi

# --- Merge settings.json (permissions + plugin config) ----------------------
if [[ -f "$HOST_SETTINGS" ]]; then
    target='{}'
    if [[ -f "$TARGET_SETTINGS" ]]; then
        target="$(cat "$TARGET_SETTINGS")"
    fi

    jq -n \
        --argjson host "$(cat "$HOST_SETTINGS")" \
        --argjson target "$target" \
        '
        $target
        | .permissions.defaultMode = "bypassPermissions"
        | .permissions.allow = (
            ((.permissions.allow // []) + ($host.permissions.allow // []))
            | unique
        )
        | .skipDangerousModePermissionPrompt = true
        | if ($host | has("enabledPlugins")) then .enabledPlugins = $host.enabledPlugins else . end
        ' > "$TARGET_SETTINGS" 2>/dev/null || true
fi

# --- Copy plugins and fix paths ---------------------------------------------
if [[ -d "$HOST_PLUGINS" ]] && [[ -n "$(ls -A "$HOST_PLUGINS" 2>/dev/null)" ]]; then
    mkdir -p "$TARGET_PLUGINS"
    cp -a "$HOST_PLUGINS"/. "$TARGET_PLUGINS"/ 2>/dev/null || true

    # Fix installed_plugins.json - rewrite host home path to container home
    MANIFEST="$TARGET_PLUGINS/installed_plugins.json"
    if [[ -f "$MANIFEST" ]]; then
        jq '
            .plugins |= (
                to_entries | map(
                    .value |= map(
                        .installPath |= sub(".*/\\.claude/plugins/"; "/home/agent/.claude/plugins/")
                    )
                ) | from_entries
            )
        ' "$MANIFEST" > "${MANIFEST}.tmp" 2>/dev/null && mv "${MANIFEST}.tmp" "$MANIFEST" || true
    fi

    MARKETPLACES="$TARGET_PLUGINS/known_marketplaces.json"
    if [[ -f "$MARKETPLACES" ]]; then
        jq '
            to_entries | map(
                .value.installLocation |= sub(".*/\\.claude/plugins/"; "/home/agent/.claude/plugins/")
            ) | from_entries
        ' "$MARKETPLACES" > "${MARKETPLACES}.tmp" 2>/dev/null && mv "${MARKETPLACES}.tmp" "$MARKETPLACES" || true
    fi
fi
