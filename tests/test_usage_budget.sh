#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export USAGE_LOG="$LOG_DIR/usage.tsv"
export RESULTS_LOG="$LOG_DIR/results.tsv"
export AGENT_ID="usage"
export ITERATION="1"
export AGENTMILL_RUN_ID="usage-test"
export AGENTMILL_PROFILE_LEVEL="standard"
export MAX_ITERATIONS="1"
export MAX_WALL_SECONDS="0"
export MAX_LOG_BYTES="0"
export MAX_TOTAL_TOKENS="19"
export MAX_TOTAL_USD="0.10"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

session_log="$TMPDIR/session.jsonl"
cat > "$session_log" <<'JSONL'
not json
{"type":"message","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"cost_usd":0.12}}
JSONL

record_usage_from_session 1 usage "$session_log"
[[ "$USAGE_LAST_RECORDED" == true ]]
[[ "$USAGE_LAST_INPUT_TOKENS" == 10 ]]
[[ "$USAGE_LAST_OUTPUT_TOKENS" == 5 ]]
[[ "$USAGE_LAST_CACHE_CREATION_INPUT_TOKENS" == 2 ]]
[[ "$USAGE_LAST_CACHE_READ_INPUT_TOKENS" == 3 ]]
[[ "$USAGE_LAST_TOTAL_TOKENS" == 20 ]]
[[ "$USAGE_LAST_COST_USD" == 0.12 ]]

results_log_append 1 usage 0 0 noop exit=0 \
    "$USAGE_LAST_INPUT_TOKENS" "$USAGE_LAST_OUTPUT_TOKENS" "$USAGE_LAST_CACHE_CREATION_INPUT_TOKENS" "$USAGE_LAST_CACHE_READ_INPUT_TOKENS" "$USAGE_LAST_TOTAL_TOKENS" "$USAGE_LAST_COST_USD"

if enforce_usage_budget >/dev/null; then
    echo "expected usage budget to be exhausted" >&2
    exit 1
fi
[[ "$USAGE_BUDGET_LAST_REASON" == "max_total_tokens" ]]

python3 - "$EVENT_LOG" "$USAGE_LOG" "$RESULTS_LOG" <<'PY'
import csv
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
usage_events = [event for event in events if event["type"] == "usage.recorded"]
budget_events = [event for event in events if event["type"] == "budget.exhausted"]
assert usage_events, events
assert usage_events[-1]["payload"]["client"] == "claude"
assert usage_events[-1]["payload"]["raw_event_type"] == "usage"
assert usage_events[-1]["payload"]["total_tokens"] == 20
assert usage_events[-1]["payload"]["cost_usd"] == 0.12
assert any(event["payload"]["budget"] == "total_tokens" for event in budget_events), events
assert any(event["payload"]["budget"] == "total_usd" for event in budget_events), events

usage_rows = list(csv.DictReader(open(sys.argv[2], newline="", encoding="utf-8"), delimiter="\t"))
assert usage_rows[-1]["total_tokens"] == "20", usage_rows
assert usage_rows[-1]["cost_usd"] == "0.12", usage_rows

result_rows = list(csv.DictReader(open(sys.argv[3], newline="", encoding="utf-8"), delimiter="\t"))
assert result_rows[-1]["total_tokens"] == "20", result_rows
assert result_rows[-1]["cost_usd"] == "0.12", result_rows
PY

original_usage_log="$USAGE_LOG"
USAGE_LOG="$TMPDIR/missing-usage.tsv"
MAX_TOTAL_TOKENS=1
MAX_TOTAL_USD=0
if enforce_usage_budget >/dev/null; then
    echo "expected missing usage telemetry to exhaust configured token budget" >&2
    exit 1
fi
[[ "$USAGE_BUDGET_LAST_REASON" == "missing_usage_telemetry" ]]

USAGE_LOG="$TMPDIR/missing-cost.tsv"
printf 'iteration\tagent\ttimestamp\tinput_tokens\toutput_tokens\tcache_creation_input_tokens\tcache_read_input_tokens\ttotal_tokens\tcost_usd\n' > "$USAGE_LOG"
printf '1\tusage\t2026-05-29T00:00:00Z\t10\t5\t0\t0\t15\t0\n' >> "$USAGE_LOG"
MAX_TOTAL_TOKENS=0
MAX_TOTAL_USD=1
if enforce_usage_budget >/dev/null; then
    echo "expected missing cost telemetry to exhaust configured cost budget" >&2
    exit 1
fi
[[ "$USAGE_BUDGET_LAST_REASON" == "missing_cost_telemetry" ]]

USAGE_LOG="$original_usage_log"
MAX_TOTAL_TOKENS=19
MAX_TOTAL_USD=0.10
export AGENTMILL_COST_INPUT_PER_MTOKENS=100000
export AGENTMILL_COST_OUTPUT_PER_MTOKENS=200000
export AGENTMILL_COST_CACHE_CREATION_PER_MTOKENS=250000
export AGENTMILL_COST_CACHE_READ_PER_MTOKENS=50000
estimated_session_log="$TMPDIR/session-estimated.jsonl"
cat > "$estimated_session_log" <<'JSONL'
{"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}
JSONL
record_usage_from_session 2 usage "$estimated_session_log"
[[ "$USAGE_LAST_TOTAL_TOKENS" == 20 ]]
[[ "$USAGE_LAST_COST_USD" == 2.65 ]]

mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${CLAUDE_ARGS_LOG:?}"
printf '{"type":"message","usage":{"input_tokens":1,"output_tokens":1}}\n'
SH
chmod +x "$TMPDIR/bin/claude"
export AGENTMILL_CLIENT=claude
export AGENTMILL_CLAUDE_COMMAND="$TMPDIR/bin/claude"
export AGENTMILL_CLAUDE_OUTPUT_FORMAT=text
export CLAUDE_ARGS_LOG="$TMPDIR/claude-args.log"
client_run_headless "budgeted prompt" "$TMPDIR/claude-session.jsonl"
grep -Fx -- '--output-format' "$CLAUDE_ARGS_LOG"
grep -Fx -- 'stream-json' "$CLAUDE_ARGS_LOG"
[[ "$AGENTMILL_CLAUDE_OUTPUT_FORMAT" == "stream-json" ]]

set +e
MAX_TOTAL_TOKENS=bad validate_runtime_policy headless >/dev/null 2>&1
invalid_tokens_rc=$?
MAX_TOTAL_TOKENS=0 MAX_TOTAL_USD=bad validate_runtime_policy headless >/dev/null 2>&1
invalid_usd_rc=$?
set -e
[[ "$invalid_tokens_rc" -ne 0 ]]
[[ "$invalid_usd_rc" -ne 0 ]]

grep -q -- '--output-format "$AGENTMILL_CLAUDE_OUTPUT_FORMAT"' "$REPO_ROOT/entrypoint-common.sh"

echo "PASS test_usage_budget"
