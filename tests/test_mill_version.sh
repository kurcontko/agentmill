#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

output="$(MODEL=sonnet "$REPO_ROOT/mill" version)"
flag_output="$(MODEL=sonnet "$REPO_ROOT/mill" --version)"
[[ "$output" == *"mill_version=dev"* ]]
[[ "$flag_output" == *"mill_version=dev"* ]]
[[ "$output" == *"mill_dir=$REPO_ROOT"* ]]
[[ "$output" == *"git_head="* ]]
[[ "$output" == *"git_dirty="* ]]
[[ "$output" == *"claude_code_version_arg="* ]]
[[ "$output" == *"model_default=sonnet"* ]]
[[ "$output" == *"docker_version="* ]]
[[ "$output" == *"docker_image_tag=agentmill:latest"* ]]
[[ "$output" == *"docker_image="* ]]
[[ "$output" == *"host_claude="* ]]
[[ "$output" == *"host_os="* ]]
[[ "$output" == *"host_arch="* ]]

json_output="$(MODEL=sonnet "$REPO_ROOT/mill" version --json)"
python3 - "$json_output" "$REPO_ROOT" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["mill_dir"] == sys.argv[2]
assert data["mill_version"] == "dev"
assert data["model_default"] == "sonnet"
assert "claude_code_version_arg" in data
assert data["docker_image_tag"] == "agentmill:latest"
assert "docker_image" in data
assert "host_os" in data
assert "host_arch" in data
PY

echo "PASS test_mill_version"
