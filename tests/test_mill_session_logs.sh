#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
mkdir -p "$harness/logs" "$TMPDIR/bin"
cp "$REPO_ROOT/mill" "$harness/mill"
chmod +x "$harness/mill"

printf 'agent 1 session\n' > "$harness/logs/session_agent-1_20260531_010000_iter1.log"
printf 'agent 2 session\n' > "$harness/logs/session_agent-2_20260531_020000_iter1.log"
touch -t 202605310100 "$harness/logs/session_agent-1_20260531_010000_iter1.log"
touch -t 202605310200 "$harness/logs/session_agent-2_20260531_020000_iter1.log"

cat > "$TMPDIR/bin/tail" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'TAIL:%s\n' "$*"
cat "${@: -1}"
SH
chmod +x "$TMPDIR/bin/tail"

output="$(PATH="$TMPDIR/bin:$PATH" "$harness/mill" logs 1 --session)"
[[ "$output" == *"=== session_agent-1_20260531_010000_iter1.log ==="* ]] || {
    echo "expected agent-1 session log header" >&2
    printf '%s\n' "$output" >&2
    exit 1
}
[[ "$output" == *"agent 1 session"* ]]
[[ "$output" != *"agent 2 session"* ]]

echo "PASS test_mill_session_logs"
