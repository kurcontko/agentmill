<p align="center">
  <img src="assets/agentmill.png" alt="AgentMill" width="200">
</p>

<h1 align="center">AgentMill</h1>

<p align="center">
  A Docker container that runs Claude Code in a respawning loop.<br>
  Point it at a repo and a prompt — it works, commits, pushes, and repeats.<br>
  <strong>Tasks go in, code comes out.</strong>
</p>

<p align="center">
  <a href="https://github.com/kurcontko/agentmill/actions/workflows/ci.yml"><img src="https://github.com/kurcontko/agentmill/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/kurcontko/agentmill/actions/workflows/security-scan.yml"><img src="https://github.com/kurcontko/agentmill/actions/workflows/security-scan.yml/badge.svg" alt="Security Scan"></a>
  <a href="https://github.com/kurcontko/agentmill/actions/workflows/codeql.yml"><img src="https://github.com/kurcontko/agentmill/actions/workflows/codeql.yml/badge.svg" alt="CodeQL"></a>
  <a href="https://sonarcloud.io/summary/overall?id=kurcontko_agentmill"><img src="https://sonarcloud.io/api/project_badges/measure?project=kurcontko_agentmill&metric=security_rating" alt="Security Rating"></a>
  <a href="https://sonarcloud.io/summary/overall?id=kurcontko_agentmill"><img src="https://sonarcloud.io/api/project_badges/measure?project=kurcontko_agentmill&metric=reliability_rating" alt="Reliability Rating"></a>
  <a href="https://github.com/ossf/scorecard"><img src="https://api.scorecard.dev/projects/github.com/kurcontko/agentmill/badge" alt="OpenSSF Scorecard"></a>
</p>

## Quick Start

```bash
# 1. Configure
cp .env.example .env
# Edit .env — set REPO_PATH and auth (API key or OAuth token)

# 2. Write your prompt
# Edit prompts/PROMPT.md with your task

# 3. Run
REPO_PATH=/path/to/repo docker compose up agent

# 4. Or watch it work in the TUI
REPO_PATH=/path/to/repo docker compose run dashboard

# 5. Stop gracefully (finishes current session, commits WIP, exits)
docker compose down
```

## Authentication

Set one of these in your `.env`:

- **API Key**: set `ANTHROPIC_API_KEY`
- **OAuth Token**: run `claude setup-token` on the host, then set `CLAUDE_CODE_OAUTH_TOKEN`

## Services

| Service | Mode | Use case |
|---------|------|----------|
| `agent` | Headless loop | Background automation — logs to `./logs/` |
| `agent-1`, `agent-2`, `agent-3` | Multi-agent | Each agent gets its own branch, syncs via rebase |
| `dashboard` | TUI + auto-ralph | Watch Claude work in real time (autonomous) |
| `tui` | TUI manual | Interactive Claude session, no automation |

```bash
# Single agent
REPO_PATH=/path/to/repo docker compose up agent

# Multi-agent with per-agent prompts
PROMPT_FILE_1=/prompts/core.md PROMPT_FILE_2=/prompts/tests.md \
  REPO_PATH=/path/to/repo docker compose up agent-1 agent-2

# Dashboard with Ralph loop
REPO_PATH=/path/to/repo AUTO_RALPH=true docker compose run dashboard

# Plain interactive TUI
REPO_PATH=/path/to/repo docker compose run tui
```

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `REPO_PATH` | *(required)* | Absolute path to the repo on your host |
| `ANTHROPIC_API_KEY` | — | API key auth |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | OAuth token auth (alternative to API key) |
| `MODEL` | `sonnet` | Claude model to use |
| `MAX_ITERATIONS` | `0` (infinite) | Stop after N loop iterations |
| `LOOP_DELAY` | `5` | Seconds between iterations |
| `PROMPT_FILE` | `/prompts/PROMPT.md` | Prompt file path inside the container |
| `GIT_USER` | `agentmill` | Git commit author name |
| `GIT_EMAIL` | `agent@agentmill` | Git commit author email |
| `AUTO_SETUP` | `true` | Auto-detect and install repo dependencies on start |
| `REPO_SETUP_COMMAND` | — | Custom bootstrap command (overrides auto-detect) |
| `EXTRA_PYTHON_TOOLS` | — | Additional pip packages to install (e.g. `ruff pytest`) |
| `AGENT_BRANCH` | auto | Branch name for multi-agent services (default: `agent-$ID`) |
| `AUTO_RALPH` | `false` | Auto-start Ralph loop in dashboard |
| `AUTO_RALPH_MAX_ITERATIONS` | `10` | Ralph loop iteration cap |
| `RESPAWN` | `false` | Restart TUI after Claude exits |

**Multi-agent only:** `PROMPT_FILE_1`, `PROMPT_FILE_2`, `PROMPT_FILE_3` override prompts per agent.

## Auto-Setup

When `AUTO_SETUP=true` (default), AgentMill bootstraps the repo's dev environment:

1. `REPO_SETUP_COMMAND` if set, otherwise:
2. `pyproject.toml` + `uv.lock` → `uv sync --frozen`
3. `pyproject.toml` alone → `pip install .`
4. `requirements.txt` → `pip install -r requirements.txt`

The `.venv/bin` is prepended to `PATH`, so tools like `pytest` and `ruff` are available to Claude.

## Volumes

| Host | Container | Purpose |
|------|-----------|---------|
| `./prompts` | `/prompts` | Agent prompt files |
| `./logs` | `/workspace/logs` | Session logs |
| `$REPO_PATH` | `/workspace/repo` or `/workspace/upstream` | Target repository |
| `~/.claude.json` | `/home/agent/.host-claude.json` | Host Claude config (read-only) |
| `~/.claude/settings.json` | `/home/agent/.claude/settings.host.json` | Host settings (read-only) |

## Apple Silicon

If a dependency lacks a Linux `arm64` wheel, force x86 emulation:

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose build
```
