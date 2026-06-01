#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

extract_function() {
    local func_name="$1"
    local file="$2"
    sed -n "/^${func_name}()/,/^}/p" "$REPO_ROOT/$file"
    return 0
}

# Stub log_warn so resolve_model emits warnings to stderr (which is what
# the real logger does for the warn path inside resolve_model). Variable
# state can't leak out of $(...) command substitutions, so the test
# inspects captured stderr rather than a stub variable.
# shellcheck disable=SC2329
log_warn() {
    echo "WARN $*" >&2
}

eval "$(extract_function resolve_model entrypoint-common.sh)"
eval "$(extract_function log_claude_version entrypoint-common.sh)"

WARN_LOG="$(mktemp)"
LOG_OUTPUT="$(mktemp)"
TMP_BIN="$(mktemp -d)"
trap 'rm -f "$WARN_LOG" "$LOG_OUTPUT"; rm -rf "$TMP_BIN"' EXIT

cat > "$TMP_BIN/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${CLAUDE_VERSION_OUTPUT:-Claude Code 2.1.119}"
SH
chmod +x "$TMP_BIN/claude"
PATH="$TMP_BIN:$PATH"

assert_resolves() {
    local input="$1" expected="$2"
    local got
    got="$(resolve_model "$input" 2>>"$WARN_LOG")"
    if [[ "$got" != "$expected" ]]; then
        echo "FAIL: resolve_model '$input' -> '$got' (expected '$expected')" >&2
        return 1
    fi
}

assert_file_contains() {
    local file="$1" expected="$2"
    if ! grep -Fq -- "$expected" "$REPO_ROOT/$file"; then
        echo "FAIL: expected $file to contain: $expected" >&2
        return 1
    fi
}

# Family aliases default to the latest in each family.
assert_resolves "opus"            "claude-opus-4-7"
assert_resolves "sonnet"          "claude-sonnet-4-6"
assert_resolves "haiku"           "claude-haiku-4-5-20251001"

# Case-insensitive.
assert_resolves "Opus"            "claude-opus-4-7"
assert_resolves "SONNET"          "claude-sonnet-4-6"

# *-latest synonyms.
assert_resolves "opus-latest"     "claude-opus-4-7"
assert_resolves "sonnet-latest"   "claude-sonnet-4-6"
assert_resolves "haiku-latest"    "claude-haiku-4-5-20251001"

# Explicit version aliases — multiple separators.
assert_resolves "opus-4.7"        "claude-opus-4-7"
assert_resolves "opus-4-7"        "claude-opus-4-7"
assert_resolves "opus-47"         "claude-opus-4-7"
assert_resolves "opus47"          "claude-opus-4-7"
assert_resolves "sonnet-4.6"      "claude-sonnet-4-6"
assert_resolves "sonnet-46"       "claude-sonnet-4-6"
assert_resolves "haiku-4.5"       "claude-haiku-4-5-20251001"
assert_resolves "haiku-45"        "claude-haiku-4-5-20251001"

# Bare version numbers: documented mapping (current flagship of each tier).
assert_resolves "4.7"             "claude-opus-4-7"
assert_resolves "4.6"             "claude-sonnet-4-6"
assert_resolves "4.5"             "claude-haiku-4-5-20251001"

# Already-qualified IDs pass through (lowercased).
assert_resolves "claude-opus-4-7" "claude-opus-4-7"
assert_resolves "claude-sonnet-4-6" "claude-sonnet-4-6"
assert_resolves "Claude-Opus-4-7" "claude-opus-4-7"  # case-folded passthrough

# Unknown values pass through as-is and emit a WARN to stderr.
: > "$WARN_LOG"
assert_resolves "made-up-model"   "made-up-model"
grep -q "Unknown MODEL alias 'made-up-model'" "$WARN_LOG" \
    || { echo "FAIL: expected log_warn for unknown alias, got: $(cat "$WARN_LOG")" >&2; exit 1; }

# Default when no argument supplied.
assert_resolves "" "claude-sonnet-4-6"

# Resolved models must actually be passed to Claude at launch sites.
assert_file_contains "entrypoint.sh" "export MODEL"
assert_file_contains "entrypoint-tui.sh" "export MODEL"
# shellcheck disable=SC2016
assert_file_contains "entrypoint.sh" '--model "$MODEL"'
# shellcheck disable=SC2016
assert_file_contains "entrypoint-tui.sh" 'claude --model "$MODEL" || true'
# shellcheck disable=SC2016
assert_file_contains "auto-trust.exp" 'set model [expr {[info exists env(MODEL)] ? $env(MODEL) : "sonnet"}]'

log() {
    echo "LOG $*" >> "$LOG_OUTPUT"
}

log_warn() {
    echo "WARN $*" >> "$LOG_OUTPUT"
}

assert_log_contains() {
    local expected="$1"
    if ! grep -Fq -- "$expected" "$LOG_OUTPUT"; then
        echo "FAIL: expected log output to contain: $expected" >&2
        echo "actual log output:" >&2
        cat "$LOG_OUTPUT" >&2
        return 1
    fi
}

assert_log_not_contains() {
    local unexpected="$1"
    if grep -Fq -- "$unexpected" "$LOG_OUTPUT"; then
        echo "FAIL: expected log output not to contain: $unexpected" >&2
        echo "actual log output:" >&2
        cat "$LOG_OUTPUT" >&2
        return 1
    fi
}

: > "$LOG_OUTPUT"
CLAUDE_VERSION_OUTPUT="Claude Code 2.1.119" log_claude_version "claude-opus-4-7"
assert_log_contains "Claude Code CLI version: 2.1.119"
assert_log_not_contains "silent downshift likely"

: > "$LOG_OUTPUT"
CLAUDE_VERSION_OUTPUT="Claude Code 2.1.110" log_claude_version "claude-opus-4-7"
assert_log_contains "Claude Code CLI version: 2.1.110"
assert_log_contains "older than the floor 2.1.111"

: > "$LOG_OUTPUT"
CLAUDE_VERSION_OUTPUT="Claude Code 2.1.110" log_claude_version "claude-sonnet-4-6"
assert_log_contains "Claude Code CLI version: 2.1.110"
assert_log_not_contains "silent downshift likely"

: > "$LOG_OUTPUT"
CLAUDE_VERSION_OUTPUT="claude dev build" log_claude_version "claude-opus-4-7"
assert_log_contains "Could not parse claude CLI version"

echo "PASS test_resolve_model"
