#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export USAGE_LOG="$LOG_DIR/usage.tsv"
export AGENT_ID="codex"
export AGENTMILL_RUN_ID="codex-test"
export AGENTMILL_CLIENT=codex
export AGENTMILL_PROFILE_LEVEL=standard
export AGENTMILL_NETWORK=deny
export AGENTMILL_MCP_ALLOWLIST=Docs
export AGENTMILL_CODEX_REQUIRE_AUTH=false
export REPO_DIR="$TMPDIR/repo"
export DONE_FILE="$TMPDIR/done"
export CODEX_ARGS_LOG="$TMPDIR/codex-args.log"
export CODEX_PROMPT_LOG="$TMPDIR/codex-prompt.txt"

mkdir -p "$HOME" "$REPO_DIR" "$TMPDIR/bin"
cat > "$TMPDIR/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
    echo "codex 0.135.0"
    exit 0
fi

printf 'CWD=%s\n' "$PWD" > "${CODEX_ARGS_LOG:?}"
printf '%s\n' "$@" >> "${CODEX_ARGS_LOG:?}"
printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-}" >> "${CODEX_ARGS_LOG:?}"
cat > "${CODEX_PROMPT_LOG:?}"
printf '{"type":"item.started","item":{"id":"cmd-1","type":"command_execution","command":"pytest"}}\n'
printf '{"type":"item.completed","item":{"id":"cmd-1","type":"command_execution","status":"completed","exit_code":0}}\n'
printf '{"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":4,"total_tokens":14}}\n'
touch "${DONE_FILE:?}"
SH
chmod +x "$TMPDIR/bin/codex"
export AGENTMILL_CODEX_COMMAND="$TMPDIR/bin/codex"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

client_select codex
MODEL="$(client_resolve_model sonnet)"
[[ "$MODEL" == "gpt-5.3-codex" ]]
client_version "$MODEL"
client_require_auth
client_prepare_home

[[ "$AGENTMILL_CLIENT_HOME" == "$HOME/.agentmill/clients/codex" ]]
[[ "$CODEX_HOME" == "$AGENTMILL_CLIENT_HOME/.codex" ]]
[[ -L "$HOME/.codex" ]]
[[ -f "$CODEX_HOME/config.toml" ]]
[[ -f "$CODEX_HOME/rules/agentmill.rules" ]]
[[ ! -f "$CODEX_HOME/auth.json" ]]

python3 - "$CODEX_HOME/config.toml" <<'PY'
import sys
import tomllib

text = open(sys.argv[1], encoding="utf-8").read()
data = tomllib.loads(text)
assert data["model"] == "gpt-5.3-codex", data
assert data["approval_policy"] == "untrusted", data
assert data["default_permissions"] == "agentmill", data
assert "sandbox_mode" not in data, data
assert data["shell_environment_policy"]["include_only"], data
assert data["agentmill"]["profile"] == "standard", data
assert data["agentmill"]["network"] == "deny", data
assert data["agentmill"]["mcp_allowlist"] == ["Docs"], data
assert data["agentmill"]["write_roots"] == [], data
fs = data["permissions"]["agentmill"]["filesystem"]
assert fs[":minimal"] == "read", fs
assert fs["glob_scan_max_depth"] == 3, fs
roots = fs[":workspace_roots"]
assert roots["."] == "write", roots
assert roots[".env"] == "deny", roots
assert roots["**/*.env"] == "deny", roots
assert roots[".github/workflows"] == "read", roots
assert roots[".codex"] == "read", roots
assert data["permissions"]["agentmill"]["network"]["enabled"] is False, data
assert "CODEX_API_KEY" not in text, text
PY

roots_config="$TMPDIR/codex-roots.toml"
AGENTMILL_WRITE_ROOTS="src,tests" client_write_codex_config "$roots_config"
python3 - "$roots_config" <<'PY'
import sys
import tomllib

data = tomllib.loads(open(sys.argv[1], encoding="utf-8").read())
roots = data["permissions"]["agentmill"]["filesystem"][":workspace_roots"]
assert roots["."] == "read", roots
assert roots["src"] == "write", roots
assert roots["tests"] == "write", roots
assert data["agentmill"]["write_roots"] == ["src", "tests"], data
PY

allowlist_config="$TMPDIR/codex-allowlist.toml"
AGENTMILL_NETWORK=allowlist AGENTMILL_EGRESS_ALLOWLIST="api.openai.com,https://github.com/org/repo" client_write_codex_config "$allowlist_config"
python3 - "$allowlist_config" <<'PY'
import sys
import tomllib

data = tomllib.loads(open(sys.argv[1], encoding="utf-8").read())
network = data["permissions"]["agentmill"]["network"]
assert network["enabled"] is True, network
assert network["domains"]["api.openai.com"] == "allow", network
assert network["domains"]["github.com"] == "allow", network
PY

sandbox_config="$TMPDIR/codex-sandbox.toml"
AGENTMILL_CODEX_SANDBOX="read-only" client_write_codex_config "$sandbox_config"
python3 - "$sandbox_config" <<'PY'
import sys
import tomllib

data = tomllib.loads(open(sys.argv[1], encoding="utf-8").read())
assert data["sandbox_mode"] == "read-only", data
assert "default_permissions" not in data, data
assert "permissions" not in data, data
PY

host_codex="$TMPDIR/host-codex"
trusted_home="$TMPDIR/trusted-home"
standard_home="$TMPDIR/standard-home"
mkdir -p "$host_codex" "$trusted_home" "$standard_home"
printf '{"OPENAI_API_KEY":"subscription-secret"}\n' > "$host_codex/auth.json"
(
    unset CODEX_API_KEY OPENAI_API_KEY CODEX_ACCESS_TOKEN
    export HOME="$trusted_home"
    export AGENTMILL_CLIENT=codex
    export AGENTMILL_CLIENT_HOME=
    export AGENTMILL_CLIENT_HOME_ROOT="$trusted_home/.agentmill/clients"
    export AGENTMILL_CODEX_REQUIRE_AUTH=true
    export AGENTMILL_HOST_CODEX_HOME="$host_codex"
    export AGENTMILL_PROFILE_LEVEL=trusted
    export MODEL="gpt-5.3-codex"
    client_require_auth
    client_prepare_codex_home
    [[ -f "$CODEX_HOME/auth.json" ]]
    grep -q "subscription-secret" "$CODEX_HOME/auth.json"
)
(
    unset REPO_DIR
    export HOME="$TMPDIR/no-repo-dir-home"
    export AGENTMILL_CLIENT=codex
    export AGENTMILL_CLIENT_HOME=
    export AGENTMILL_CLIENT_HOME_ROOT="$HOME/.agentmill/clients"
    export AGENTMILL_HOST_CODEX_HOME=
    export AGENTMILL_PROFILE_LEVEL=trusted
    export MODEL="gpt-5.3-codex"
    mkdir -p "$HOME"
    client_prepare_codex_home
    [[ -f "$CODEX_HOME/config.toml" ]]
)
set +e
standard_auth_output="$(
    {
        unset CODEX_API_KEY OPENAI_API_KEY CODEX_ACCESS_TOKEN
        export HOME="$standard_home"
        export AGENTMILL_CLIENT=codex
        export AGENTMILL_CLIENT_HOME=
        export AGENTMILL_CLIENT_HOME_ROOT="$standard_home/.agentmill/clients"
        export AGENTMILL_CODEX_REQUIRE_AUTH=true
        export AGENTMILL_HOST_CODEX_HOME="$host_codex"
        export AGENTMILL_PROFILE_LEVEL=standard
        client_require_auth
    } 2>&1
)"
standard_auth_rc=$?
set -e
[[ "$standard_auth_rc" -ne 0 ]] || { echo "expected standard profile mounted Codex auth to fail" >&2; exit 1; }
[[ "$standard_auth_output" == *"only forwarded for trusted profile runs"* ]]

python3 - "$CODEX_HOME/rules/agentmill.rules" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
assert 'prefix_rule(pattern=["curl"], decision="forbidden")' in text, text
assert 'prefix_rule(pattern=["git", "push"], decision="forbidden")' in text, text
assert 'prefix_rule(pattern=["npm", "install"], decision="forbidden")' in text, text
PY

if command -v codex >/dev/null 2>&1; then
    curl_decision="$(codex execpolicy check --rules "$CODEX_HOME/rules/agentmill.rules" curl https://example.com 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))')"
    git_decision="$(codex execpolicy check --rules "$CODEX_HOME/rules/agentmill.rules" git push origin main 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))')"
    [[ "$curl_decision" == "forbidden" ]]
    [[ "$git_decision" == "forbidden" ]]
fi

allow_rules="$TMPDIR/codex-allow.rules"
AGENTMILL_SHELL_ALLOWLIST="git status:*" AGENTMILL_SHELL_DENYLIST="make deploy:*" client_write_codex_rules "$allow_rules"
if command -v codex >/dev/null 2>&1; then
    allow_decision="$(codex execpolicy check --rules "$allow_rules" git status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))')"
    deny_decision="$(codex execpolicy check --rules "$allow_rules" make deploy 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))')"
    [[ "$allow_decision" == "allow" ]]
    [[ "$deny_decision" == "forbidden" ]]
fi

session_log="$TMPDIR/codex-session.jsonl"
client_run_headless "run tests" "$session_log"
[[ -f "$DONE_FILE" ]]
[[ "$(cat "$CODEX_PROMPT_LOG")" == "run tests" ]]
grep -Fx "CWD=$REPO_DIR" "$CODEX_ARGS_LOG"
grep -Fx 'exec' "$CODEX_ARGS_LOG"
grep -Fx '-' "$CODEX_ARGS_LOG"
grep -Fx -- '--cd' "$CODEX_ARGS_LOG"
grep -Fx "$REPO_DIR" "$CODEX_ARGS_LOG"
grep -Fx -- '--json' "$CODEX_ARGS_LOG"
if grep -Fxq -- '--sandbox' "$CODEX_ARGS_LOG"; then
    echo "unexpected --sandbox arg when Codex permission profile is active" >&2
    exit 1
fi
if grep -Fxq -- '--ask-for-approval' "$CODEX_ARGS_LOG"; then
    echo "unexpected --ask-for-approval arg for codex exec" >&2
    exit 1
fi
grep -Fx -- '--model' "$CODEX_ARGS_LOG"
grep -Fx "$MODEL" "$CODEX_ARGS_LOG"
grep -Fx "CODEX_HOME=$CODEX_HOME" "$CODEX_ARGS_LOG"

record_tool_events_from_session 1 codex "$session_log"
record_usage_from_session 1 codex "$session_log"

python3 - "$EVENT_LOG" "$USAGE_LOG" <<'PY'
import csv
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
tool = next(event for event in events if event["type"] == "tool.invoked")
assert tool["payload"]["client"] == "codex", tool
assert tool["payload"]["provider"] == "codex_json", tool
assert tool["payload"]["tool_name"] == "Bash", tool
usage = next(event for event in events if event["type"] == "usage.recorded")
assert usage["payload"]["client"] == "codex", usage
assert usage["payload"]["total_tokens"] == 14, usage
assert usage["payload"]["output_tokens"] == 7, usage

rows = list(csv.DictReader(open(sys.argv[2], newline="", encoding="utf-8"), delimiter="\t"))
assert rows[-1]["total_tokens"] == "14", rows
assert rows[-1]["output_tokens"] == "7", rows
PY

grep -q '"@openai/codex@${CODEX_CLI_VERSION}"' "$REPO_ROOT/Dockerfile"

echo "PASS test_codex_adapter"
