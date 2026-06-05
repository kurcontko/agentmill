#!/usr/bin/env bash

backup_project_settings() {
    SETTINGS_LOCAL_PATH="${1:-.claude/settings.local.json}"
    SETTINGS_BACKUP_FILE="" SETTINGS_BACKUP_EXISTS=false
    mkdir -p "$(dirname "$SETTINGS_LOCAL_PATH")"
    if [[ -f "$SETTINGS_LOCAL_PATH" ]]; then
        SETTINGS_BACKUP_FILE="$(mktemp)"
        cp "$SETTINGS_LOCAL_PATH" "$SETTINGS_BACKUP_FILE"
        SETTINGS_BACKUP_EXISTS=true
    fi
}

write_project_settings() {
    [[ -n "${SETTINGS_LOCAL_PATH:-}" ]] || { echo "call backup_project_settings first" >&2; return 1; }
    printf '%s\n' "$1" > "$SETTINGS_LOCAL_PATH"
}

restore_project_settings() {
    [[ -n "${SETTINGS_LOCAL_PATH:-}" ]] || return 0
    if [[ "${SETTINGS_BACKUP_EXISTS:-false}" == "true" && -f "${SETTINGS_BACKUP_FILE:-}" ]]; then
        cp "$SETTINGS_BACKUP_FILE" "$SETTINGS_LOCAL_PATH"
    else
        rm -f "$SETTINGS_LOCAL_PATH"
    fi
    rm -f "${SETTINGS_BACKUP_FILE:-}"
    unset SETTINGS_LOCAL_PATH SETTINGS_BACKUP_FILE SETTINGS_BACKUP_EXISTS
}

autonomous_settings_json() {
    printf '%s\n' '{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep","Agent","WebFetch","WebSearch","NotebookEdit","mcp__*"],"defaultMode":"bypassPermissions"}}'
}
