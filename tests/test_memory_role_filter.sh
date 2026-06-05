#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export MEMORY_DIR="$TMPDIR/memory"
export LOG_DIR="$TMPDIR/logs"
mkdir -p "$MEMORY_DIR" "$LOG_DIR"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

memory_write findings "finding" researcher
memory_write sources "https://example.com" researcher
memory_write decisions "decision" coder
memory_write failed_approaches "failed" coder

research_summary="$(AGENTMILL_ROLE=researcher-depth memory_summary)"
[[ "$research_summary" == *"[[findings]]"* ]]
[[ "$research_summary" == *"[[sources]]"* ]]
[[ "$research_summary" != *"[[decisions]]"* ]]
[[ "$research_summary" != *"[[failed_approaches]]"* ]]

coder_summary="$(AGENTMILL_ROLE=coder memory_summary)"
[[ "$coder_summary" == *"[[decisions]]"* ]]
[[ "$coder_summary" == *"[[failed_approaches]]"* ]]
[[ "$coder_summary" != *"[[sources]]"* ]]

curator_summary="$(AGENTMILL_ROLE=memory-curator memory_summary)"
[[ "$curator_summary" == *"[[findings]]"* ]]
[[ "$curator_summary" == *"[[decisions]]"* ]]
[[ "$curator_summary" == *"[[failed_approaches]]"* ]]

echo "PASS test_memory_role_filter"
