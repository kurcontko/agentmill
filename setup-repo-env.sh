#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:-$PWD}"
AUTO_SETUP="${AUTO_SETUP:-true}"
AUTO_SETUP_LANGUAGES="${AUTO_SETUP_LANGUAGES:-all}"
REPO_SETUP_COMMAND="${REPO_SETUP_COMMAND:-}"
EXTRA_PYTHON_TOOLS="${EXTRA_PYTHON_TOOLS:-}"
AGENTMILL_SETUP_DRY_RUN="${AGENTMILL_SETUP_DRY_RUN:-false}"

repo_log() { echo "[repo-setup] $*"; }

setup_truthy() {
    case "${1:-}" in
        true|TRUE|True|1|yes|YES|Yes|on|ON|On) return 0 ;;
    esac
    return 1
}

setup_language_enabled() {
    local language="$1" item
    local -a _setup_languages
    [[ -n "$AUTO_SETUP_LANGUAGES" ]] || return 1
    IFS=',' read -r -a _setup_languages <<< "$AUTO_SETUP_LANGUAGES"
    for item in "${_setup_languages[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        case "$item" in
            all|"*"|"") return 0 ;;
            "$language") return 0 ;;
        esac
    done
    return 1
}

run_setup_command() {
    repo_log "Running: $*"
    if setup_truthy "$AGENTMILL_SETUP_DRY_RUN"; then
        return 0
    fi
    "$@"
}

ensure_setup_command() {
    local command_name="$1" language="$2"
    if setup_truthy "$AGENTMILL_SETUP_DRY_RUN"; then
        return 0
    fi
    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi
    repo_log "ERROR: $language setup requires '$command_name' on PATH"
    return 1
}

has_pyproject_field() {
    [[ -f pyproject.toml ]] && rg -q "$1" pyproject.toml && rg -q '^\s*dev\s*=' pyproject.toml
}

has_make_install() {
    [[ -f Makefile || -f makefile || -f GNUmakefile ]] || return 1
    command -v make >/dev/null 2>&1 || return 1
    make -n install >/dev/null 2>&1
}

activate_venv() {
    [[ -d "$REPO_DIR/.venv/bin" ]] && export PATH="$REPO_DIR/.venv/bin:$PATH" && repo_log "Using virtualenv at $REPO_DIR/.venv"
    return 0
}

ensure_venv() {
    if setup_truthy "$AGENTMILL_SETUP_DRY_RUN"; then
        [[ -d .venv ]] || repo_log "Creating virtualenv"
        return 0
    fi
    [[ -d .venv ]] || { repo_log "Creating virtualenv"; python3 -m venv .venv; }
    . .venv/bin/activate
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel
}

install_extra_python_tools() {
    [[ -z "$EXTRA_PYTHON_TOOLS" ]] && return
    if setup_truthy "$AGENTMILL_SETUP_DRY_RUN"; then
        repo_log "Installing extra Python tools: $EXTRA_PYTHON_TOOLS"
        return 0
    fi
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
    if setup_truthy "$AGENTMILL_SETUP_DRY_RUN"; then
        repo_log "Running: $REPO_SETUP_COMMAND"
    else
        eval "$REPO_SETUP_COMMAND"
    fi
    activate_venv; install_extra_python_tools; activate_venv
    return 0 2>/dev/null || exit 0
fi

if setup_language_enabled make && has_make_install; then
    run_setup_command make install
    install_extra_python_tools
    activate_venv
    return 0 2>/dev/null || exit 0
elif setup_language_enabled python && [[ -f pyproject.toml ]]; then
    if [[ -f uv.lock ]] && command -v uv >/dev/null 2>&1; then
        uv_args=(sync --frozen)
        has_pyproject_field '^\[project\.optional-dependencies\]' && uv_args+=(--extra dev)
        has_pyproject_field '^\[dependency-groups\]' && uv_args+=(--group dev)
        run_setup_command uv "${uv_args[@]}"
    elif [[ -f poetry.lock ]]; then
        if ! command -v poetry >/dev/null 2>&1; then
            repo_log "Installing Poetry"
            run_setup_command python3 -m pip install --no-cache-dir poetry
        fi
        if ! setup_truthy "$AGENTMILL_SETUP_DRY_RUN"; then
            poetry config virtualenvs.in-project true 2>/dev/null || true
        fi
        run_setup_command poetry install --no-interaction
    else
        ensure_venv
        if has_pyproject_field '^\[project\.optional-dependencies\]'; then
            run_setup_command python -m pip install --no-cache-dir -e '.[dev]'
        else
            run_setup_command python -m pip install --no-cache-dir -e .
        fi
    fi
elif setup_language_enabled python && [[ -f requirements.txt ]]; then
    ensure_venv
    run_setup_command python -m pip install --no-cache-dir -r requirements.txt
fi

if setup_language_enabled node; then
    if [[ -f package-lock.json ]]; then
        ensure_setup_command npm Node
        run_setup_command npm ci
    elif [[ -f pnpm-lock.yaml ]]; then
        ensure_setup_command pnpm Node
        run_setup_command pnpm install --frozen-lockfile
    elif [[ -f yarn.lock ]]; then
        ensure_setup_command yarn Node
        run_setup_command yarn install --immutable
    fi
fi

if setup_language_enabled go && [[ -f go.mod ]]; then
    ensure_setup_command go Go
    run_setup_command go mod download
fi

if setup_language_enabled rust && [[ -f Cargo.toml && -f Cargo.lock ]]; then
    ensure_setup_command cargo Rust
    run_setup_command cargo fetch
fi

install_extra_python_tools
activate_venv
