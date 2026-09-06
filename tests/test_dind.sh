#!/usr/bin/env bash
set -euo pipefail
umask 000  # disposable fixtures are writable by CI's deliberately different uid
# Host integration test; requires a Docker daemon inside a disposable VM/runner.
# All workers use a fixture CLI and dummy auth. No external model calls.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_image="${AGENTMILL_TEST_IMAGE:-agentmill:ci}"
test_root="$(mktemp -d "${AGENTMILL_TEST_TMPDIR:-/tmp}/agentmill-dind-test.XXXXXXXX")"
fixture_image="agentmill-dind-test:${test_root##*.}"
worker_ids=()

cleanup() {
    for worker in ${worker_ids[@]+"${worker_ids[@]}"}; do
        docker stop --time 5 "$worker" >/dev/null 2>&1 || true
    done
    for repo in one two; do
        [[ ! -d "$test_root/$repo" ]] || bash "$test_root/mill" -C "$test_root/$repo" stop >/dev/null 2>&1 || true
    done
    docker image rm "$fixture_image" >/dev/null 2>&1 || true
    rm -rf -- "$test_root"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cp "$ROOT/mill" "$ROOT/dind_watch.sh" "$test_root/"
mkdir -p "$test_root/dind" "$test_root/prompts" "$test_root/image"
cp "$ROOT/dind/Dockerfile" "$test_root/dind/"
cp "$ROOT/prompts/"*.md "$test_root/prompts/"
cat >"$test_root/image/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" != --help ]] || exit 0
docker info >/dev/null
docker volume create "$TEST_VOLUME" >/dev/null
docker volume ls --format '{{.Name}}' >.mill/volumes
touch .mill/READY
while [[ ! -f .mill/RELEASE ]]; do sleep 0.1; done
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0,"num_turns":4,"result":"TASK_COMPLETE"}'
STUB
chmod 755 "$test_root/image/claude"
cat >"$test_root/image/Dockerfile" <<'DOCKERFILE'
ARG BASE
FROM ${BASE}
ARG TEST_UID
# mill build maps the worker to the Linux host UID. Other image tests retain
# the deliberately foreign UID; this host CLI fixture needs that real mapping
# to open private (0700) evidence directories without weakening permissions.
RUN sed -i "s/^agent:x:[0-9]*:/agent:x:${TEST_UID}:/" /etc/passwd
COPY claude /usr/local/bin/claude
DOCKERFILE
docker build -q --build-arg "BASE=$test_image" --build-arg "TEST_UID=$(id -u)" -t "$fixture_image" "$test_root/image" >/dev/null
export AGENTMILL_IMAGE="$fixture_image" AGENTMILL_CONFIG="$test_root/config"
export XDG_STATE_HOME="$test_root/state"
printf 'ANTHROPIC_API_KEY=test\nCHECK_CMD=true\nSHUTDOWN_GRACE=1\n' >"$AGENTMILL_CONFIG"
for repo in one two; do
    mkdir -p "$test_root/$repo/.mill"
    git -C "$test_root/$repo" init -q
    printf -- '---\ntest_volume: %s\n---\nexercise the private daemon\n' "$repo" >"$test_root/$repo/MILL.md"
    git -C "$test_root/$repo" add MILL.md
    git -C "$test_root/$repo" -c user.name=test -c user.email=test@example.com commit -qm init
done
# Prepare both fixtures before handing either to the image's different uid.
# The host runner cannot chmod files created by an already-running worker.
# Precreate .mill so both the worker and host can write steering files.
chmod -R a+rwX "$test_root"
for repo in one two; do
    bash "$test_root/mill" -C "$test_root/$repo" run --dind -d --iterations 1 >"$test_root/$repo.out"
    worker="$(tail -1 "$test_root/$repo.out")"
    [[ "$worker" =~ ^[a-f0-9]{64}$ ]] || fail "no worker id: $(cat "$test_root/$repo.out")"
    worker_ids+=("$worker")
    for ((attempt = 0; attempt < 300; attempt++)); do
        [[ -f "$test_root/$repo/.mill/READY" ]] && break
        sleep 0.1
    done
    [[ -f "$test_root/$repo/.mill/READY" ]] \
        || { docker logs "$worker" >&2 || true;
             find "$XDG_STATE_HOME/agentmill/runs" -type f \
                 \( -name '*.log' -o -name outcome.json \) -exec tail -40 {} \; >&2 || true;
             fail "$repo worker did not reach its TLS daemon"; }
done
[[ "$(cat "$test_root/one/.mill/volumes")" == one ]] || fail "first daemon has unexpected volumes"
[[ "$(cat "$test_root/two/.mill/volumes")" == two ]] || fail "workers shared Docker state"
owner_one="$(docker inspect -f '{{.Name}}' "${worker_ids[0]}")"
owner_one="${owner_one#/}"
owner_two="$(docker inspect -f '{{.Name}}' "${worker_ids[1]}")"
owner_two="${owner_two#/}"
sidecar_one="$(docker ps -q --filter label=agentmill.dind --filter "label=agentmill.owner=$owner_one")"
[[ -n "$sidecar_one" ]] || fail "first sidecar missing"
# TLS listeners must not be reachable through published host ports.
[[ "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$sidecar_one")" == '{}' ]] \
    || fail "DinD published a host port"
touch "$test_root/one/.mill/RELEASE"
for ((attempt = 0; attempt < 200; attempt++)); do
    [[ -z "$(docker ps -aq --filter "label=agentmill.owner=$owner_one")" \
       && -z "$(docker network ls -q --filter "label=agentmill.owner=$owner_one")" \
       && -z "$(docker volume ls -q --filter "label=agentmill.owner=$owner_one")" ]] && break
    sleep 0.1
done
[[ "$attempt" -lt 200 ]] || fail "detached natural exit leaked DinD resources"
[[ "$(docker inspect -f '{{.State.Running}}' "${worker_ids[1]}")" == true ]] || fail "first exit stopped second worker"
[[ -n "$(docker ps -q --filter "label=agentmill.owner=$owner_two")" ]] || fail "first exit removed second daemon"
bash "$test_root/mill" -C "$test_root/two" stop >/dev/null
[[ -z "$(docker ps -aq --filter "label=agentmill.owner=$owner_two")" \
   && -z "$(docker network ls -q --filter "label=agentmill.owner=$owner_two")" \
   && -z "$(docker volume ls -q --filter "label=agentmill.owner=$owner_two")" ]] || fail "stop leaked DinD resources"
echo 'PASS: concurrent DinD runs use separate TLS daemons and clean up on detached exit/stop'
