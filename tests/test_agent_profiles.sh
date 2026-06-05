#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_contains() {
    local haystack="$1" needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "expected output to contain: $needle" >&2
        echo "actual output:" >&2
        printf '%s\n' "$haystack" >&2
        return 1
    fi
}

depth_exports="$(python3 "$REPO_ROOT/scripts/profile-env.py" "$REPO_ROOT/agents/researcher-depth.toml" --role researcher-depth --agent-id 2)"
assert_contains "$depth_exports" "export AGENTMILL_ROLE=researcher-depth"
assert_contains "$depth_exports" "export PROMPT_FILE=/prompts/PROMPT_RESEARCH_DEPTH.md"
assert_contains "$depth_exports" "export AGENT_BRANCH=main"
assert_contains "$depth_exports" "export AGENTMILL_PROFILE_LEVEL=standard"
assert_contains "$depth_exports" "export AGENTMILL_COMPLETION_GATE=research_saturation"
assert_contains "$depth_exports" "export AGENTMILL_RESEARCH_SATURATION_ITERATIONS=3"
assert_contains "$depth_exports" "export AGENTMILL_RESEARCH_OPEN_QUESTIONS_MAX=0"
assert_contains "$depth_exports" "export AGENTMILL_MCP_ALLOWLIST=BrightData"
assert_contains "$depth_exports" "export AGENTMILL_FORWARD_HOST_MCP=true"

suffix_exports="$(python3 "$REPO_ROOT/scripts/profile-env.py" "$REPO_ROOT/agents/coder.toml" --role coder --agent-id 3 --suffix _3)"
assert_contains "$suffix_exports" "export AGENTMILL_ROLE_3=coder"
assert_contains "$suffix_exports" "export PROMPT_FILE_3=/prompts/PROMPT.md"
assert_contains "$suffix_exports" "export AGENT_BRANCH_3=agent-3"
assert_contains "$suffix_exports" "export MAX_ITERATIONS_3=10"
assert_contains "$suffix_exports" "export MAX_LOG_BYTES_3=52428800"
assert_contains "$suffix_exports" "export AGENTMILL_COMPLETION_GATE_3=coder_verified"
assert_contains "$suffix_exports" "export AGENTMILL_CODER_OPEN_QUESTIONS_MAX_3=0"

default_exports="$(python3 "$REPO_ROOT/scripts/profile-env.py" "$REPO_ROOT/agents/coder.toml" --role coder --agent-id 1 --defaults)"
assert_contains "$default_exports" "export AGENTMILL_ROLE=coder"
assert_contains "$default_exports" 'if [[ -z "${AGENTMILL_NETWORK:-}" ]]; then export AGENTMILL_NETWORK=allowlist; fi'
assert_contains "$default_exports" 'if [[ -z "${MODEL:-}" ]]; then export MODEL=sonnet; fi'

suffix_default_exports="$(python3 "$REPO_ROOT/scripts/profile-env.py" "$REPO_ROOT/agents/coder.toml" --role coder --agent-id 3 --suffix _3 --defaults)"
assert_contains "$suffix_default_exports" "export AGENTMILL_ROLE_3=coder"
assert_contains "$suffix_default_exports" 'if [[ -z "${AGENTMILL_NETWORK_3:-}" && -z "${AGENTMILL_NETWORK:-}" ]]; then export AGENTMILL_NETWORK_3=allowlist; fi'
assert_contains "$suffix_default_exports" 'if [[ -z "${MODEL_3:-}" && -z "${MODEL:-}" ]]; then export MODEL_3=sonnet; fi'

tmp_profile="$(mktemp)"
cat > "$tmp_profile" <<'TOML'
prompt_file = "/prompts/PROMPT.md"
profile_level = "standard"
shell_allowlist = ["git status:*", "make test:*"]
shell_denylist = ["make deploy:*"]
write_roots = ["src", "tests"]
forward_host_tools = true
forward_host_hooks = true
forward_host_env = true
forward_host_extensions = true
TOML
forwarding_exports="$(python3 "$REPO_ROOT/scripts/profile-env.py" "$tmp_profile" --role scoped --agent-id 1)"
assert_contains "$forwarding_exports" "export AGENTMILL_SHELL_ALLOWLIST='git status:*,make test:*'"
assert_contains "$forwarding_exports" "export AGENTMILL_SHELL_DENYLIST='make deploy:*'"
assert_contains "$forwarding_exports" "export AGENTMILL_WRITE_ROOTS=src,tests"
assert_contains "$forwarding_exports" "export AGENTMILL_FORWARD_HOST_TOOLS=true"
assert_contains "$forwarding_exports" "export AGENTMILL_FORWARD_HOST_HOOKS=true"
assert_contains "$forwarding_exports" "export AGENTMILL_FORWARD_HOST_ENV=true"
assert_contains "$forwarding_exports" "export AGENTMILL_FORWARD_HOST_EXTENSIONS=true"
rm -f "$tmp_profile"

profiles="$("$REPO_ROOT/mill" profiles)"
assert_contains "$profiles" "coder"
assert_contains "$profiles" "researcher-depth"
assert_contains "$profiles" "researcher-redteam"

coder_profile="$("$REPO_ROOT/mill" profiles coder)"
assert_contains "$coder_profile" "export AGENTMILL_ROLE=coder"
assert_contains "$coder_profile" "export AGENTMILL_COMPLETION_GATE=coder_verified"
assert_contains "$coder_profile" "export MAX_WALL_SECONDS=7200"
assert_contains "$coder_profile" "export MAX_LOG_BYTES=52428800"

refactor_profile="$("$REPO_ROOT/mill" profiles refactor)"
assert_contains "$refactor_profile" "export AGENTMILL_COMPLETION_GATE=refactor_verified"
assert_contains "$refactor_profile" "export AGENTMILL_REFACTOR_MAX_LOC_DELTA=-1"

if "$REPO_ROOT/mill" profiles does-not-exist >/tmp/agentmill-profile-test.out 2>&1; then
    echo "expected unknown profile to fail" >&2
    exit 1
fi
grep -q "unknown agent role" /tmp/agentmill-profile-test.out

echo "PASS test_agent_profiles"
