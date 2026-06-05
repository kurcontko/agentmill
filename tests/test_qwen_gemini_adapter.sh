#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export USAGE_LOG="$LOG_DIR/usage.tsv"
export REPO_DIR="$TMPDIR/repo"
export DONE_FILE="$TMPDIR/done"
export AGENTMILL_RUN_ID="qwen-gemini-test"
export AGENTMILL_WRITE_ROOTS=src,tests
export BWRAP_ARGS_LOG="$TMPDIR/bwrap-args.log"

mkdir -p "$HOME" "$REPO_DIR" "$TMPDIR/bin"

cat > "$TMPDIR/bin/bwrap" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" > "${BWRAP_ARGS_LOG:?}"
cwd=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --chdir)
            cwd="${2:?}"
            shift 2
            ;;
        --)
            shift
            [[ -n "$cwd" ]] && cd "$cwd"
            exec "$@"
            ;;
        *)
            shift
            ;;
    esac
done
echo "missing bwrap command delimiter" >&2
exit 99
SH
chmod +x "$TMPDIR/bin/bwrap"
export AGENTMILL_BWRAP_COMMAND="$TMPDIR/bin/bwrap"

cat > "$TMPDIR/bin/qwen" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
    echo "qwen-code 0.14.1"
    exit 0
fi

printf 'CWD=%s\n' "$PWD" > "${QWEN_ARGS_LOG:?}"
printf '%s\n' "$@" >> "${QWEN_ARGS_LOG:?}"
printf 'QWEN_CODE_SYSTEM_SETTINGS_PATH=%s\n' "${QWEN_CODE_SYSTEM_SETTINGS_PATH:-}" >> "${QWEN_ARGS_LOG:?}"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"q-tool-1","name":"run_shell_command","input":{"command":"git status"}}],"usage":{"input_tokens":3,"output_tokens":2}}}\n'
printf '{"type":"tool_result","tool_use_id":"q-tool-1","status":"completed"}\n'
touch "${DONE_FILE:?}"
SH
chmod +x "$TMPDIR/bin/qwen"

cat > "$TMPDIR/bin/gemini" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
    echo "0.43.0"
    exit 0
fi

printf 'CWD=%s\n' "$PWD" > "${GEMINI_ARGS_LOG:?}"
printf '%s\n' "$@" >> "${GEMINI_ARGS_LOG:?}"
printf 'GEMINI_CLI_SYSTEM_SETTINGS_PATH=%s\n' "${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-}" >> "${GEMINI_ARGS_LOG:?}"
printf '{"response":"ok","stats":{"models":{"gemini-2.5-flash":{"tokens":{"prompt":10,"candidates":2,"cached":3,"thoughts":1,"tool":4,"total":20}}},"tools":{"byName":{"google_web_search":{"count":1,"success":1,"fail":0,"durationMs":50}}}}}\n'
touch "${DONE_FILE:?}"
SH
chmod +x "$TMPDIR/bin/gemini"

export AGENTMILL_QWEN_COMMAND="$TMPDIR/bin/qwen"
export AGENTMILL_QWEN_REQUIRE_AUTH=false
export QWEN_ARGS_LOG="$TMPDIR/qwen-args.log"
export AGENTMILL_GEMINI_COMMAND="$TMPDIR/bin/gemini"
export AGENTMILL_GEMINI_REQUIRE_AUTH=false
export GEMINI_ARGS_LOG="$TMPDIR/gemini-args.log"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

export AGENT_ID="qwen"
export AGENTMILL_CLIENT=qwen
export AGENTMILL_PROFILE_LEVEL=standard
export AGENTMILL_NETWORK=deny
export AGENTMILL_MCP_ALLOWLIST=BrightData
MODEL="$(client_resolve_model sonnet)"

client_select qwen
[[ "$MODEL" == "qwen3-coder-plus" ]]
client_version "$MODEL"
client_require_auth
client_prepare_home

[[ "$AGENTMILL_CLIENT_HOME" == "$HOME/.agentmill/clients/qwen" ]]
[[ "$QWEN_CODE_SYSTEM_SETTINGS_PATH" == "$AGENTMILL_CLIENT_HOME/.qwen/settings.json" ]]
[[ -L "$HOME/.qwen" ]]

python3 - "$QWEN_CODE_SYSTEM_SETTINGS_PATH" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
assert config["model"]["name"] == "qwen3-coder-plus", config
assert config["tools"]["approvalMode"] == "auto-edit", config
assert "Bash" in config["permissions"]["ask"], config
assert "WebFetch" in config["permissions"]["deny"], config
assert "Bash(git push *)" in config["permissions"]["deny"], config
assert config["mcp"]["allowed"] == ["BrightData"], config
assert "auth" in config["slashCommands"]["disabled"], config
assert config["agentmill_policy"]["client"] == "qwen", config
PY

qwen_session="$TMPDIR/qwen-session.jsonl"
client_run_headless "inspect repo" "$qwen_session"
[[ -f "$DONE_FILE" ]]
grep -Fx "CWD=$REPO_DIR" "$QWEN_ARGS_LOG"
grep -Fx -- '--prompt' "$QWEN_ARGS_LOG"
grep -Fx -- '--output-format' "$QWEN_ARGS_LOG"
grep -Fx 'stream-json' "$QWEN_ARGS_LOG"
grep -Fx -- '--model' "$QWEN_ARGS_LOG"
grep -Fx "$MODEL" "$QWEN_ARGS_LOG"
grep -Fx -- '--approval-mode' "$QWEN_ARGS_LOG"
grep -Fx 'auto_edit' "$QWEN_ARGS_LOG"
grep -Fx "QWEN_CODE_SYSTEM_SETTINGS_PATH=$QWEN_CODE_SYSTEM_SETTINGS_PATH" "$QWEN_ARGS_LOG"
grep -Fx -- '--ro-bind' "$BWRAP_ARGS_LOG"
grep -Fx "$REPO_DIR" "$BWRAP_ARGS_LOG"
grep -Fx "$REPO_DIR/src" "$BWRAP_ARGS_LOG"
grep -Fx "$REPO_DIR/tests" "$BWRAP_ARGS_LOG"
grep -Fx -- '--chdir' "$BWRAP_ARGS_LOG"
grep -Fx -- '--' "$BWRAP_ARGS_LOG"

record_tool_events_from_session 1 qwen "$qwen_session"
record_usage_from_session 1 qwen "$qwen_session"

standard_gemini_config="$TMPDIR/gemini-standard-settings.json"
MODEL="gemini-2.5-flash" AGENTMILL_CLIENT=gemini AGENTMILL_PROFILE_LEVEL=standard AGENTMILL_NETWORK=deny client_write_gemini_config "$standard_gemini_config"
python3 - "$standard_gemini_config" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
assert "run_shell_command" in config["tools"]["exclude"], config
assert config["agentmill_policy"]["profile"] == "standard", config
assert "git push:*" in config["agentmill_policy"]["shell"]["deny"], config
PY

rm -f "$DONE_FILE"
export AGENT_ID="gemini"
export AGENTMILL_CLIENT=gemini
export AGENTMILL_CLIENT_HOME=
export AGENTMILL_PROFILE_LEVEL=untrusted
export AGENTMILL_NETWORK=deny
export AGENTMILL_MCP_ALLOWLIST=
MODEL="$(client_resolve_model sonnet)"

client_select gemini
[[ "$MODEL" == "gemini-2.5-flash" ]]
client_version "$MODEL"
client_require_auth
client_prepare_home

[[ "$AGENTMILL_CLIENT_HOME" == "$HOME/.agentmill/clients/gemini" ]]
[[ "$GEMINI_CLI_SYSTEM_SETTINGS_PATH" == "$AGENTMILL_CLIENT_HOME/.gemini/settings.json" ]]
[[ -L "$HOME/.gemini" ]]

python3 - "$GEMINI_CLI_SYSTEM_SETTINGS_PATH" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
assert config["model"]["name"] == "gemini-2.5-flash", config
assert set(config["tools"]["core"]) == {"glob", "grep_search", "list_directory", "read_file", "read_many_files"}, config
for tool in ["run_shell_command", "write_file", "replace", "web_fetch", "google_web_search"]:
    assert tool in config["tools"]["exclude"], config
assert config["mcp"]["allowed"] == [], config
assert config["agentmill_policy"]["client"] == "gemini", config
PY

gemini_session="$TMPDIR/gemini-session.json"
client_run_headless "summarize repo" "$gemini_session"
[[ -f "$DONE_FILE" ]]
grep -Fx "CWD=$REPO_DIR" "$GEMINI_ARGS_LOG"
grep -Fx -- '--prompt' "$GEMINI_ARGS_LOG"
grep -Fx -- '--output-format' "$GEMINI_ARGS_LOG"
grep -Fx 'json' "$GEMINI_ARGS_LOG"
grep -Fx -- '--model' "$GEMINI_ARGS_LOG"
grep -Fx "$MODEL" "$GEMINI_ARGS_LOG"
grep -Fx -- '--approval-mode' "$GEMINI_ARGS_LOG"
grep -Fx 'default' "$GEMINI_ARGS_LOG"
grep -Fx -- '--extensions' "$GEMINI_ARGS_LOG"
grep -Fx 'none' "$GEMINI_ARGS_LOG"
grep -Fx "GEMINI_CLI_SYSTEM_SETTINGS_PATH=$GEMINI_CLI_SYSTEM_SETTINGS_PATH" "$GEMINI_ARGS_LOG"
grep -Fx "$REPO_DIR/src" "$BWRAP_ARGS_LOG"
grep -Fx "$REPO_DIR/tests" "$BWRAP_ARGS_LOG"

record_tool_events_from_session 2 gemini "$gemini_session"
record_usage_from_session 2 gemini "$gemini_session"

python3 - "$EVENT_LOG" "$USAGE_LOG" <<'PY'
import csv
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
write_sandbox_events = [event for event in events if event["type"] == "policy.allowed" and event["payload"]["reason"] == "write_root_filesystem_sandbox"]
assert len(write_sandbox_events) >= 2, events
qwen_tool = next(event for event in events if event["type"] == "tool.invoked" and event["payload"]["client"] == "qwen")
assert qwen_tool["payload"]["provider"] == "qwen_json", qwen_tool
gemini_tool = next(event for event in events if event["type"] == "tool.invoked" and event["payload"]["client"] == "gemini")
assert gemini_tool["payload"]["provider"] == "gemini_stats", gemini_tool
usage_events = [event for event in events if event["type"] == "usage.recorded"]
assert usage_events[-1]["payload"]["client"] == "gemini", usage_events[-1]
assert usage_events[-1]["payload"]["total_tokens"] == 20, usage_events[-1]

rows = list(csv.DictReader(open(sys.argv[2], newline="", encoding="utf-8"), delimiter="\t"))
assert rows[-1]["total_tokens"] == "20", rows
assert rows[-1]["input_tokens"] == "10", rows
assert rows[-1]["output_tokens"] == "7", rows
assert rows[-1]["cache_read_input_tokens"] == "3", rows
PY

grep -q '"@qwen-code/qwen-code@${QWEN_CODE_VERSION}"' "$REPO_ROOT/Dockerfile"
grep -q '"@google/gemini-cli@${GEMINI_CLI_VERSION}"' "$REPO_ROOT/Dockerfile"

echo "PASS test_qwen_gemini_adapter"
