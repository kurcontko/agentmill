<p align="center">
  <img src="assets/agentmill.png" alt="AgentMill" width="200">
</p>

<h1 align="center">AgentMill</h1>

<p align="center">
  A Docker container that runs Claude CLI in a respawning loop.<br>
  Give it a git repo and a prompt — it clones, works, commits, pushes, and repeats.<br>
  <strong>Tasks go in, code comes out.</strong>
</p>

## Quick Start

```bash
# 1. Configure
cp .env.example .env
# Edit .env — set auth (see below) and other options

# 2. Write your prompt
# Edit prompts/PROMPT.md with your task

# 3. Run with a remote repo
REPO_URL=https://github.com/you/your-repo.git docker compose up

# 4. OR run with a local repo
# Place/clone your repo in ./repo, then:
docker compose up

# 5. Monitor
tail -f logs/agent.log

# 6. Stop gracefully
docker compose down
```

## Authentication

Two options — use whichever you prefer:

**Option A: API Key**
Set `ANTHROPIC_API_KEY` in your `.env` file. That's it.

**Option B: Claude Subscription (OAuth)**
Log in on your host machine first, then the container picks up your session automatically:
```bash
claude login
# The docker-compose.yml already mounts ~/.claude into the container
```
Leave `ANTHROPIC_API_KEY` blank in `.env` when using this method.

## TUI Dashboard Mode

Want to **see** what the agent is doing? Run the dashboard service — it forwards Claude Code's full interactive TUI to your terminal. Same UI as running `claude` locally, but autonomous (all tool calls auto-approved).

```bash
# Launch with TUI — you see the full Claude Code interface
docker compose run dashboard

# Same env vars apply:
MODEL=opus MAX_ITERATIONS=3 docker compose run dashboard
```

The TUI is purely a **monitoring window** — Claude works autonomously while you watch tool calls, file edits, and reasoning in real time. You can scroll, review output, or just let it run.

For headless/background operation, use the default `agent` service instead:
```bash
docker compose up       # headless, logs to ./logs/
```

## How It Works

Each iteration of the loop:

1. `git pull --rebase` to get latest changes
2. Run Claude with full autonomy (`--dangerously-skip-permissions`)
3. Commit all changes with a timestamp
4. Push to origin (retries on conflict)
5. Log the session to `./logs/`
6. Repeat

**Headless mode** (`agent` service): uses `-p` pipe mode, no UI, output goes to logs.
**TUI mode** (`dashboard` service): forwards Claude's interactive terminal UI to your terminal.

The container restarts automatically on crash (`restart: unless-stopped`).

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `ANTHROPIC_API_KEY` | — | API key (or use subscription auth via `~/.claude` mount) |
| `REPO_URL` | — | Git repo URL to clone |
| `MODEL` | `sonnet` | Claude model to use |
| `MAX_ITERATIONS` | `0` (infinite) | Stop after N iterations |
| `LOOP_DELAY` | `5` | Seconds between iterations |
| `GIT_USER` | `agentmill` | Git commit author name |
| `GIT_EMAIL` | `agent@agentmill` | Git commit author email |
| `PROMPT_FILE` | `/prompts/PROMPT.md` | Path to prompt file inside container |
| `AUTO_SETUP` | `true` | Auto-bootstrap repo-local dev environment on container start |
| `REPO_SETUP_COMMAND` | — | Custom repo bootstrap command, run in repo root before Claude starts |
| `EXTRA_PYTHON_TOOLS` | — | Extra Python CLI tools to install into repo `.venv` (for example `ruff pytest`) |

## Repo Setup Contract

For consistency across repositories, AgentMill now uses this setup order when a container starts:

1. If `REPO_SETUP_COMMAND` is set, run that in the repo root.
2. Else if `pyproject.toml` and `uv.lock` exist, run `uv sync --frozen` and include the `dev` extra and `dev` dependency group when present.
3. Else if `pyproject.toml` exists, create `.venv` and install the project with `pip`, including `.[dev]` when present.
4. Else if `requirements.txt` exists, create `.venv` and install it.

After setup, AgentMill prepends `./.venv/bin` to `PATH`, so repo-local tools like `pytest`, `ruff`, and project CLIs are available to Claude.

Recommended standard for repos:

- Python repos: declare dev tools in `pyproject.toml` and commit `uv.lock`
- Non-standard repos: set `REPO_SETUP_COMMAND`
- Missing one-off Python tools: use `EXTRA_PYTHON_TOOLS`

Example:

```bash
REPO_PATH=/path/to/repo \
REPO_SETUP_COMMAND='uv sync --frozen --extra dev --group dev' \
EXTRA_PYTHON_TOOLS='ruff pytest' \
docker-compose run --rm dashboard
```

## Apple Silicon

On a MacBook with Colima, containers usually run as Linux `arm64`, not macOS ARM. That is fine for most Python tooling, including `pytest`, `uv`, and `ruff`, as long as Linux `arm64` wheels exist.

If a dependency has no Linux `arm64` wheel or fails to build natively, force x86_64 emulation for that run:

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker-compose build dashboard
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker-compose run --rm dashboard
```

Use that only when needed because it is slower than native `arm64`.

## Volumes

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `./prompts` | `/prompts` | Agent prompt file |
| `./logs` | `/workspace/logs` | Session logs |
| `./repo` | `/upstream` | Optional: local repo to clone from |
| `~/.claude` | `/root/.claude` | Optional: subscription auth from `claude login` |

## Private Repos

For private repos over HTTPS, embed credentials in the URL:

```bash
REPO_URL=https://TOKEN@github.com/you/private-repo.git
```

For SSH, mount your SSH key:

```yaml
# Add to docker-compose.yml under volumes:
- ~/.ssh:/root/.ssh:ro
```

## Stopping

`docker compose down` sends SIGTERM. AgentMill finishes its current Claude session, commits any pending changes, then exits cleanly.
