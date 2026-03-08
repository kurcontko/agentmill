#!/usr/bin/env bats
# Tests for entrypoint.sh functions
# These tests source the entrypoint to test individual functions

setup() {
    export TEST_DIR="$(mktemp -d)"
    export LOG_DIR="$TEST_DIR/logs"
    export AGENT_ID="test"
    export LOG_FORMAT="text"
    export LOG_MAX_SIZE="10485760"
    export LOG_MAX_FILES="5"
    mkdir -p "$LOG_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Helper to source just the logging functions from entrypoint
load_logging() {
    mkdir -p "$LOG_DIR"
    # Extract and eval logging functions
    eval "$(sed -n '/^rotate_log()/,/^}/p' /entrypoint.sh)"
    eval "$(sed -n '/^log()/,/^}/p' /entrypoint.sh)"
}

@test "log function writes to stdout and file" {
    load_logging
    run log "test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test message"* ]]
    [[ -f "$LOG_DIR/agent-${AGENT_ID}.log" ]]
}

@test "log function parses WARN level" {
    load_logging
    run log "WARN: something went wrong"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"something went wrong"* ]]
}

@test "log function parses ERROR level" {
    load_logging
    run log "ERROR: critical failure"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ERROR"* ]]
    [[ "$output" == *"critical failure"* ]]
}

@test "log function defaults to INFO level" {
    load_logging
    run log "just a message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INFO"* ]]
}

@test "log function outputs JSON when LOG_FORMAT=json" {
    export LOG_FORMAT="json"
    load_logging
    run log "json test"
    [ "$status" -eq 0 ]
    echo "$output" | jq . >/dev/null 2>&1
}

@test "log rotation triggers at max size" {
    load_logging
    export LOG_MAX_SIZE=100
    local logfile="$LOG_DIR/agent-${AGENT_ID}.log"

    # Write enough to trigger rotation
    for i in $(seq 1 20); do
        log "padding message number $i to fill the log file up"
    done

    # Check that rotated file exists
    [[ -f "${logfile}.0" ]]
}

@test "check_auth fails with no credentials" {
    unset ANTHROPIC_API_KEY
    unset CLAUDE_CODE_OAUTH_TOKEN
    # Source check_auth function
    eval "$(sed -n '/^check_auth()/,/^}/p' /entrypoint.sh)"
    run check_auth
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR"* ]]
}

@test "check_auth succeeds with ANTHROPIC_API_KEY" {
    export ANTHROPIC_API_KEY="test-key"
    eval "$(sed -n '/^check_auth()/,/^}/p' /entrypoint.sh)"
    run check_auth
    [ "$status" -eq 0 ]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "settings restore removes file when no backup" {
    eval "$(sed -n '/^restore_settings()/,/^}/p' /entrypoint.sh)"
    SETTINGS_LOCAL="$TEST_DIR/settings.local.json"
    SETTINGS_BACKUP=""
    touch "$SETTINGS_LOCAL"
    restore_settings
    [[ ! -f "$SETTINGS_LOCAL" ]]
}

@test "settings restore writes backup content" {
    eval "$(sed -n '/^restore_settings()/,/^}/p' /entrypoint.sh)"
    SETTINGS_LOCAL="$TEST_DIR/settings.local.json"
    SETTINGS_BACKUP='{"test":"value"}'
    restore_settings
    [[ "$(cat "$SETTINGS_LOCAL")" == '{"test":"value"}' ]]
}
