#!/usr/bin/env bash
set -euo pipefail
# Host-only watcher, copied to a private directory before the worker starts.
# No Docker socket or cleanup authority is mounted into either container.
docker_bin="$1" state_dir="$2" sidecar="$3" network="$4" certs="$5" launcher_pid="$6"

cleanup() {
    "$docker_bin" rm -f "$sidecar" >/dev/null 2>&1 || true
    "$docker_bin" network rm "$network" >/dev/null 2>&1 || true
    "$docker_bin" volume rm "$certs" >/dev/null 2>&1 || true
    rm -f -- "$state_dir/worker.cid" "$state_dir/watch.sh"
    rmdir -- "$state_dir" 2>/dev/null || true
}
trap cleanup EXIT

# Failed launch paths clean these resources in mill's EXIT trap as well. Wait
# for the launcher, not a fixed timer: pulling the worker image can take minutes.
worker_id=""
while true; do
    [[ -d "$state_dir" ]] || exit 0
    [[ ! -f "$state_dir/worker.cid" ]] || worker_id="$(<"$state_dir/worker.cid")"
    [[ "$worker_id" =~ ^[a-f0-9]{64}$ ]] && break
    kill -0 "$launcher_pid" 2>/dev/null || exit 1
    sleep 0.5
done

# A disconnected daemon is unknown state, not proof that the worker exited.
# Retry until Docker can establish termination; never tear down a live run.
while true; do
    if "$docker_bin" wait "$worker_id" >/dev/null 2>&1; then break; fi
    if state="$("$docker_bin" inspect -f '{{.State.Running}}' "$worker_id" 2>/dev/null)"; then
        [[ "$state" == false ]] && break
    elif "$docker_bin" info >/dev/null 2>&1; then
        # --rm removed the completed worker while this watcher was reconnecting.
        break
    fi
    sleep 2
done
