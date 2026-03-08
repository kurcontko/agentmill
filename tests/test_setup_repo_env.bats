#!/usr/bin/env bats
# Tests for setup-repo-env.sh

setup() {
    export TEST_DIR="$(mktemp -d)"
    export REPO_DIR="$TEST_DIR/repo"
    mkdir -p "$REPO_DIR"
    cd "$REPO_DIR"
    git init
    git config user.email "test@test.com"
    git config user.name "test"
    touch README.md
    git add . && git commit -m "init"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "auto setup disabled skips everything" {
    export AUTO_SETUP=false
    run bash /setup-repo-env.sh "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auto setup disabled"* ]]
}

@test "custom setup command runs via bash -c" {
    export REPO_SETUP_COMMAND="echo custom-setup-ran"
    run bash /setup-repo-env.sh "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"custom-setup-ran"* ]]
}

@test "requirements.txt triggers pip install" {
    echo "requests==2.31.0" > "$REPO_DIR/requirements.txt"
    export AUTO_SETUP=true
    export REPO_SETUP_COMMAND=""
    run bash /setup-repo-env.sh "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing requirements.txt"* ]]
}

@test "no project files produces no errors" {
    export AUTO_SETUP=true
    export REPO_SETUP_COMMAND=""
    run bash /setup-repo-env.sh "$REPO_DIR"
    [ "$status" -eq 0 ]
}

@test "activate_venv adds venv to PATH" {
    python3 -m venv "$REPO_DIR/.venv"
    export AUTO_SETUP=true
    export REPO_SETUP_COMMAND=""
    # Source instead of run to check PATH
    . /setup-repo-env.sh "$REPO_DIR"
    [[ "$PATH" == *"$REPO_DIR/.venv/bin"* ]]
}

@test "extra python tools get installed" {
    export AUTO_SETUP=true
    export REPO_SETUP_COMMAND=""
    export EXTRA_PYTHON_TOOLS="cowsay"
    run bash /setup-repo-env.sh "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing extra Python tools"* ]]
}
