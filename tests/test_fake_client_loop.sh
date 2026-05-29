#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

repo="$TMPDIR/repo"
logs="$TMPDIR/logs"
prompts="$TMPDIR/prompts"
hooks="$TMPDIR/hooks"
mkdir -p "$repo" "$logs" "$prompts" "$hooks" "$TMPDIR/memory" "$TMPDIR/home"

git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m base

cat > "$prompts/PROMPT.md" <<'PROMPT'
Use the fake client to write one file and signal completion.
PROMPT

cat > "$TMPDIR/setup-claude-config.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMPDIR/setup-repo-env.sh" <<'SH'
#!/usr/bin/env bash
return 0
SH
chmod +x "$TMPDIR/setup-claude-config.sh" "$TMPDIR/setup-repo-env.sh"

cat > "$hooks/pre_iteration.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
touch "$TMPDIR/pre-hook-ran"
printf '%s\n' '{"decision":"allow","reason":"pre ok","additional_context":"hook context"}'
SH
cat > "$hooks/post_iteration.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
touch "$TMPDIR/post-hook-ran"
printf '%s\n' '{"decision":"allow","reason":"post ok"}'
SH
chmod +x "$hooks/pre_iteration.sh" "$hooks/post_iteration.sh"

set +e
REPO_DIR="$repo" \
HOME="$TMPDIR/home" \
UPSTREAM_DIR="$TMPDIR/no-upstream" \
LOG_DIR="$logs" \
MEMORY_DIR="$TMPDIR/memory" \
RESULTS_LOG="$logs/results.tsv" \
CONVERGENCE_LOG="$logs/convergence.tsv" \
USAGE_LOG="$logs/usage.tsv" \
PROMPT_FILE="$prompts/PROMPT.md" \
AGENT_ID="fake" \
AGENTMILL_RUN_ID="fake-client-loop-test" \
AGENTMILL_ENTRYPOINT_COMMON="$REPO_ROOT/entrypoint-common.sh" \
AGENTMILL_SETUP_CLAUDE_CONFIG="$TMPDIR/setup-claude-config.sh" \
AGENTMILL_SETUP_REPO_ENV="$TMPDIR/setup-repo-env.sh" \
AGENTMILL_HOOK_DIR="$hooks" \
AGENTMILL_CLIENT=fake \
AGENTMILL_FAKE_CLIENT_WRITE_FILE="fake-output.txt" \
AGENTMILL_FAKE_CLIENT_WRITE_TEXT="fake client changed the repo" \
AUTO_COMMIT=on \
MAX_ITERATIONS=1 \
LOOP_DELAY=0 \
DONE_FILE="$TMPDIR/done" \
    bash "$REPO_ROOT/entrypoint.sh" > "$TMPDIR/stdout.log" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { cat "$TMPDIR/stdout.log" >&2; exit "$rc"; }

[[ -f "$TMPDIR/pre-hook-ran" ]]
[[ -f "$TMPDIR/post-hook-ran" ]]
[[ "$(git -C "$repo" show HEAD:fake-output.txt)" == "fake client changed the repo" ]]
git -C "$repo" log --oneline -1 | grep -q 'agent-fake: iteration 1'

python3 - "$logs/events.jsonl" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
types = [event["type"] for event in events]

configured = next(event for event in events if event["type"] == "run.configured")
assert configured["payload"]["client"] == "fake", configured

assert "agent.started" in types, types
completed = next(event for event in events if event["type"] == "agent.completed")
assert completed["payload"]["client"] == "fake", completed
assert completed["payload"]["done_signaled"] is True, completed
assert completed["payload"]["completion_accepted"] is True, completed

assert "hook.completed" in types, types
assert "tool.invoked" in types, types
assert "tool.completed" in types, types
assert "claude.completed" not in types, types

iteration = next(event for event in events if event["type"] == "iteration.completed")
assert iteration["payload"]["status"] == "kept", iteration
assert iteration["payload"]["commits"] == 1, iteration
PY

echo "PASS test_fake_client_loop"
