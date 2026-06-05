#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test_push_failure_is_retryable_matches_only_sync_failures() {
    # shellcheck source=../lib/agentmill/sh/runtime/git.sh
    . "$REPO_ROOT/lib/agentmill/sh/runtime/git.sh"

    push_failure_is_retryable '!	refs/heads/agent-1:refs/heads/agent-1	[rejected] (fetch first)'
    push_failure_is_retryable 'error: failed to push some refs to origin
hint: Updates were rejected because the tip of your current branch is behind
! [rejected]        agent-1 -> agent-1 (non-fast-forward)'

    if push_failure_is_retryable '!	refs/heads/agent-1:refs/heads/agent-1	[remote rejected] (pre-receive hook declined)'; then
        echo "classified pre-receive rejection as retryable" >&2
        return 1
    fi
}

test_log_preserves_entrypoint_log_paths() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2034 # Used by the sourced log() helper.
    LOG_DIR="$tmpdir"
    # shellcheck source=../lib/agentmill/sh/core/log.sh
    . "$REPO_ROOT/lib/agentmill/sh/core/log.sh"

    unset AGENT_ID
    log "tui message" >/dev/null
    [[ -f "$tmpdir/agent.log" ]]
    [[ ! -e "$tmpdir/agent-tui.log" ]]

    # shellcheck disable=SC2034 # Used by the eval'd log() helper.
    AGENT_ID=2
    log "headless message" >/dev/null
    [[ -f "$tmpdir/agent-2.log" ]]
    grep -q '^\[agentmill:agent-2 ' "$tmpdir/agent-2.log"

    rm -rf "$tmpdir"
}

test_poetry_install_keeps_legacy_flags() {
    local tmpdir repo bin calls
    tmpdir="$(mktemp -d)"
    repo="$tmpdir/repo"
    bin="$tmpdir/bin"
    calls="$tmpdir/poetry.calls"
    mkdir -p "$repo" "$bin"
    touch "$repo/pyproject.toml" "$repo/poetry.lock"

    cat > "$bin/poetry" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$POETRY_CALLS"
if [[ "${1:-}" == "install" ]]; then
    [[ "$*" != *"--no-root"* ]]
    [[ -z "${POETRY_INSTALLER_ONLY_BINARY:-}" ]]
    [[ -z "${PIP_ONLY_BINARY:-}" ]]
fi
EOF
    chmod +x "$bin/poetry"

    PATH="$bin:$PATH" POETRY_CALLS="$calls" AUTO_SETUP=true EXTRA_PYTHON_TOOLS="" \
        bash -c '. "$1/setup-repo-env.sh" "$2"' _ "$REPO_ROOT" "$repo"
    grep -Fxq "install --no-interaction" "$calls"

    rm -rf "$tmpdir"
}

test_claude_config_skips_directory_mounts_and_merges_settings() {
    local tmpdir home host_config host_settings target_config target_settings repo
    tmpdir="$(mktemp -d)"
    home="$tmpdir/home"
    host_config="$tmpdir/host-claude.json"
    host_settings="$tmpdir/settings.host.json"
    target_config="$home/.claude.json"
    target_settings="$home/.claude/settings.json"
    repo="$tmpdir/repo"
    mkdir -p "$home/.claude" "$host_config" "$repo"

    cat > "$host_settings" <<'EOF'
{
  "permissions": {"allow": ["Bash"]},
  "hooks": {"PreToolUse": []},
  "env": {"AGENTMILL_TEST_SETTING": "forwarded"}
}
EOF

    HOME="$home" \
        HOST_CONFIG="$host_config" \
        TARGET_CONFIG="$target_config" \
        HOST_SETTINGS="$host_settings" \
        TARGET_SETTINGS="$target_settings" \
        DEFAULT_TRUSTED_PATHS="$repo" \
        bash "$REPO_ROOT/setup-claude-config.sh"

    python3 - "$target_config" "$target_settings" <<'PY'
import json
import sys

target_config = json.load(open(sys.argv[1]))
target_settings = json.load(open(sys.argv[2]))

assert target_config["hasCompletedOnboarding"] is True
assert target_settings["permissions"]["defaultMode"] == "bypassPermissions"
assert "Bash" in target_settings["permissions"]["allow"]
assert "PreToolUse" in target_settings["hooks"]
assert target_settings["env"]["AGENTMILL_TEST_SETTING"] == "forwarded"
PY

    rm -rf "$tmpdir"
}

test_claude_config_hardens_empty_host_settings() {
    local tmpdir home host_config host_settings target_config target_settings repo
    tmpdir="$(mktemp -d)"
    home="$tmpdir/home"
    host_config="$tmpdir/host-claude.json"
    host_settings="$tmpdir/settings.host.json"
    target_config="$home/.claude.json"
    target_settings="$home/.claude/settings.json"
    repo="$tmpdir/repo"
    mkdir -p "$home/.claude" "$repo"
    printf '%s\n' '{}' > "$host_config"
    printf '%s\n' '{}' > "$host_settings"

    HOME="$home" \
        HOST_CONFIG="$host_config" \
        TARGET_CONFIG="$target_config" \
        HOST_SETTINGS="$host_settings" \
        TARGET_SETTINGS="$target_settings" \
        DEFAULT_TRUSTED_PATHS="$repo" \
        bash "$REPO_ROOT/setup-claude-config.sh"

    python3 - "$target_settings" <<'PY'
import json
import sys

target_settings = json.load(open(sys.argv[1]))

assert target_settings["permissions"]["defaultMode"] == "bypassPermissions"
assert target_settings["skipDangerousModePermissionPrompt"] is True
assert target_settings["enableAllProjectMcpServers"] is True
PY

    rm -rf "$tmpdir"
}

test_claude_config_isolates_corrupt_host_config_from_settings() {
    local tmpdir home host_config host_settings target_config target_settings repo
    tmpdir="$(mktemp -d)"
    home="$tmpdir/home"
    host_config="$tmpdir/host-claude.json"
    host_settings="$tmpdir/settings.host.json"
    target_config="$home/.claude.json"
    target_settings="$home/.claude/settings.json"
    repo="$tmpdir/repo"
    mkdir -p "$home/.claude" "$repo"
    printf '%s\n' '{"broken":' > "$host_config"
    cat > "$host_settings" <<'EOF'
{"permissions": {"allow": ["Read"]}}
EOF

    HOME="$home" \
        HOST_CONFIG="$host_config" \
        TARGET_CONFIG="$target_config" \
        HOST_SETTINGS="$host_settings" \
        TARGET_SETTINGS="$target_settings" \
        DEFAULT_TRUSTED_PATHS="$repo" \
        bash "$REPO_ROOT/setup-claude-config.sh"

    python3 - "$target_config" "$target_settings" <<'PY'
import json
import sys

target_config = json.load(open(sys.argv[1]))
target_settings = json.load(open(sys.argv[2]))

assert target_config["hasCompletedOnboarding"] is True
assert target_settings["permissions"]["defaultMode"] == "bypassPermissions"
assert "Read" in target_settings["permissions"]["allow"]
PY

    rm -rf "$tmpdir"
}

test_push_failure_is_retryable_matches_only_sync_failures
test_log_preserves_entrypoint_log_paths
test_poetry_install_keeps_legacy_flags
test_claude_config_skips_directory_mounts_and_merges_settings
test_claude_config_hardens_empty_host_settings
test_claude_config_isolates_corrupt_host_config_from_settings

echo "PASS test_entrypoint_push_retry"
