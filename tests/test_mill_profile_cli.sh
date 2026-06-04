#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
export AGENTMILL_EGRESS_ALLOWLIST=api.anthropic.com

repo="$TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'test\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m init

harness="$TMPDIR/harness"
mkdir -p "$harness"
cp "$REPO_ROOT/mill" "$REPO_ROOT/docker-compose.yml" "$harness/"
cp -R "$REPO_ROOT/agents" "$REPO_ROOT/scripts" "$harness/"
chmod +x "$harness/mill"

mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
    exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
    printf 'ARGS:%s\n' "$*"
    env | sort | grep -E '^(AGENTMILL_ROLE|AGENTMILL_RUN_MODE|AGENTMILL_PROFILE_LEVEL|AGENTMILL_MCP_ALLOWLIST|AGENTMILL_FORWARD_HOST_MCP|AGENTMILL_WORKSPACE_MODE|PROMPT_FILE|MODEL|MAX_ITERATIONS|MAX_WALL_SECONDS|MAX_LOG_BYTES|MAX_TOTAL_TOKENS|MAX_TOTAL_USD|LOOP_DELAY|AUTO_COMMIT|AGENT_BRANCH)=' || true
    env | sort | grep -E '^(AGENTMILL_ROLE|AGENTMILL_PROFILE_LEVEL|AGENTMILL_MCP_ALLOWLIST|AGENTMILL_FORWARD_HOST_MCP|PROMPT_FILE|MODEL|MAX_ITERATIONS|MAX_WALL_SECONDS|MAX_LOG_BYTES|MAX_TOTAL_TOKENS|MAX_TOTAL_USD|AGENT_BRANCH)_[123]=' || true
    exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
SH
chmod +x "$TMPDIR/bin/docker"

assert_contains() {
    local haystack="$1" needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "expected output to contain: $needle" >&2
        echo "actual output:" >&2
        printf '%s\n' "$haystack" >&2
        return 1
    fi
}

run_output="$(PATH="$TMPDIR/bin:$PATH" "$harness/mill" run "$repo" --agent researcher-depth --iterations 2 --max-log-bytes 12345 --max-total-tokens 1000 --max-total-usd 1.25 --model haiku)"
assert_contains "$run_output" "ARGS:compose -f $harness/docker-compose.yml"
assert_contains "$run_output" " up headless-clone"
assert_contains "$run_output" "AGENTMILL_ROLE=researcher-depth"
assert_contains "$run_output" "AGENTMILL_WORKSPACE_MODE=readonly-clone"
assert_contains "$run_output" "PROMPT_FILE=/prompts/PROMPT_RESEARCH_DEPTH.md"
assert_contains "$run_output" "AGENTMILL_MCP_ALLOWLIST=BrightData"
assert_contains "$run_output" "AGENTMILL_FORWARD_HOST_MCP=true"
assert_contains "$run_output" "MODEL=haiku"
assert_contains "$run_output" "MAX_ITERATIONS=2"
assert_contains "$run_output" "MAX_LOG_BYTES=12345"
assert_contains "$run_output" "MAX_TOTAL_TOKENS=1000"
assert_contains "$run_output" "MAX_TOTAL_USD=1.25"

trusted_output="$(PATH="$TMPDIR/bin:$PATH" "$harness/mill" run "$repo" --profile-level trusted --iterations 1)"
assert_contains "$trusted_output" "ARGS:compose -f $harness/docker-compose.yml"
assert_contains "$trusted_output" " up headless"
assert_contains "$trusted_output" "AGENTMILL_PROFILE_LEVEL=trusted"
assert_contains "$trusted_output" "AGENTMILL_WORKSPACE_MODE=direct"

exec_output="$(PATH="$TMPDIR/bin:$PATH" "$harness/mill" exec "$repo" --agent reviewer --max-log-bytes 999)"
assert_contains "$exec_output" "ARGS:compose -f $harness/docker-compose.yml"
assert_contains "$exec_output" " run --rm headless-clone"
assert_contains "$exec_output" "AGENTMILL_RUN_MODE=exec"
assert_contains "$exec_output" "AGENTMILL_ROLE=reviewer"
assert_contains "$exec_output" "AGENTMILL_WORKSPACE_MODE=readonly-clone"
assert_contains "$exec_output" "MAX_ITERATIONS=1"
assert_contains "$exec_output" "LOOP_DELAY=0"
assert_contains "$exec_output" "AUTO_COMMIT=off"
assert_contains "$exec_output" "MAX_LOG_BYTES=999"

set +e
direct_output="$(PATH="$TMPDIR/bin:$PATH" "$harness/mill" run "$repo" --agent researcher-depth --workspace-mode direct 2>&1)"
direct_rc=$?
set -e
[[ "$direct_rc" -ne 0 ]] || { echo "expected standard direct workspace mode to fail without override" >&2; exit 1; }
assert_contains "$direct_output" "standard/untrusted direct workspace mode requires AGENTMILL_ALLOW_DIRECT_HOST_REPO=true"

multi_output="$(PATH="$TMPDIR/bin:$PATH" "$harness/mill" multi "$repo" --roles coder,researcher-depth)"
assert_contains "$multi_output" "ARGS:compose -f $harness/docker-compose.yml"
assert_contains "$multi_output" " up agent-1 agent-2"
assert_contains "$multi_output" "AGENTMILL_ROLE_1=coder"
assert_contains "$multi_output" "AGENTMILL_ROLE_2=researcher-depth"
assert_contains "$multi_output" "PROMPT_FILE_1=/prompts/PROMPT.md"
assert_contains "$multi_output" "PROMPT_FILE_2=/prompts/PROMPT_RESEARCH_DEPTH.md"
assert_contains "$multi_output" "AGENT_BRANCH_1=agent-1"
assert_contains "$multi_output" "AGENT_BRANCH_2=main"
assert_contains "$multi_output" "MAX_LOG_BYTES_1=52428800"
assert_contains "$multi_output" "MAX_LOG_BYTES_2=52428800"

echo "PASS test_mill_profile_cli"
