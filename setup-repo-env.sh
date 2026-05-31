#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:-$PWD}"
AUTO_SETUP="${AUTO_SETUP:-true}"
REPO_SETUP_COMMAND="${REPO_SETUP_COMMAND:-}"
EXTRA_PYTHON_TOOLS="${EXTRA_PYTHON_TOOLS:-}"

repo_log() { echo "[repo-setup] $*"; }

has_pyproject_field() {
    local pattern="$1"
    [[ -f pyproject.toml ]] && rg -q "$pattern" pyproject.toml && rg -q '^\s*dev\s*=' pyproject.toml
}

activate_venv() {
    [[ -d "$REPO_DIR/.venv/bin" ]] && export PATH="$REPO_DIR/.venv/bin:$PATH" && repo_log "Using virtualenv at $REPO_DIR/.venv"
    return 0
}

ensure_venv() {
    [[ -d .venv ]] || { repo_log "Creating virtualenv"; python3 -m venv .venv; }
    . .venv/bin/activate
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel
}

install_extra_python_tools() {
    [[ -z "$EXTRA_PYTHON_TOOLS" ]] && return
    [[ -x "$REPO_DIR/.venv/bin/python" ]] || { repo_log "Creating virtualenv for extra tools"; python3 -m venv "$REPO_DIR/.venv"; }
    repo_log "Installing extra Python tools: $EXTRA_PYTHON_TOOLS"
    # shellcheck disable=SC2086
    "$REPO_DIR/.venv/bin/python" -m pip install --no-cache-dir $EXTRA_PYTHON_TOOLS
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
        has_pyproject_field '^\[project\.optional-dependencies\]' && uv_args+=(--extra dev)
        has_pyproject_field '^\[dependency-groups\]' && uv_args+=(--group dev)
        repo_log "Running: uv ${uv_args[*]}"
        uv "${uv_args[@]}"
    elif [[ -f poetry.lock ]]; then
        command -v poetry >/dev/null 2>&1 || { repo_log "Installing Poetry"; python3 -m pip install --no-cache-dir poetry; }
        repo_log "Running: poetry install"
        poetry config virtualenvs.in-project true 2>/dev/null || true
        poetry install --no-interaction
    else
        ensure_venv
        if has_pyproject_field '^\[project\.optional-dependencies\]'; then
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
