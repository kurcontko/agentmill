#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export AGENT_ID="settings"
mkdir -p "$LOG_DIR"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

missing_path="$TMPDIR/missing/.claude/settings.local.json"
backup_project_settings "$missing_path"
write_project_settings '{"permissions":{"defaultMode":"bypassPermissions"}}'
[[ -f "$missing_path" ]]
restore_project_settings
[[ ! -e "$missing_path" && ! -L "$missing_path" ]]

corrupt_path="$TMPDIR/corrupt/.claude/settings.local.json"
mkdir -p "$(dirname "$corrupt_path")"
printf '{not json\n' > "$corrupt_path"
backup_project_settings "$corrupt_path"
write_project_settings '{"permissions":{"defaultMode":"bypassPermissions"}}'
restore_project_settings
[[ "$(<"$corrupt_path")" == "{not json" ]]

target_dir="$TMPDIR/targets"
mkdir -p "$target_dir" "$TMPDIR/link/.claude"
target_path="$target_dir/settings.json"
link_path="$TMPDIR/link/.claude/settings.local.json"
printf '{"original":true}\n' > "$target_path"
ln -s "$target_path" "$link_path"

backup_project_settings "$link_path"
write_project_settings '{"temporary":true}'
[[ -L "$link_path" ]]
[[ "$(readlink "$link_path")" == "$target_path" ]]
[[ "$(<"$target_path")" == '{"temporary":true}' ]]
restore_project_settings
[[ -L "$link_path" ]]
[[ "$(readlink "$link_path")" == "$target_path" ]]
[[ "$(<"$target_path")" == '{"original":true}' ]]

dangling_target="$target_dir/dangling-settings.json"
dangling_link="$TMPDIR/dangling/.claude/settings.local.json"
mkdir -p "$(dirname "$dangling_link")"
ln -s "$dangling_target" "$dangling_link"
[[ -L "$dangling_link" && ! -e "$dangling_link" ]]

backup_project_settings "$dangling_link"
write_project_settings '{"temporary":true}'
[[ -L "$dangling_link" && -f "$dangling_target" ]]
restore_project_settings
[[ -L "$dangling_link" ]]
[[ "$(readlink "$dangling_link")" == "$dangling_target" ]]
[[ ! -e "$dangling_link" ]]
[[ ! -e "$dangling_target" ]]

if write_project_settings '{}' >/tmp/agentmill-settings-write.out 2>&1; then
    echo "expected write_project_settings without backup to fail" >&2
    exit 1
fi

echo "PASS test_settings_backup_restore"
