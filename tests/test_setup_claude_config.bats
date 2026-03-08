#!/usr/bin/env bats
# Tests for setup-claude-config.sh (jq-based config merging)

setup() {
    export TEST_DIR="$(mktemp -d)"
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME/.claude"

    # Override paths used by the script
    export HOST_CONFIG="$HOME/.host-claude.json"
    export TARGET_CONFIG="$HOME/.claude.json"
    export HOST_SETTINGS="$HOME/.claude/settings.host.json"
    export TARGET_SETTINGS="$HOME/.claude/settings.json"
    export HOST_PLUGINS="$HOME/.host-plugins"
    export TARGET_PLUGINS="$HOME/.claude/plugins"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "no host config creates default target" {
    # No host config file — should not error
    run /setup-claude-config.sh
    [ "$status" -eq 0 ]
}

@test "host config merges MCP servers" {
    echo '{"mcpServers":{"test":{"command":"echo"}},"projects":{}}' > "$HOST_CONFIG"
    /setup-claude-config.sh
    result="$(jq -r '.mcpServers.test.command' "$TARGET_CONFIG")"
    [ "$result" = "echo" ]
}

@test "host config sets trust dialog accepted" {
    echo '{"projects":{}}' > "$HOST_CONFIG"
    /setup-claude-config.sh
    result="$(jq -r '.projects["/workspace/repo"].hasTrustDialogAccepted' "$TARGET_CONFIG")"
    [ "$result" = "true" ]
}

@test "settings merge combines allow lists" {
    echo '{"permissions":{"allow":["Bash","Read"]}}' > "$TARGET_SETTINGS"
    echo '{"permissions":{"allow":["CustomTool"]}}' > "$HOST_SETTINGS"
    /setup-claude-config.sh
    result="$(jq '.permissions.allow | length' "$TARGET_SETTINGS")"
    [ "$result" -ge 3 ]
}

@test "settings merge sets bypassPermissions" {
    echo '{}' > "$HOST_SETTINGS"
    /setup-claude-config.sh
    result="$(jq -r '.permissions.defaultMode' "$TARGET_SETTINGS")"
    [ "$result" = "bypassPermissions" ]
}

@test "plugin path rewriting fixes install paths" {
    mkdir -p "$HOST_PLUGINS"
    echo '{"plugins":{"test-plugin":[{"installPath":"/Users/someone/.claude/plugins/test"}]}}' > "$HOST_PLUGINS/installed_plugins.json"
    /setup-claude-config.sh
    result="$(jq -r '.plugins["test-plugin"][0].installPath' "$TARGET_PLUGINS/installed_plugins.json")"
    [ "$result" = "/home/agent/.claude/plugins/test" ]
}
