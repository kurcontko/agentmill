# AgentMill

Docker-based framework for running autonomous AI agents (Claude Code) in respawning loops. Give it a git repo and a prompt — it clones, works, commits, pushes, and repeats.

## Commands

```bash
# Build
docker build -t agentmill .
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker build -t agentmill .  # macOS

# Run
REPO_PATH=/path/to/repo docker compose up agent                    # single agent
REPO_PATH=/path/to/repo docker compose up agent-1 agent-2 agent-3  # multi-agent
REPO_PATH=/path/to/repo docker compose run dashboard                # interactive TUI

# Test
python3 -m unittest tests.test_entrypoint_retry_limit
bash tests/test_entrypoint_push_retry.sh

# Lint
shellcheck entrypoint.sh entrypoint-tui.sh
```

## Architecture

```
entrypoint.sh          # Claude headless agent loop
entrypoint-tui.sh      # Claude interactive TUI mode
setup-repo-env.sh      # Auto-bootstrap repo (uv/poetry/pip detection)
setup-claude-config.sh # Merge host Claude config into container
prompts/               # Versioned agent task prompts (PROMPT.md through V7)
```

## Key Patterns

- **Respawning Loop**: Each iteration runs Claude in a fresh context, commits results, waits, repeats. No context rot.
- **Multi-Agent Sync**: Agents push to their own branches (`agent-1`, `agent-2`, etc.). On conflict: rebase + retry (max 3).
- **Graceful Shutdown**: Entrypoints trap SIGTERM/SIGINT, complete current session, commit WIP, exit.
- **Settings Override**: Agents backup `.claude/settings.local.json`, apply permissive config, restore on exit.
- **Auto-Setup**: Detects `pyproject.toml`/`requirements.txt` and runs appropriate installer (uv > poetry > pip).

## Code Conventions

- Shell scripts use `set -euo pipefail` and `shellcheck` compliance
- Python targets 3.11+, stdlib only (no third-party deps)
- Entrypoints must handle signals and clean up — never leave orphan processes
- Git operations must have retry limits; never retry infinitely
- All user-facing config via environment variables (see docker-compose.yml)
- Status files go under `logs/` directory hierarchy

## Testing

- Python tests use `unittest` (no pytest dependency in the framework itself)
- Shell tests use plain bash assertions or bats
- Run individual test files, not the full suite, during development

## Important

- Container runs as non-root `agent` user (UID 1000)
- Claude runs with `--dangerously-skip-permissions` inside containers — this is intentional for automation
- Multi-agent services share `REPO_PATH` as upstream but clone into isolated workspaces
- PROMPT files are mounted at `/prompts/` inside the container

## Web Search

Always prefer using Brightdata MCP (scrape as markdown, search engine) instead of built-in web tools.

When scraping git repos, consider cloning into /tmp and perform file-level ops on it.
