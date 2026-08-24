#!/usr/bin/env bash
set -euo pipefail

# AgentMill Harness Mode — a shell with LongHorizon-Harness pointed at a repo.
#
# Unlike the other modes, AgentMill is not the agent here. LongHorizon-Harness
# is, and it drives `claude` / `codex` itself in a manager -> executor ->
# auditor loop. This entrypoint only prepares the container and hands over a
# terminal, so the harness runs against any target repo you mount.
#
# Layout:
#   /opt/lh-harness   LongHorizon-Harness source (read-only), editable-installed
#   /workspace/repo   the TARGET repo the agents work on  (REPO_PATH)
#   /workspace/runs   run data: logs, trajectories, reports
#   /workspace/state  harness_dir, kept out of the target repo

HARNESS_SRC="${HARNESS_SRC:-/opt/lh-harness}"
REPO_DIR="/workspace/repo"
RUNS_DIR="/workspace/runs"
STATE_DIR="/workspace/state"
VENV_DIR="${HARNESS_VENV:-/home/agent/.lh-venv}"
GIT_USER="${GIT_USER:-agentmill}"
GIT_EMAIL="${GIT_EMAIL:-agent@agentmill}"

# shellcheck source=/entrypoint-common.sh
. /entrypoint-common.sh

require_auth
merge_host_claude_config
configure_git_identity "$GIT_USER" "$GIT_EMAIL"

[[ -d "$REPO_DIR" ]] || { log_error "No target repo mounted at $REPO_DIR (set REPO_PATH)"; exit 1; }
mkdir -p "$RUNS_DIR" "$STATE_DIR"

# The harness source is mounted read-only, so the editable install goes into a
# venv on the container's own filesystem. Reinstall only when the entry point is
# missing or pyproject.toml is newer than it — an edit to src/ needs no rebuild
# because the editable .pth points straight at the mounted tree.
if [[ ! -d "$HARNESS_SRC" ]]; then
    log_error "LongHorizon-Harness source not mounted at $HARNESS_SRC"
    exit 1
fi
if [[ ! -x "$VENV_DIR/bin/lh-harness" || "$HARNESS_SRC/pyproject.toml" -nt "$VENV_DIR/bin/lh-harness" ]]; then
    log "Installing LongHorizon-Harness (editable) from $HARNESS_SRC"
    [[ -d "$VENV_DIR" ]] || python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/python" -m pip install --quiet --no-cache-dir --upgrade pip
    "$VENV_DIR/bin/python" -m pip install --quiet --no-cache-dir --editable "$HARNESS_SRC"
fi
export PATH="$VENV_DIR/bin:$PATH"

DASHBOARD_PORT="${DASHBOARD_PORT:-8080}"

# Default flags so a bare `lh-harness run --task ...` targets the mounted repo
# instead of creating a throwaway workspace, keeps .harness out of that repo,
# and exposes the dashboard on a published port.
LH_RUN_FLAGS=(
    --workspace "$REPO_DIR"
    --harness-dir "$STATE_DIR/.harness"
    --runs-root "$RUNS_DIR"
    --dashboard-host 0.0.0.0
    --dashboard-port "$DASHBOARD_PORT"
)
export LH_RUN_FLAGS_STR="${LH_RUN_FLAGS[*]}"

# Interactive non-login shells read .bashrc; login shells read the profile.d
# entry baked into the image. Guarded so a mounted/persisted home does not
# accumulate a copy per container start.
if ! grep -q 'lh-harness helpers' /home/agent/.bashrc 2>/dev/null; then
    # shellcheck disable=SC2016
    cat >>/home/agent/.bashrc <<BASHRC
# lh-harness helpers
export PATH="$VENV_DIR/bin:\$PATH"
lhrun() { lh-harness run \$LH_RUN_FLAGS_STR "\$@"; }
lhdash() { lh-harness dashboard --runs-root "$RUNS_DIR" --host 0.0.0.0 --port "\${DASHBOARD_PORT:-8080}"; }
BASHRC
fi

log "Harness ready"
log "  target repo : $REPO_DIR"
log "  runs        : $RUNS_DIR"
log "  agents      : $(command -v claude >/dev/null && echo -n 'claude '; command -v codex >/dev/null && echo -n 'codex')"
log "  dashboard   : http://localhost:${DASHBOARD_PORT}/ (once a run starts)"
log ""
log "  lhrun --task \"...\"          run against the mounted repo"
log "  lhdash                      browse past runs"

cd "$REPO_DIR"
if [[ $# -gt 0 ]]; then
    exec "$@"
fi
exec bash
