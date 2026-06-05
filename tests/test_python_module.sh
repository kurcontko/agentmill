#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

module_output="$(cd "$REPO_ROOT" && python3 -m agentmill version --json)"

python3 - "$REPO_ROOT" "$module_output" <<'PY'
import json
import sys

from agentmill import Mill

repo_root = sys.argv[1]
module_output = json.loads(sys.argv[2])
assert "mill_version" in module_output, module_output

result = Mill(repo_root).call(["version", "--json"], capture_output=True, check=True)
data = json.loads(result.stdout)
assert data["mill_dir"] == repo_root, data
assert "docker_image" in data, data
PY

echo "PASS test_python_module"
