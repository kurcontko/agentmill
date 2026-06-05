#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="redact"
export AGENTMILL_RUN_ID="redact-test"
export ITERATION=0
export ANTHROPIC_API_KEY="sk-ant-thisisasecret1234567890"
export GITHUB_TOKEN="ghp_123456789012345678901234567890123456"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

assert_not_contains() {
    local file="$1" needle="$2"
    if grep -qF "$needle" "$file"; then
        echo "expected $file not to contain secret: $needle" >&2
        echo "actual file:" >&2
        cat "$file" >&2
        return 1
    fi
}

log "agent log has ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY and bearer Bearer abcdefghijklmnopqrstuvwxyz0123456789"

session_log="$TMPDIR/session.log"
{
    printf 'anthropic token %s\n' "$ANTHROPIC_API_KEY"
    printf 'github token %s\n' "$GITHUB_TOKEN"
    printf 'github pattern ghp_abcdefghijklmnopqrstuvwxyz1234567890\n'
    printf 'bearer Bearer abcdefghijklmnopqrstuvwxyz0123456789\n'
    printf 'env GITHUB_TOKEN=%s\n' "$GITHUB_TOKEN"
    printf 'generic sk-abcdefghijklmnopqrstuvwxyz123456\n'
} | redacted_tee "$session_log" >/tmp/agentmill-redacted-stdout.txt

for file in "$LOG_DIR/agent-redact.log" "$session_log" /tmp/agentmill-redacted-stdout.txt; do
    assert_not_contains "$file" "$ANTHROPIC_API_KEY"
    assert_not_contains "$file" "$GITHUB_TOKEN"
    assert_not_contains "$file" "ghp_abcdefghijklmnopqrstuvwxyz1234567890"
    assert_not_contains "$file" "Bearer abcdefghijklmnopqrstuvwxyz0123456789"
    assert_not_contains "$file" "sk-abcdefghijklmnopqrstuvwxyz123456"
done

grep -q "\[REDACTED\]" "$LOG_DIR/agent-redact.log"
grep -q "\[REDACTED\]" "$session_log"
grep -q "\[REDACTED_GITHUB_TOKEN\]" "$session_log"
grep -q "Bearer \[REDACTED_TOKEN\]" "$session_log"
grep -q "\[REDACTED_API_KEY\]" "$session_log"

echo "PASS test_log_redaction"
