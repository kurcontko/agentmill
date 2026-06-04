#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

repo="$TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'test\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m init

assert_contains() {
    local haystack="$1" needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "expected output to contain: $needle" >&2
        echo "actual output:" >&2
        printf '%s\n' "$haystack" >&2
        return 1
    fi
}

doctor_env=(
    PATH="$PATH"
    HOME="$TMPDIR/home"
    AGENTMILL_DOCTOR_SKIP_DOCKER=true
    ANTHROPIC_API_KEY=test-key
    REPO_PATH="$repo"
    PROMPT_FILE=/prompts/PROMPT.md
    AGENTMILL_PROFILE_LEVEL=standard
    AGENTMILL_WORKSPACE_MODE=auto
    MAX_ITERATIONS=1
    MAX_WALL_SECONDS=0
    MAX_LOG_BYTES=0
)

success_output="$(env "${doctor_env[@]}" "$REPO_ROOT/mill" doctor)"
assert_contains "$success_output" "[OK] profile: AGENTMILL_PROFILE_LEVEL=standard"
assert_contains "$success_output" "[OK] profile: validated"
assert_contains "$success_output" "[OK] auth: ANTHROPIC_API_KEY is set"
assert_contains "$success_output" "[OK] model: MODEL="
assert_contains "$success_output" "[WARN] docker: docker checks skipped"
assert_contains "$success_output" "[OK] prompt: /prompts/PROMPT.md maps to"
assert_contains "$success_output" "[OK] budget: MAX_LOG_BYTES=0"
assert_contains "$success_output" "[OK] completion: completion gate: done_file"
assert_contains "$success_output" "[OK] workspace: mill run/watch will auto-select readonly-clone for standard"
assert_contains "$success_output" "[OK] filesystem: containers use read-only root filesystem by default"
assert_contains "$success_output" "[OK] filesystem: runtime scratch paths are tmpfs"
assert_contains "$success_output" "[OK] filesystem: image installs bubblewrap for non-native write-root sandboxes"
assert_contains "$success_output" "[OK] skill: host skills are not copied by default"
assert_contains "$success_output" "[OK] host-config: compose mounts host Claude config and extensions read-only"
assert_contains "$success_output" "Doctor summary: 0 error(s)"

set +e
unbounded_output="$(env "${doctor_env[@]}" MAX_ITERATIONS=0 MAX_WALL_SECONDS=0 "$REPO_ROOT/mill" doctor 2>&1)"
unbounded_rc=$?
set -e
[[ "$unbounded_rc" -ne 0 ]] || { echo "expected unbounded standard profile to fail doctor" >&2; exit 1; }
assert_contains "$unbounded_output" "[ERROR] budget: standard/untrusted runs require MAX_ITERATIONS or MAX_WALL_SECONDS"

set +e
coder_gate_output="$(env "${doctor_env[@]}" AGENTMILL_COMPLETION_GATE=coder_verified AGENTMILL_VERIFIER_COMMAND= "$REPO_ROOT/mill" doctor 2>&1)"
coder_gate_rc=$?
set -e
[[ "$coder_gate_rc" -ne 0 ]] || { echo "expected coder gate without verifier to fail doctor" >&2; exit 1; }
assert_contains "$coder_gate_output" "[ERROR] completion: coder_verified requires AGENTMILL_VERIFIER_COMMAND"

refactor_gate_output="$(env "${doctor_env[@]}" AGENTMILL_COMPLETION_GATE=refactor_verified AGENTMILL_VERIFIER_COMMAND=true AGENTMILL_REFACTOR_LOC_TARGET=-3 AGENTMILL_REFACTOR_LOC_TOLERANCE=1 "$REPO_ROOT/mill" doctor)"
assert_contains "$refactor_gate_output" "[OK] completion: refactor gate has AGENTMILL_VERIFIER_COMMAND"
assert_contains "$refactor_gate_output" "[OK] completion: AGENTMILL_REFACTOR_LOC_TARGET=-3"

set +e
mcp_output="$(env "${doctor_env[@]}" AGENTMILL_FORWARD_HOST_MCP=true AGENTMILL_MCP_ALLOWLIST= "$REPO_ROOT/mill" doctor 2>&1)"
mcp_rc=$?
set -e
[[ "$mcp_rc" -ne 0 ]] || { echo "expected broad forwarded MCP to fail doctor" >&2; exit 1; }
assert_contains "$mcp_output" "[ERROR] mcp: AGENTMILL_FORWARD_HOST_MCP=true outside trusted requires AGENTMILL_MCP_ALLOWLIST"

skill_output="$(env "${doctor_env[@]}" AGENTMILL_FORWARD_HOST_EXTENSIONS=true "$REPO_ROOT/mill" doctor)"
assert_contains "$skill_output" "[WARN] skill: AGENTMILL_FORWARD_HOST_EXTENSIONS=true outside trusted but AGENTMILL_SKILL_ALLOWLIST is empty; host skills will not be copied"

network_deny_output="$(env "${doctor_env[@]}" AGENTMILL_NETWORK=deny "$REPO_ROOT/mill" doctor)"
assert_contains "$network_deny_output" "[OK] network: harness-managed git network remotes are denied"
assert_contains "$network_deny_output" "[OK] network: mill-launched services use Docker network_mode=none"

set +e
network_allowlist_missing_output="$(env "${doctor_env[@]}" AGENTMILL_NETWORK=allowlist "$REPO_ROOT/mill" doctor 2>&1)"
network_allowlist_missing_rc=$?
set -e
[[ "$network_allowlist_missing_rc" -ne 0 ]] || { echo "expected allowlist network without egress allowlist to fail doctor" >&2; exit 1; }
assert_contains "$network_allowlist_missing_output" "[ERROR] network: AGENTMILL_NETWORK=allowlist requires AGENTMILL_EGRESS_ALLOWLIST"

network_allowlist_output="$(env "${doctor_env[@]}" AGENTMILL_NETWORK=allowlist AGENTMILL_EGRESS_ALLOWLIST=api.anthropic.com "$REPO_ROOT/mill" doctor)"
assert_contains "$network_allowlist_output" "[OK] network: container egress proxy allowlist is set: api.anthropic.com"
assert_contains "$network_allowlist_output" "[OK] network: mill-launched services use Docker internal proxy network for allowlist egress"

codex_client_output="$(env "${doctor_env[@]}" AGENTMILL_CLIENT=codex AGENTMILL_CODEX_APPROVAL_POLICY= "$REPO_ROOT/mill" doctor)"
assert_contains "$codex_client_output" "[OK] client: Codex non-trusted runs default to approval_policy=untrusted with generated permission profile and execpolicy rules"

opencode_roots_output="$(env "${doctor_env[@]}" AGENTMILL_CLIENT=opencode AGENTMILL_WRITE_ROOTS=src "$REPO_ROOT/mill" doctor)"
assert_contains "$opencode_roots_output" "[OK] filesystem: AGENTMILL_WRITE_ROOTS will use bubblewrap for opencode"

set +e
codex_never_output="$(env "${doctor_env[@]}" AGENTMILL_CLIENT=codex AGENTMILL_CODEX_APPROVAL_POLICY=never "$REPO_ROOT/mill" doctor 2>&1)"
codex_never_rc=$?
set -e
[[ "$codex_never_rc" -ne 0 ]] || { echo "expected non-trusted Codex approval=never to fail doctor" >&2; exit 1; }
assert_contains "$codex_never_output" "[ERROR] client: AGENTMILL_CLIENT=codex outside trusted must not use AGENTMILL_CODEX_APPROVAL_POLICY=never"

set +e
codex_sandbox_roots_output="$(env "${doctor_env[@]}" AGENTMILL_CLIENT=codex AGENTMILL_WRITE_ROOTS=src AGENTMILL_CODEX_SANDBOX=workspace-write "$REPO_ROOT/mill" doctor 2>&1)"
codex_sandbox_roots_rc=$?
set -e
[[ "$codex_sandbox_roots_rc" -ne 0 ]] || { echo "expected Codex sandbox override plus write roots to fail doctor" >&2; exit 1; }
assert_contains "$codex_sandbox_roots_output" "[ERROR] client: AGENTMILL_CODEX_SANDBOX bypasses generated Codex permission-profile write roots"

set +e
skill_wildcard_output="$(env "${doctor_env[@]}" AGENTMILL_SKILL_ALLOWLIST='*' "$REPO_ROOT/mill" doctor 2>&1)"
skill_wildcard_rc=$?
set -e
[[ "$skill_wildcard_rc" -ne 0 ]] || { echo "expected wildcard skill allowlist to fail doctor" >&2; exit 1; }
assert_contains "$skill_wildcard_output" "[ERROR] skill: AGENTMILL_SKILL_ALLOWLIST must name explicit host skill directories, not wildcards"

harness="$TMPDIR/harness"
mkdir -p "$harness"
cp "$REPO_ROOT/mill" "$REPO_ROOT/.env.example" "$REPO_ROOT/docker-compose.yml" "$REPO_ROOT/Dockerfile" "$harness/"
chmod +x "$harness/mill"

fix_output="$(env "${doctor_env[@]}" "$harness/mill" doctor "$repo" --fix)"
assert_contains "$fix_output" "[OK] fix: ensured .env, prompts, logs, memory, and hooks exist"
[[ -f "$harness/.env" ]]
[[ -f "$harness/prompts/PROMPT.md" ]]
[[ -d "$harness/logs" ]]
[[ -d "$harness/memory" ]]
[[ -d "$harness/hooks" ]]

cat > "$harness/logs/mcp-manifest-test-agent.json" <<'JSON'
{
  "version": 1,
  "run_id": "run-123",
  "agent_id": "agent",
  "role": "researcher-depth",
  "profile": "standard",
  "mcp_allowlist": ["BrightData"],
  "enable_all_project_mcp": true,
  "tool_snapshot_enabled": true,
  "manifest_hash": "abc123",
  "servers": [
    {"name": "BrightData", "source": "claude.json:mcpServers", "config_hash": "hash1", "transport": "stdio", "command": "sh", "command_path_kind": "path", "tool_snapshot_status": "ok", "tool_count": 1, "tool_manifest_hash": "tools1", "tools": [{"name": "search", "description_hash": "desc", "input_schema_hash": "schema"}]}
  ]
}
JSON
mcp_manifest_output="$(env "${doctor_env[@]}" AGENTMILL_MCP_ALLOWLIST=BrightData "$harness/mill" doctor "$repo")"
assert_contains "$mcp_manifest_output" "[OK] mcp: allowlist: BrightData"
assert_contains "$mcp_manifest_output" "[OK] mcp: latest manifest includes allowlisted MCP server(s): BrightData"
assert_contains "$mcp_manifest_output" "[OK] mcp: BrightData stdio command reachable: sh"
assert_contains "$mcp_manifest_output" "[OK] mcp: BrightData MCP tool snapshot includes 1 tool(s)"

cat > "$harness/logs/mcp-manifest-test-agent.json" <<'JSON'
{
  "version": 1,
  "run_id": "run-123",
  "agent_id": "agent",
  "role": "researcher-depth",
  "profile": "standard",
  "mcp_allowlist": ["BrightData"],
  "enable_all_project_mcp": true,
  "manifest_hash": "abc123",
  "servers": [
    {"name": "BrightData", "source": "claude.json:mcpServers", "config_hash": "hash1", "transport": "stdio", "command": "definitely-missing-agentmill-mcp-command", "command_path_kind": "path"}
  ]
}
JSON
set +e
mcp_strict_output="$(env "${doctor_env[@]}" AGENTMILL_MCP_ALLOWLIST=BrightData AGENTMILL_DOCTOR_REQUIRE_MCP_REACHABLE=true "$harness/mill" doctor "$repo" 2>&1)"
mcp_strict_rc=$?
set -e
[[ "$mcp_strict_rc" -ne 0 ]] || { echo "expected strict MCP reachability to fail doctor" >&2; exit 1; }
assert_contains "$mcp_strict_output" "[ERROR] mcp: BrightData stdio command not reachable: definitely-missing-agentmill-mcp-command"

cat > "$harness/.env" <<EOF_ENV
REPO_PATH=$repo
ANTHROPIC_API_KEY=file-key
CLAUDE_CODE_OAUTH_TOKEN=file-token
MAX_ITERATIONS=1
UNKNOWN_AGENTMILL_KEY=typo
EOF_ENV
schema_output="$(env "${doctor_env[@]}" "$harness/mill" doctor "$repo")"
assert_contains "$schema_output" "[WARN] env: unknown .env keys: UNKNOWN_AGENTMILL_KEY"
assert_contains "$schema_output" "[WARN] env: both ANTHROPIC_API_KEY and CLAUDE_CODE_OAUTH_TOKEN are set"

mkdir -p "$harness/agents" "$harness/scripts"
cp "$REPO_ROOT/scripts/profile-env.py" "$harness/scripts/profile-env.py"
cat > "$harness/agents/bad.toml" <<'TOML'
profile_level = "root"
TOML
set +e
bad_profile_output="$(env "${doctor_env[@]}" "$harness/mill" doctor "$repo" 2>&1)"
bad_profile_rc=$?
set -e
[[ "$bad_profile_rc" -ne 0 ]] || { echo "expected malformed profile to fail doctor" >&2; exit 1; }
assert_contains "$bad_profile_output" "[ERROR] profile: invalid bad.toml:"
rm -rf "$harness/agents" "$harness/scripts"

sed -i 's/^ARG CLAUDE_CODE_VERSION=.*/ARG CLAUDE_CODE_VERSION=2.1.1/' "$harness/Dockerfile"
old_model_output="$(env "${doctor_env[@]}" MODEL=opus "$harness/mill" doctor "$repo")"
assert_contains "$old_model_output" "[WARN] model: MODEL=opus resolves to claude-opus-4-8 but Dockerfile CLAUDE_CODE_VERSION=2.1.1 is older than floor 2.1.154"

docker_bin="$TMPDIR/docker-bin"
mkdir -p "$docker_bin"
cat > "$docker_bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "info" ]]; then
    exit 0
fi
if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
    exit 0
fi
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
    if [[ "$*" == *"--format"* ]]; then
        printf '%s\n' "${DOCKER_CREATED:-2000-01-01T00:00:00Z}"
    else
        printf '[{}]\n'
    fi
    exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
SH
chmod +x "$docker_bin/docker"

stale_image_output="$(env "${doctor_env[@]}" AGENTMILL_DOCTOR_SKIP_DOCKER=false PATH="$docker_bin:$PATH" DOCKER_CREATED=2000-01-01T00:00:00Z "$harness/mill" doctor "$repo")"
assert_contains "$stale_image_output" "[WARN] image: agentmill image may be older than Dockerfile"

fresh_image_output="$(env "${doctor_env[@]}" AGENTMILL_DOCTOR_SKIP_DOCKER=false PATH="$docker_bin:$PATH" DOCKER_CREATED=2999-01-01T00:00:00Z "$harness/mill" doctor "$repo")"
assert_contains "$fresh_image_output" "[OK] image: agentmill image is newer than Dockerfile"

echo "PASS test_mill_doctor"
