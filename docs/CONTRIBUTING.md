# Contributing

## Development Setup

```bash
git clone https://github.com/kurcontko/agentmill.git
cd agentmill
cp .env.example .env
# Edit .env with your auth credentials
```

## Project Structure

```
├── Dockerfile              Container image definition
├── docker-compose.yml      Service definitions (agent, multi-agent, dashboard)
├── entrypoint.sh           Headless agent loop (main entrypoint)
├── entrypoint-tui.sh       TUI dashboard entrypoint
├── setup-claude-config.sh  Merges host Claude config into container (uses jq)
├── setup-repo-env.sh       Auto-bootstraps repo dev environment (Python/uv/pip)
├── auto-trust.exp          Expect script for trust dialog automation
├── prompts/                Prompt templates
├── tests/                  BATS test suite
└── docs/                   Documentation
```

## Code Style

- **Shell**: Bash 5+ with `set -euo pipefail`. Follow ShellCheck recommendations.
- **JSON manipulation**: Use `jq`, not inline Python.
- **Logging**: Use the `log()` function. Prefix with level: `log "WARN: message"`, `log "ERROR: message"`.
- **Error handling**: Never silently swallow errors with `|| true` or `2>/dev/null` alone. Always log a warning.

## Testing

Tests use [BATS](https://github.com/bats-core/bats-core) (Bash Automated Testing System).

```bash
# Install BATS
brew install bats-core  # macOS
# or: apt-get install bats  # Debian/Ubuntu

# Run all tests
bats tests/

# Run a specific test file
bats tests/test_entrypoint_functions.bats
```

### Writing Tests

- Place test files in `tests/` with the naming convention `test_*.bats`
- Use `setup()` and `teardown()` for test fixtures
- Create temp directories for isolation — never modify the real repo
- Source individual functions from scripts rather than running the full entrypoint

## Adding a New Workspace Mode

1. Add detection logic in `setup_workspace()` in `entrypoint.sh`
2. Document the mode in `docs/ARCHITECTURE.md`
3. Add a service definition in `docker-compose.yml`
4. Add BATS tests covering the new mode

## CI Pipeline

The CI runs on every push and PR:
- **ShellCheck**: Lints all shell scripts
- **Hadolint**: Lints the Dockerfile
- **Trivy**: Security scanning (filesystem + Docker image)
- **SonarCloud**: Code quality and security analysis
- **CodeQL**: GitHub native SAST

All checks must pass before merging.

## Pull Requests

1. Create a feature branch from `main`
2. Make your changes
3. Ensure ShellCheck passes: `shellcheck *.sh`
4. Run tests: `bats tests/`
5. Open a PR with a clear description of what and why
