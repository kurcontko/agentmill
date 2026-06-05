#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

harness="$TMPDIR/harness"
repo="$TMPDIR/repo"
mkdir -p "$harness/memory" "$repo"
cp "$REPO_ROOT/mill" "$harness/mill"
chmod +x "$harness/mill"

git -C "$repo" init -q
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m base

assert_fails_with() {
    local expected="$1"
    shift
    local output rc
    set +e
    output="$("$harness/mill" "$@" 2>&1)"
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]] || {
        echo "expected command to fail: mill $*" >&2
        return 1
    }
    [[ "$output" == *"$expected"* ]] || {
        echo "expected output to contain: $expected" >&2
        echo "actual output:" >&2
        printf '%s\n' "$output" >&2
        return 1
    }
}

assert_fails_with "--iterations requires a value" run "$repo" --iterations
assert_fails_with "unknown run option: --bogus" run "$repo" --bogus
assert_fails_with "unexpected run argument: extra" run "$repo" extra
assert_fails_with "--max-total-usd must be a non-negative number" run "$repo" --max-total-usd nope
assert_fails_with "--transport must be one of: native, acp" watch "$repo" --transport bogus
assert_fails_with "--platform requires a value" build --platform
assert_fails_with "invalid memory topic '../escape'" memory ../escape
assert_fails_with "invalid agent id '../agent'" logs ../agent
assert_fails_with "--tail must be a positive integer" events --tail nope

echo "PASS test_mill_arg_validation"
