#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_dir="$(mktemp -d)"
trap 'rm -rf -- "$scratch_dir"' EXIT
install_dir="$scratch_dir/install with spaces"
mkdir -p "$install_dir" "$scratch_dir/bin"
cp "$repo_root/mill" "$install_dir/mill"
ln -s "$install_dir/mill" "$scratch_dir/bin/mill"

cat > "$scratch_dir/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$CALL_LOG"
printf '%s\n' "${DOCKER_DEFAULT_PLATFORM:-}" > "$ENV_LOG"
SH
cat > "$scratch_dir/bin/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$CALL_LOG"
printf '%s\n' "${REPO_PATH:-}" > "$ENV_LOG"
printf '%s\n' "${AGENTMILL_IMAGE:-}" > "$ENV_LOG.image"
SH
chmod +x "$scratch_dir/bin/docker" "$scratch_dir/bin/python3"

run_mill() {
    CALL_LOG="$scratch_dir/call" ENV_LOG="$scratch_dir/env" \
        PATH="$scratch_dir/bin:$PATH" "$scratch_dir/bin/mill" "$@"
}

# A symlinked launcher still builds from the installation, not the caller's cwd.
run_mill build --platform linux/amd64
printf '%s\n' build -t agentmill "$install_dir" > "$scratch_dir/expected"
cmp "$scratch_dir/call" "$scratch_dir/expected"
[[ "$(cat "$scratch_dir/env")" == linux/amd64 ]]

# Source-launcher defaults load from its own .env; explicit environment wins.
printf 'REPO_PATH="%s"\n' "$scratch_dir/default repo" > "$install_dir/.env"
unset REPO_PATH
run_mill run --task 'Fix retry handling' --check true
printf '%s\n' -I "$install_dir/basic_loop.py" run --task 'Fix retry handling' --check true > "$scratch_dir/expected"
cmp "$scratch_dir/call" "$scratch_dir/expected"
[[ "$(cat "$scratch_dir/env")" == "$scratch_dir/default repo" ]]
# The checkout runs its locally built image; an explicit selection wins.
[[ "$(cat "$scratch_dir/env.image")" == agentmill:latest ]]
AGENTMILL_IMAGE=custom:tag run_mill run --task 'Fix retry handling' --check true
[[ "$(cat "$scratch_dir/env.image")" == custom:tag ]]
REPO_PATH="$scratch_dir/selected repo" run_mill show r_1111111111111111 --runs-dir "$scratch_dir/runs"
printf '%s\n' -I "$install_dir/basic_loop.py" show r_1111111111111111 --runs-dir "$scratch_dir/runs" > "$scratch_dir/expected"
cmp "$scratch_dir/call" "$scratch_dir/expected"
[[ "$(cat "$scratch_dir/env")" == "$scratch_dir/selected repo" ]]

# Optional init preserves an existing mission and names the credential's backend.
git init -q "$scratch_dir/source"
run_mill init "$scratch_dir/source" > "$scratch_dir/init"
test -s "$scratch_dir/source/MILL.md"
grep -F -- '--agent claude' "$scratch_dir/init" > /dev/null
printf 'Keep my task\n' > "$scratch_dir/source/MILL.md"
run_mill init "$scratch_dir/source" > /dev/null
[[ "$(cat "$scratch_dir/source/MILL.md")" == 'Keep my task' ]]

run_mill --help > "$scratch_dir/help"
if grep -qi 'legacy\|compose' "$scratch_dir/help"; then
    echo 'Retired commands are still advertised' >&2
    exit 1
fi
if run_mill legacy run > "$scratch_dir/unknown" 2>&1; then
    echo 'Retired runtime unexpectedly launched' >&2
    exit 1
fi
echo 'PASS source launcher: build, environment, run/show, init, retired commands'
