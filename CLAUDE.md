# AgentMill

Docker-based framework for running autonomous AI agents (Claude Code) in respawning loops. Give it a git repo and a prompt — it clones, works, commits, pushes, and repeats.

## Commands

```bash
# CLI (preferred)
./mill run ~/myrepo                        # headless loop
./mill run ~/myrepo --model opus --iterations 5
./mill watch ~/myrepo --ralph              # autonomous TUI with Ralph Loop
./mill multi ~/myrepo 3                    # 3 parallel agents
./mill shell ~/myrepo                      # interactive Claude session
./mill status                              # show agent iteration status
./mill history                             # show iteration results log
./mill memory                              # list memory topics
./mill memory decisions                    # read a memory topic
./mill memory --search "pattern"           # search across memory
./mill memory decisions --clear            # clear a memory topic
./mill diff                                # show recent changes across iterations
./mill logs 1                              # tail agent-1 logs
./mill build                               # build container image
./mill stop                                # stop all services

# Direct docker compose (still works)
REPO_PATH=/path/to/repo docker compose up headless
REPO_PATH=/path/to/repo docker compose up agent-1 agent-2 agent-3
REPO_PATH=/path/to/repo docker compose run watch
REPO_PATH=/path/to/repo docker compose run interactive

# Test
python3 -m unittest tests.test_entrypoint_retry_limit
bash tests/test_entrypoint_push_retry.sh

# Lint
shellcheck entrypoint.sh entrypoint-tui.sh mill
```

## Architecture

```
mill                   # CLI wrapper — run/watch/multi/shell/status/memory/history
entrypoint.sh          # Claude headless agent loop
entrypoint-tui.sh      # Claude interactive TUI mode
entrypoint-common.sh   # Shared functions: logging, auth, git, settings, sentinel, memory
setup-repo-env.sh      # Auto-bootstrap repo (uv/poetry/pip detection)
setup-claude-config.sh # Merge host Claude config into container
prompts/               # Agent task prompts (PROMPT.md, PROMPT_LITE.md, PROMPT_MEMORY.md)
memory/                # Shared markdown memory (flock-guarded, multi-agent safe)
logs/results.tsv       # Iteration results log (Karpathy autoresearch pattern)
```

## Key Patterns

- **Respawning Loop**: Each iteration runs Claude in a fresh context, commits results, waits, repeats. No context rot. This is a productionized Ralph loop (Huntley 2025); see `docs/LONG_RUNNING.md` for pedigree and Anthropic's Mar 2026 post endorsing the pattern.
- **Multi-Agent Sync**: Agents push to their own branches (`agent-1`, `agent-2`, etc.). On conflict: rebase + retry (max 3).
- **Graceful Shutdown**: Entrypoints trap SIGTERM/SIGINT, complete current session, commit WIP, exit.
- **Settings Override**: Agents backup `.claude/settings.local.json`, apply permissive config, restore on exit.
- **Auto-Setup**: Detects `pyproject.toml`/`requirements.txt` and runs appropriate installer (uv > poetry > pip).
- **Shared Memory**: Agents write to `memory/` via flock-guarded append-only markdown files. Read freely, write safely.
- **Iteration Log**: Every iteration appends to `logs/results.tsv` (agent, files changed, commits, status). View with `mill history`.

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
