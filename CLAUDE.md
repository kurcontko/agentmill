# AgentMill

Docker-based framework for running autonomous AI agents (Claude Code, OpenAI Codex) in respawning loops. Give it a git repo and a prompt — it clones, works, commits, pushes, and repeats.

## Commands

```bash
# Build
docker build -t agentmill .
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker build -t agentmill .  # macOS

# Run
REPO_PATH=/path/to/repo docker compose up agent                    # single agent
REPO_PATH=/path/to/repo docker compose up agent-1 agent-2 agent-3  # multi-agent
REPO_PATH=/path/to/repo docker compose run dashboard                # interactive TUI
REPO_PATH=/path/to/repo docker compose up codex-agent codex-preview # codex + dashboard

# Test
python3 -m unittest tests.test_codex_preview_server
python3 -m unittest tests.test_codex_preview_supervisor
python3 -m unittest tests.test_entrypoint_retry_limit
bash tests/test_entrypoint_push_retry.sh

# Lint
python3 -m py_compile codex_preview_server.py codex_preview_supervisor.py
shellcheck entrypoint.sh entrypoint-tui.sh entrypoint-codex.sh entrypoint-codex-tui.sh
```

## Architecture

```
entrypoint.sh          # Claude headless agent loop
entrypoint-tui.sh      # Claude interactive TUI mode
entrypoint-codex.sh    # Codex headless loop with supervisor
entrypoint-codex-tui.sh # Codex interactive mode
codex_preview_server.py    # SSE file-watcher + HTTP server for dashboard
codex_preview_supervisor.py # Codex process supervisor, writes status.json
setup-repo-env.sh      # Auto-bootstrap repo (uv/poetry/pip detection)
setup-claude-config.sh # Merge host Claude config into container
static/index.html      # Codex preview dashboard (vanilla JS + SSE)
prompts/               # Versioned agent task prompts (PROMPT.md through V7)
```

## Key Patterns

- **Respawning Loop**: Each iteration runs Claude/Codex in a fresh context, commits results, waits, repeats. No context rot.
- **Multi-Agent Sync**: Agents push to their own branches (`agent-1`, `agent-2`, etc.). On conflict: rebase + retry (max 3).
- **Graceful Shutdown**: Entrypoints trap SIGTERM/SIGINT, complete current session, commit WIP, exit.
- **Settings Override**: Agents backup `.claude/settings.local.json`, apply permissive config, restore on exit.
- **Auto-Setup**: Detects `pyproject.toml`/`requirements.txt` and runs appropriate installer (uv > poetry > pip).

## Code Conventions

- Shell scripts use `set -euo pipefail` and `shellcheck` compliance
- Python targets 3.11+, stdlib only (no third-party deps for server/supervisor)
- Entrypoints must handle signals and clean up — never leave orphan processes
- Git operations must have retry limits; never retry infinitely
- All user-facing config via environment variables (see docker-compose.yml)
- Status files go under `logs/` directory hierarchy

## Testing

- Python tests use `unittest` (no pytest dependency in the framework itself)
- Shell tests use plain bash assertions or bats
- Run individual test files, not the full suite, during development
- Smoke test container: `docker run --rm --entrypoint python3 agentmill -c "import codex_preview_server; print('OK')"`

## Important

- Container runs as non-root `agent` user (UID 1000)
- Claude runs with `--dangerously-skip-permissions` inside containers — this is intentional for automation
- Multi-agent services share `REPO_PATH` as upstream but clone into isolated workspaces
- The `static/index.html` dashboard connects via SSE to `codex_preview_server.py` on port 3001
- PROMPT files are mounted at `/prompts/` inside the container

## Web Search

Always prefer using Brightdata MCP (scrape as markdown, search engine) instead of built-in web tools.

When scraping git repos, consider cloning into /tmp and perform file-level ops on it.

## Task Tracking

Active task board: @TASK.md
Progress log: @PROGRESS.md
