#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:-$PWD}"
AUTO_SETUP="${AUTO_SETUP:-true}"
REPO_SETUP_COMMAND="${REPO_SETUP_COMMAND:-}"
EXTRA_PYTHON_TOOLS="${EXTRA_PYTHON_TOOLS:-}"
REPO_VENV_DIR="$REPO_DIR/.venv"
if [[ -f "$REPO_DIR/uv.lock" && -n "${UV_PROJECT_ENVIRONMENT:-}" ]]; then
    REPO_VENV_DIR="$UV_PROJECT_ENVIRONMENT"
fi

repo_log() { echo "[repo-setup] $*"; }

has_dev_dependency() {
    python3 - "$1" <<'PY'
import sys
import tomllib

with open("pyproject.toml", "rb") as stream:
    table = tomllib.load(stream)
for key in sys.argv[1].split("."):
    table = table.get(key, {})
sys.exit(0 if "dev" in table else 1)
PY
}

activate_venv() {
    [[ -d "$REPO_VENV_DIR/bin" ]] && export PATH="$REPO_VENV_DIR/bin:$PATH" && repo_log "Using virtualenv at $REPO_VENV_DIR"
    return 0
}

ensure_venv() {
    [[ -d .venv ]] || { repo_log "Creating virtualenv"; python3 -m venv .venv; }
    . .venv/bin/activate
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel
}

install_extra_python_tools() {
    [[ -z "$EXTRA_PYTHON_TOOLS" ]] && return
    [[ -x "$REPO_VENV_DIR/bin/python" ]] || { repo_log "Creating virtualenv for extra tools"; python3 -m venv "$REPO_VENV_DIR"; }
    repo_log "Installing extra Python tools: $EXTRA_PYTHON_TOOLS"
    # shellcheck disable=SC2086
    "$REPO_VENV_DIR/bin/python" -m pip install --no-cache-dir $EXTRA_PYTHON_TOOLS
}

cd "$REPO_DIR"

if [[ "$AUTO_SETUP" != "true" ]]; then
    repo_log "Auto setup disabled"
    activate_venv
    return 0 2>/dev/null || exit 0
fi

if [[ -n "$REPO_SETUP_COMMAND" ]]; then
    repo_log "Running custom setup command"
    eval "$REPO_SETUP_COMMAND"
    activate_venv; install_extra_python_tools; activate_venv
    return 0 2>/dev/null || exit 0
fi

if [[ -f pyproject.toml ]]; then
    if [[ -f uv.lock ]] && command -v uv >/dev/null 2>&1; then
        uv_args=(sync --frozen)
        has_dev_dependency project.optional-dependencies && uv_args+=(--extra dev)
        has_dev_dependency dependency-groups && uv_args+=(--group dev)
        repo_log "Running: uv ${uv_args[*]}"
        uv "${uv_args[@]}"
    elif [[ -f poetry.lock ]]; then
        command -v poetry >/dev/null 2>&1 || { repo_log "Installing Poetry"; python3 -m pip install --no-cache-dir poetry; }
        repo_log "Running: poetry install"
        poetry config virtualenvs.in-project true 2>/dev/null || true
        poetry install --no-interaction # NOSONAR: preserve Poetry defaults for user-controlled repo setup.
    else
        ensure_venv
        if has_dev_dependency project.optional-dependencies; then
            python -m pip install --no-cache-dir -e '.[dev]'
        else
            python -m pip install --no-cache-dir -e .
        fi
    fi
elif [[ -f requirements.txt ]]; then
    ensure_venv
    python -m pip install --no-cache-dir -r requirements.txt
fi

install_extra_python_tools
activate_venv
