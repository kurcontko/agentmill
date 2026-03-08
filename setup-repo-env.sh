#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:-$PWD}"
AUTO_SETUP="${AUTO_SETUP:-true}"
REPO_SETUP_COMMAND="${REPO_SETUP_COMMAND:-}"
EXTRA_PYTHON_TOOLS="${EXTRA_PYTHON_TOOLS:-}"

repo_log() {
    echo "[repo-setup] $*"
    return 0
}

has_pyproject_dev_extra() {
    [[ -f pyproject.toml ]] && rg -q '^\[project\.optional-dependencies\]' pyproject.toml && rg -q '^\s*dev\s*=' pyproject.toml
}

has_pyproject_dev_group() {
    [[ -f pyproject.toml ]] && rg -q '^\[dependency-groups\]' pyproject.toml && rg -q '^\s*dev\s*=' pyproject.toml
}

activate_venv() {
    if [[ -d "$REPO_DIR/.venv/bin" ]]; then
        export PATH="$REPO_DIR/.venv/bin:$PATH"
        repo_log "Using virtualenv at $REPO_DIR/.venv"
    fi
}

install_extra_python_tools() {
    if [[ -z "$EXTRA_PYTHON_TOOLS" ]]; then
        return
    fi

    if [[ ! -x "$REPO_DIR/.venv/bin/python" ]]; then
        repo_log "Creating virtualenv for extra Python tools"
        python3 -m venv "$REPO_DIR/.venv"
    fi

    repo_log "Installing extra Python tools: $EXTRA_PYTHON_TOOLS"
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
    activate_venv
    install_extra_python_tools
    activate_venv
    return 0 2>/dev/null || exit 0
fi

if [[ -f pyproject.toml ]]; then
    if [[ -f uv.lock ]] && command -v uv >/dev/null 2>&1; then
        uv_args=(sync --frozen)
        if has_pyproject_dev_extra; then
            uv_args+=(--extra dev)
        fi
        if has_pyproject_dev_group; then
            uv_args+=(--group dev)
        fi
        repo_log "Running: uv ${uv_args[*]}"
        uv "${uv_args[@]}"
    else
        if [[ ! -d .venv ]]; then
            repo_log "Creating virtualenv"
            python3 -m venv .venv
        fi
        repo_log "Installing project dependencies with pip"
        . .venv/bin/activate
        python -m pip install --no-cache-dir --upgrade pip setuptools wheel
        if has_pyproject_dev_extra; then
            python -m pip install --no-cache-dir -e '.[dev]'
        else
            python -m pip install --no-cache-dir -e .
        fi
    fi
elif [[ -f requirements.txt ]]; then
    if [[ ! -d .venv ]]; then
        repo_log "Creating virtualenv"
        python3 -m venv .venv
    fi
    repo_log "Installing requirements.txt"
    . .venv/bin/activate
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel
    python -m pip install --no-cache-dir -r requirements.txt
fi

install_extra_python_tools
activate_venv
