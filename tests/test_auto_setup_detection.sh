#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

run_setup() {
    local repo="$1" languages="${2:-all}"
    AGENTMILL_SETUP_DRY_RUN=true AUTO_SETUP_LANGUAGES="$languages" bash "$REPO_ROOT/setup-repo-env.sh" "$repo"
}

assert_contains() {
    local haystack="$1" needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "expected output to contain: $needle" >&2
        printf '%s\n' "$haystack" >&2
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "expected output not to contain: $needle" >&2
        printf '%s\n' "$haystack" >&2
        return 1
    fi
}

make_repo="$TMPDIR/make"
mkdir -p "$make_repo"
cat > "$make_repo/Makefile" <<'MAKE'
install:
	@echo install
MAKE
touch "$make_repo/package-lock.json"
make_output="$(run_setup "$make_repo")"
assert_contains "$make_output" "Running: make install"
assert_not_contains "$make_output" "Running: npm ci"

node_repo="$TMPDIR/node"
mkdir -p "$node_repo"
touch "$node_repo/package-lock.json"
node_output="$(run_setup "$node_repo" node)"
assert_contains "$node_output" "Running: npm ci"

pnpm_repo="$TMPDIR/pnpm"
mkdir -p "$pnpm_repo"
touch "$pnpm_repo/pnpm-lock.yaml"
pnpm_output="$(run_setup "$pnpm_repo" node)"
assert_contains "$pnpm_output" "Running: pnpm install --frozen-lockfile"

yarn_repo="$TMPDIR/yarn"
mkdir -p "$yarn_repo"
touch "$yarn_repo/yarn.lock"
yarn_output="$(run_setup "$yarn_repo" node)"
assert_contains "$yarn_output" "Running: yarn install --immutable"

go_repo="$TMPDIR/go"
mkdir -p "$go_repo"
printf 'module example.com/agentmill\n' > "$go_repo/go.mod"
go_output="$(run_setup "$go_repo" go)"
assert_contains "$go_output" "Running: go mod download"

rust_repo="$TMPDIR/rust"
mkdir -p "$rust_repo"
touch "$rust_repo/Cargo.toml" "$rust_repo/Cargo.lock"
rust_output="$(run_setup "$rust_repo" rust)"
assert_contains "$rust_output" "Running: cargo fetch"

python_repo="$TMPDIR/python"
mkdir -p "$python_repo"
touch "$python_repo/requirements.txt"
skip_output="$(run_setup "$python_repo" node)"
assert_not_contains "$skip_output" "requirements.txt"
assert_not_contains "$skip_output" "pip install"

custom_repo="$TMPDIR/custom"
mkdir -p "$custom_repo"
custom_output="$(AGENTMILL_SETUP_DRY_RUN=true REPO_SETUP_COMMAND='printf custom\\n' bash "$REPO_ROOT/setup-repo-env.sh" "$custom_repo")"
assert_contains "$custom_output" "Running custom setup command"
assert_contains "$custom_output" "Running: printf custom"

echo "PASS test_auto_setup_detection"
