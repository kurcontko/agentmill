#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
repo="$TMPDIR/repo"
mkdir -p "$harness" "$TMPDIR/bin"
cp "$REPO_ROOT/mill" "$REPO_ROOT/docker-compose.yml" "$harness/"
chmod +x "$harness/mill"

git init -q -b main "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m base

cat > "$TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
    exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
    printf '%s\n' "$@" > "${DOCKER_ARGS_LOG:?}"
    files=()
    prev=""
    for arg in "$@"; do
        if [[ "$prev" == "-f" ]]; then
            files+=("$arg")
        fi
        prev="$arg"
    done
    if [[ "${#files[@]}" -gt 1 ]]; then
        cp "${files[-1]}" "${OVERRIDE_COPY:?}"
    else
        rm -f "${OVERRIDE_COPY:?}"
    fi
    exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
SH
chmod +x "$TMPDIR/bin/docker"

export DOCKER_ARGS_LOG="$TMPDIR/docker-args.log"
export OVERRIDE_COPY="$TMPDIR/network-override.yml"

PATH="$TMPDIR/bin:$PATH" AGENTMILL_NETWORK=deny "$harness/mill" run "$repo" --profile-level trusted --iterations 1 -d
grep -Fx -- '-f' "$DOCKER_ARGS_LOG" >/dev/null
grep -q 'headless:' "$OVERRIDE_COPY"
grep -q 'network_mode: "none"' "$OVERRIDE_COPY"
if grep -q 'agent-1:' "$OVERRIDE_COPY"; then
    echo "single-service run should only override the selected service" >&2
    exit 1
fi

rm -f "$OVERRIDE_COPY"
PATH="$TMPDIR/bin:$PATH" AGENTMILL_NETWORK=allow "$harness/mill" run "$repo" --profile-level trusted --iterations 1 -d
[[ ! -f "$OVERRIDE_COPY" ]]

PATH="$TMPDIR/bin:$PATH" AGENTMILL_NETWORK=allowlist "$harness/mill" ps

set +e
PATH="$TMPDIR/bin:$PATH" AGENTMILL_NETWORK=allowlist "$harness/mill" run "$repo" --profile-level trusted --iterations 1 -d 2>"$TMPDIR/allowlist-missing.err"
missing_rc=$?
set -e
[[ "$missing_rc" -ne 0 ]] || { echo "expected allowlist without egress allowlist to fail" >&2; exit 1; }
grep -q 'AGENTMILL_NETWORK=allowlist requires AGENTMILL_EGRESS_ALLOWLIST' "$TMPDIR/allowlist-missing.err"

PATH="$TMPDIR/bin:$PATH" AGENTMILL_NETWORK=allowlist AGENTMILL_EGRESS_ALLOWLIST=api.anthropic.com "$harness/mill" run "$repo" --profile-level trusted --iterations 1 -d
grep -q 'agentmill-egress-proxy:' "$OVERRIDE_COPY"
grep -q 'headless:' "$OVERRIDE_COPY"
grep -q 'HTTP_PROXY: "http://agentmill-egress-proxy' "$OVERRIDE_COPY"
grep -q 'agentmill-egress-internal:' "$OVERRIDE_COPY"
grep -q 'internal: true' "$OVERRIDE_COPY"
if grep -q 'agent-1:' "$OVERRIDE_COPY"; then
    echo "single-service allowlist should only override the selected service" >&2
    exit 1
fi

PATH="$TMPDIR/bin:$PATH" AGENTMILL_NETWORK=allow AGENTMILL_NETWORK_2=deny "$harness/mill" multi "$repo" 2 -d
grep -q 'agent-2:' "$OVERRIDE_COPY"
grep -q 'network_mode: "none"' "$OVERRIDE_COPY"
if grep -q 'agent-1:' "$OVERRIDE_COPY"; then
    echo "per-agent deny should not disable networking for agent-1" >&2
    exit 1
fi

PATH="$TMPDIR/bin:$PATH" AGENTMILL_NETWORK=allowlist AGENTMILL_NETWORK_2=deny AGENTMILL_EGRESS_ALLOWLIST=api.anthropic.com "$harness/mill" multi "$repo" 2 -d
grep -q 'agentmill-egress-proxy:' "$OVERRIDE_COPY"
grep -q 'agent-1:' "$OVERRIDE_COPY"
grep -q 'agent-2:' "$OVERRIDE_COPY"
grep -q 'network_mode: "none"' "$OVERRIDE_COPY"
grep -q 'HTTP_PROXY: "http://agentmill-egress-proxy' "$OVERRIDE_COPY"

echo "PASS test_mill_network_policy"
