#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
fakebin="$TMPDIR/bin"
mkdir -p "$harness/logs" "$fakebin"
cp "$REPO_ROOT/mill" "$REPO_ROOT/docker-compose.yml" "$harness/"
chmod +x "$harness/mill"

cat > "$fakebin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALL_LOG"
if [[ "$1" == "compose" && "${2:-}" == "version" ]]; then
    exit 0
fi
if [[ "$1" == "compose" && "$*" == *" down"* ]]; then
    exit 0
fi
echo "unexpected docker args: $*" >&2
exit 1
SH
chmod +x "$fakebin/docker"

export PATH="$fakebin:$PATH"
export DOCKER_CALL_LOG="$TMPDIR/docker.log"

cat > "$harness/logs/events.jsonl" <<'JSONL'
{"version":1,"timestamp":"2026-05-29T00:00:00Z","run_id":"old-run","agent_id":"worker","profile":"standard","iteration":1,"type":"loop.stopped","payload":{"reason":"completion","gate":"done_file"}}
{"version":1,"timestamp":"2026-05-29T00:01:00Z","run_id":"run-1","agent_id":"worker","profile":"standard","iteration":3,"type":"convergence.evaluated","payload":{"gate":"coder_verified","passed":true}}
JSONL

output="$("$harness/mill" stop --on-converge --timeout 1 --agent worker --run-id run-1)"
[[ "$output" == *"Convergence observed: event convergence.evaluated passed run_id=run-1 agent=worker gate=coder_verified"* ]]
grep -q 'compose -f .*/docker-compose.yml down' "$DOCKER_CALL_LOG"

before_calls="$(wc -l < "$DOCKER_CALL_LOG")"
set +e
timeout_output="$("$harness/mill" stop --on-converge --timeout 0.1 --agent worker --run-id missing 2>&1)"
timeout_rc=$?
set -e
[[ "$timeout_rc" -ne 0 ]]
[[ "$timeout_output" == *"Timed out waiting for convergence"* ]]
after_calls="$(wc -l < "$DOCKER_CALL_LOG")"
[[ "$after_calls" == "$before_calls" ]]

cat > "$harness/logs/convergence.tsv" <<'TSV'
iteration	agent	timestamp	gate	passed	value	threshold	evidence	hook_decision
4	gate	2026-05-29T00:02:00Z	research_saturation	true	zero_source_streak=3;open_questions=0	zero_source_streak>=3;open_questions<=0	results=x	allow
TSV
tsv_output="$("$harness/mill" stop --on-converge --timeout 1 --agent gate)"
[[ "$tsv_output" == *"Convergence observed: convergence.tsv passed agent=gate iteration=4 gate=research_saturation"* ]]

echo "PASS test_mill_stop_on_converge"
