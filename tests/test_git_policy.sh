#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export LOG_DIR="$TMPDIR/logs"
export EVENT_LOG="$LOG_DIR/events.jsonl"
export AGENT_ID="gitpolicy"
export ITERATION="0"
export AGENTMILL_RUN_ID="git-policy-test"

# shellcheck source=../entrypoint-common.sh
. "$REPO_ROOT/entrypoint-common.sh"

repo="$TMPDIR/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m base
cd "$repo"

assert_denies_protected_direct() {
    AGENTMILL_PROFILE_LEVEL=standard
    AGENT_BRANCH=main
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES=false
    if enforce_git_branch_policy false >/dev/null; then
        echo "expected standard direct protected branch writes to be denied" >&2
        exit 1
    fi
}

assert_allows_readonly_clone_main() {
    AGENTMILL_PROFILE_LEVEL=standard
    AGENT_BRANCH=main
    AGENTMILL_WORKSPACE_MODE=readonly-clone
    AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES=false
    enforce_git_branch_policy true >/dev/null
}

assert_allows_override() {
    AGENTMILL_PROFILE_LEVEL=untrusted
    AGENT_BRANCH=main
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES=true
    enforce_git_branch_policy false >/dev/null
}

assert_denies_branch_mismatch() {
    AGENTMILL_PROFILE_LEVEL=trusted
    AGENT_BRANCH=agent-1
    AGENTMILL_WORKSPACE_MODE=direct
    if enforce_git_branch_policy false >/dev/null; then
        echo "expected branch mismatch to be denied" >&2
        exit 1
    fi
}

assert_remote_policy_allows_agent_branch() {
    git checkout -q -B agent-1
    AGENTMILL_PROFILE_LEVEL=standard
    AGENT_BRANCH=agent-1
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES=false
    AGENTMILL_ALLOW_FORCE_PUSH=false
    AGENTMILL_NETWORK=
    AGENTMILL_GIT_REMOTE_ALLOWLIST=
    AGENTMILL_ALLOW_GIT_NETWORK=false
    enforce_git_remote_action_policy push agent-1 >/dev/null
    enforce_git_remote_action_policy rebase agent-1 >/dev/null
}

assert_remote_policy_denies_mismatch() {
    git checkout -q -B agent-1
    AGENTMILL_PROFILE_LEVEL=trusted
    AGENT_BRANCH=agent-1
    AGENTMILL_WORKSPACE_MODE=direct
    if enforce_git_remote_action_policy push other-branch >/dev/null; then
        echo "expected remote branch mismatch to be denied" >&2
        exit 1
    fi
}

assert_remote_policy_denies_invalid_ref() {
    git checkout -q -B agent-1
    AGENTMILL_PROFILE_LEVEL=trusted
    AGENT_BRANCH=""
    AGENTMILL_WORKSPACE_MODE=direct
    if enforce_git_remote_action_policy push "-bad" >/dev/null; then
        echo "expected invalid remote ref to be denied" >&2
        exit 1
    fi
}

assert_remote_policy_denies_protected_push() {
    git checkout -q main
    AGENTMILL_PROFILE_LEVEL=standard
    AGENT_BRANCH=main
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES=false
    if enforce_git_remote_action_policy push main >/dev/null; then
        echo "expected standard protected branch push to be denied" >&2
        exit 1
    fi
}

assert_remote_policy_denies_force_push() {
    git checkout -q -B agent-1
    AGENTMILL_PROFILE_LEVEL=trusted
    AGENT_BRANCH=agent-1
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_ALLOW_FORCE_PUSH=false
    AGENTMILL_NETWORK=
    AGENTMILL_GIT_REMOTE_ALLOWLIST=
    AGENTMILL_ALLOW_GIT_NETWORK=false
    if enforce_git_remote_action_policy force_push agent-1 >/dev/null; then
        echo "expected force-push to be denied by default" >&2
        exit 1
    fi
}

assert_remote_policy_denies_network_denied_origin() {
    git checkout -q -B agent-1
    git remote remove origin 2>/dev/null || true
    git remote add origin https://github.com/acme/repo.git
    AGENTMILL_PROFILE_LEVEL=trusted
    AGENT_BRANCH=agent-1
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_NETWORK=deny
    AGENTMILL_ALLOW_GIT_NETWORK=false
    AGENTMILL_GIT_REMOTE_ALLOWLIST=
    if enforce_git_remote_action_policy fetch agent-1 >/dev/null; then
        echo "expected AGENTMILL_NETWORK=deny to block network git origin" >&2
        exit 1
    fi
}

assert_remote_policy_allows_allowlisted_network_origin() {
    git checkout -q -B agent-1
    git remote remove origin 2>/dev/null || true
    git remote add origin git@github.com:acme/repo.git
    AGENTMILL_PROFILE_LEVEL=trusted
    AGENT_BRANCH=agent-1
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_NETWORK=deny
    AGENTMILL_ALLOW_GIT_NETWORK=true
    AGENTMILL_GIT_REMOTE_ALLOWLIST=github.com/acme/repo
    enforce_git_remote_action_policy fetch agent-1 >/dev/null
}

assert_remote_policy_denies_non_allowlisted_network_origin() {
    git checkout -q -B agent-1
    git remote remove origin 2>/dev/null || true
    git remote add origin https://github.com/acme/repo.git
    AGENTMILL_PROFILE_LEVEL=trusted
    AGENT_BRANCH=agent-1
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_NETWORK=allowlist
    AGENTMILL_ALLOW_GIT_NETWORK=true
    AGENTMILL_GIT_REMOTE_ALLOWLIST=gitlab.com/other/repo
    if enforce_git_remote_action_policy push agent-1 >/dev/null; then
        echo "expected non-allowlisted git origin to be denied" >&2
        exit 1
    fi
}

assert_remote_policy_allows_local_origin_when_network_denied() {
    git checkout -q -B agent-1
    git remote remove origin 2>/dev/null || true
    git remote add origin "$TMPDIR/upstream"
    AGENTMILL_PROFILE_LEVEL=trusted
    AGENT_BRANCH=agent-1
    AGENTMILL_WORKSPACE_MODE=direct
    AGENTMILL_NETWORK=deny
    AGENTMILL_ALLOW_GIT_NETWORK=false
    AGENTMILL_GIT_REMOTE_ALLOWLIST=
    enforce_git_remote_action_policy push agent-1 >/dev/null
}

assert_merge_policy_denies_standard_merge() {
    git remote remove origin 2>/dev/null || true
    git checkout -q main
    git branch -D merge-main merge-feature 2>/dev/null || true
    git checkout -q -B merge-main main
    printf 'main side\n' > main-side.txt
    git add main-side.txt
    git commit -q -m merge-main-side
    git checkout -q -B merge-feature HEAD~1
    printf 'feature side\n' > feature-side.txt
    git add feature-side.txt
    git commit -q -m merge-feature-side
    base_before_merge="$(git rev-parse HEAD)"
    git merge -q --no-ff merge-main -m merge-test

    AGENTMILL_PROFILE_LEVEL=standard
    AGENTMILL_ALLOW_MERGE_COMMITS=false
    if enforce_git_merge_policy "$base_before_merge" >/dev/null; then
        echo "expected standard merge commits to be denied" >&2
        exit 1
    fi

    AGENTMILL_ALLOW_MERGE_COMMITS=true
    enforce_git_merge_policy "$base_before_merge" >/dev/null

    AGENTMILL_PROFILE_LEVEL=trusted
    AGENTMILL_ALLOW_MERGE_COMMITS=false
    enforce_git_merge_policy "$base_before_merge" >/dev/null
}

assert_denies_protected_direct
assert_allows_readonly_clone_main
assert_allows_override
assert_denies_branch_mismatch
assert_remote_policy_allows_agent_branch
assert_remote_policy_denies_mismatch
assert_remote_policy_denies_invalid_ref
assert_remote_policy_denies_protected_push
assert_remote_policy_denies_force_push
assert_remote_policy_denies_network_denied_origin
assert_remote_policy_allows_allowlisted_network_origin
assert_remote_policy_denies_non_allowlisted_network_origin
assert_remote_policy_allows_local_origin_when_network_denied
assert_merge_policy_denies_standard_merge

grep -q 'case "$AUTO_COMMIT"' "$REPO_ROOT/entrypoint-tui.sh"
grep -q 'Auto-commit disabled' "$REPO_ROOT/entrypoint-tui.sh"
grep -q 'enforce_git_remote_action_policy push "$branch"' "$REPO_ROOT/entrypoint.sh"
grep -q 'enforce_git_remote_action_policy rebase "$branch"' "$REPO_ROOT/entrypoint.sh"
grep -q 'enforce_git_merge_policy "$ITER_HEAD_BEFORE"' "$REPO_ROOT/entrypoint.sh"

python3 - "$EVENT_LOG" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1])]
denied = [event for event in events if event["type"] == "policy.denied"]
allowed = [event for event in events if event["type"] == "policy.allowed"]

assert any(event["payload"]["reason"] == "protected_branch_write" for event in denied), events
assert any(event["payload"]["reason"] == "branch_mismatch" for event in denied), events
assert any(event["payload"]["reason"] == "git_branch_policy" for event in allowed), events
assert any(event["payload"]["reason"] == "protected_branch_override" for event in allowed), events
assert any(event["payload"]["reason"] == "git_remote_action_policy" for event in allowed), events
assert any(event["payload"]["reason"] == "git_action_branch_mismatch" for event in denied), events
assert any(event["payload"]["reason"] == "invalid_git_ref" for event in denied), events
assert any(event["payload"]["reason"] == "protected_branch_remote_action" for event in denied), events
assert any(event["payload"]["reason"] == "force_push_disallowed" for event in denied), events
assert any(event["payload"]["reason"] == "git_network_denied" for event in denied), events
assert any(event["payload"]["reason"] == "git_remote_not_allowlisted" for event in denied), events
assert any(event["payload"]["reason"] == "git_remote_allowlist" for event in allowed), events
assert any(event["payload"]["reason"] == "git_remote_local" for event in allowed), events
assert any(event["payload"]["reason"] == "merge_commits_disallowed" for event in denied), events
assert any(event["payload"]["reason"] == "merge_commit_override" for event in allowed), events
PY

echo "PASS test_git_policy"
