#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
export TMPDIR

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENTMILL_HOOK_DIR="$TMPDIR/hooks"
export AGENTMILL_HOOK_TIMEOUT_SECONDS=2
export AGENT_ID="hooktest"
export ITERATION=4
export AGENTMILL_RUN_ID="hook-test"
mkdir -p "$AGENTMILL_HOOK_DIR"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

payload="$(hook_payload hook=post_iteration files_changed=2)"

run_hook missing_hook "$payload"
[[ "$HOOK_LAST_DECISION" == "allow" ]]

cat > "$AGENTMILL_HOOK_DIR/post_iteration.sh" <<'SH'
#!/usr/bin/env bash
python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["hook"] == "post_iteration"; print("{\"decision\":\"allow\",\"reason\":\"checked\",\"additional_context\":\"Review the high-risk diff before committing.\"}")'
SH
chmod +x "$AGENTMILL_HOOK_DIR/post_iteration.sh"
run_hook post_iteration "$payload"
[[ "$HOOK_LAST_DECISION" == "allow" ]]
[[ "$HOOK_LAST_REASON" == "checked" ]]
[[ "$HOOK_LAST_ADDITIONAL_CONTEXT" == "Review the high-risk diff before committing." ]]
prompt_with_context="$(prepend_hook_additional_context "Original prompt")"
[[ "$prompt_with_context" == *"## Harness Additional Context"* ]]
[[ "$prompt_with_context" == *"Review the high-risk diff before committing."* ]]
[[ "$prompt_with_context" == *"Original prompt"* ]]

rm -f "$AGENTMILL_HOOK_DIR/post_iteration.sh"

mkdir -p "$TMPDIR/prompts"
export AGENTMILL_PROMPT_ROOT="$TMPDIR/prompts"
export PROMPT_FILE="$TMPDIR/prompts/PROMPT.md"
printf 'base prompt\n' > "$PROMPT_FILE"
printf 'alternate prompt\n' > "$TMPDIR/prompts/ALT.md"
cat > "$AGENTMILL_HOOK_DIR/pre_iteration.sh" <<SH
#!/usr/bin/env bash
printf '{"decision":"allow","reason":"switch prompt","prompt_file":"$TMPDIR/prompts/ALT.md"}\n'
SH
chmod +x "$AGENTMILL_HOOK_DIR/pre_iteration.sh"
run_hook pre_iteration "$payload"
[[ "$HOOK_LAST_DECISION" == "allow" ]]
[[ "$HOOK_LAST_PROMPT_FILE" == "$TMPDIR/prompts/ALT.md" ]]
apply_hook_prompt_file_update
[[ "$PROMPT_FILE" == "$TMPDIR/prompts/ALT.md" ]]

cat > "$AGENTMILL_HOOK_DIR/pre_iteration.sh" <<'SH'
#!/usr/bin/env bash
printf '{"decision":"allow","reason":"bad prompt","prompt_file":"/etc/passwd"}\n'
SH
chmod +x "$AGENTMILL_HOOK_DIR/pre_iteration.sh"
if run_hook pre_iteration "$payload"; then
    echo "expected invalid prompt_file hook to block" >&2
    exit 1
fi
[[ "$HOOK_LAST_DECISION" == "deny" ]]
rm -f "$AGENTMILL_HOOK_DIR/pre_iteration.sh"

export AGENTMILL_ROLE="researcher-depth"
export AGENTMILL_PROFILE_LEVEL="standard"
mkdir -p "$AGENTMILL_HOOK_DIR/profiles/standard" "$AGENTMILL_HOOK_DIR/roles/researcher-depth" "$AGENTMILL_HOOK_DIR/roles/coder"
cat > "$AGENTMILL_HOOK_DIR/profiles/standard/pre_iteration.sh" <<'SH'
#!/usr/bin/env bash
printf '{"decision":"allow","reason":"standard profile","additional_context":"Standard profile context."}\n'
SH
cat > "$AGENTMILL_HOOK_DIR/roles/researcher-depth/pre_iteration.sh" <<'SH'
#!/usr/bin/env bash
printf '{"decision":"allow","reason":"research scope","additional_context":"Researcher depth context."}\n'
SH
cat > "$AGENTMILL_HOOK_DIR/roles/coder/pre_iteration.sh" <<'SH'
#!/usr/bin/env bash
printf 'coder hook should not run for researcher\n' > "$TMPDIR/coder-hook-ran"
printf '{"decision":"deny","reason":"coder hook should be scoped"}\n'
SH
chmod +x "$AGENTMILL_HOOK_DIR/profiles/standard/pre_iteration.sh" \
    "$AGENTMILL_HOOK_DIR/roles/researcher-depth/pre_iteration.sh" \
    "$AGENTMILL_HOOK_DIR/roles/coder/pre_iteration.sh"
run_hook pre_iteration "$payload"
[[ "$HOOK_LAST_DECISION" == "allow" ]]
[[ "$HOOK_LAST_ADDITIONAL_CONTEXT" == *"Standard profile context."* ]]
[[ "$HOOK_LAST_ADDITIONAL_CONTEXT" == *"Researcher depth context."* ]]
[[ ! -e "$TMPDIR/coder-hook-ran" ]]

export AGENTMILL_ROLE="coder"
if run_hook pre_iteration "$payload"; then
    echo "expected scoped coder hook to block coder role" >&2
    exit 1
fi
[[ "$HOOK_LAST_DECISION" == "deny" ]]
[[ -e "$TMPDIR/coder-hook-ran" ]]
rm -f "$TMPDIR/coder-hook-ran"

cat > "$AGENTMILL_HOOK_DIR/post_iteration.sh" <<'SH'
#!/usr/bin/env bash
printf '{"decision":"deny","reason":"dangerous files changed"}\n'
SH
chmod +x "$AGENTMILL_HOOK_DIR/post_iteration.sh"
if run_hook post_iteration "$payload"; then
    echo "expected deny hook to block" >&2
    exit 1
fi
[[ "$HOOK_LAST_DECISION" == "deny" ]]

cat > "$AGENTMILL_HOOK_DIR/post_iteration.sh" <<'SH'
#!/usr/bin/env bash
printf '{"decision":"defer","reason":"needs human review"}\n'
SH
chmod +x "$AGENTMILL_HOOK_DIR/post_iteration.sh"
if run_hook post_iteration "$payload"; then
    echo "expected defer hook to block" >&2
    exit 1
fi
[[ "$HOOK_LAST_DECISION" == "defer" ]]

cat > "$AGENTMILL_HOOK_DIR/post_iteration.sh" <<'SH'
#!/usr/bin/env bash
printf 'not-json\n'
SH
chmod +x "$AGENTMILL_HOOK_DIR/post_iteration.sh"
if run_hook post_iteration "$payload"; then
    echo "expected malformed hook output to block" >&2
    exit 1
fi
[[ "$HOOK_LAST_DECISION" == "deny" ]]

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1])]
assert any(event["type"] == "hook.skipped" for event in events), events
assert any(event["type"] == "hook.completed" and event["payload"]["decision"] == "allow" for event in events), events
assert any(event["type"] == "hook.context_injected" for event in events), events
assert any(event["type"] == "hook.prompt_file_updated" for event in events), events
assert any(event["type"] == "policy.denied" and event["payload"]["reason"] == "hook_invalid_prompt_file" for event in events), events
assert any(event["type"] == "hook.completed" and event["payload"].get("scope") == "role:researcher-depth" for event in events), events
assert any(event["type"] == "hook.completed" and event["payload"].get("scope") == "profile:standard" for event in events), events
assert any(event["type"] == "hook.completed" and event["payload"].get("scope") == "role:coder" and event["payload"]["decision"] == "deny" for event in events), events
assert any(event["type"] == "hook.completed" and event["payload"]["decision"] == "deny" for event in events), events
assert any(event["type"] == "hook.completed" and event["payload"]["decision"] == "defer" for event in events), events
assert any(event["type"] == "policy.denied" and event["payload"]["reason"] == "hook_invalid_json" for event in events), events
PY

echo "PASS test_hooks"
