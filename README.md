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
| `OPENAI_API_KEY` | — | API key for Codex services |
| `REPO_URL` | — | Git repo URL to clone |
| `MODEL` | `sonnet` | Claude model to use |
| `CODEX_MODEL` | — | Optional Codex model override |
| `MAX_ITERATIONS` | `0` (infinite) | Stop after N iterations |
| `LOOP_DELAY` | `5` | Seconds between iterations |
| `GIT_USER` | `agentmill` | Git commit author name |
| `GIT_EMAIL` | `agent@agentmill` | Git commit author email |
| `PROMPT_FILE` | `/prompts/PROMPT.md` | Path to prompt file inside container |
| `CODEX_APPROVAL_MODE` | `suggest` | Codex approval mode: `suggest`, `auto-edit`, or `full-auto` |
| `AUTO_SETUP` | `true` | Auto-bootstrap repo-local dev environment on container start |
| `REPO_SETUP_COMMAND` | — | Custom repo bootstrap command, run in repo root before Claude starts |
| `EXTRA_PYTHON_TOOLS` | — | Extra Python CLI tools to install into repo `.venv` (for example `ruff pytest`) |
| `AUTO_RALPH_MAX_ITERATIONS` | `10` | Ralph loop cap for dashboard auto-start |
| `AUTO_RALPH_COMPLETION_PROMISE` | `TASK_COMPLETE` | Exact `<promise>...</promise>` token Ralph watches for |
| `CODEX_COMPLETION_PROMISE` | — | Optional string to detect in Codex final messages for preview/supervision |
| `PREVIEW_APP_URL` | — | Optional app URL to embed in the Codex preview page |
| `CODEX_PREVIEW_PORT` | `3001` | Host port for the Codex preview UI |

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

Dashboard with Ralph auto-start and bounded looping:

```bash
REPO_PATH=/path/to/repo \
EXTRA_PYTHON_TOOLS='ruff' \
AUTO_RALPH=true \
AUTO_RALPH_MAX_ITERATIONS=10 \
AUTO_RALPH_COMPLETION_PROMISE=TASK_COMPLETE \
docker-compose run --rm \
  -e PROMPT_FILE=/prompts/PROMPT_V5_WORK.md \
  dashboard
```

## Engines

AgentMill now supports two separate interactive engines:

- `dashboard`: Claude Code TUI, with optional Ralph Loop automation
- `codex-dashboard`: OpenAI Codex interactive terminal session
- `codex-agent`: OpenAI Codex headless loop using `codex exec --full-auto`
- `codex-preview`: Browser UI for live Codex agent status

Keep them separate. Claude services use `.claude` state, plugins, and Ralph-specific behavior. Codex services use `OPENAI_API_KEY` or mounted `~/.codex` state and do not rely on Claude plugins or trust automation.

### Run Codex Dashboard

API-key auth:

```bash
REPO_PATH=/path/to/repo \
OPENAI_API_KEY=your_key_here \
docker-compose run --rm codex-dashboard
```

With repo-local setup helpers and a prompt file available in the container:

```bash
REPO_PATH=/path/to/repo \
OPENAI_API_KEY=your_key_here \
EXTRA_PYTHON_TOOLS='ruff pytest' \
PROMPT_FILE=/prompts/PROMPT_V5_WORK.md \
CODEX_APPROVAL_MODE=auto-edit \
docker-compose run --rm codex-dashboard
```

If you previously authenticated on the host with `codex --login`, the service also mounts `~/.codex` to reuse that state.

Current limitation:

- `codex-dashboard` now passes the prompt file contents as the initial interactive prompt.

### Run Codex Agent

```bash
REPO_PATH=/path/to/repo \
OPENAI_API_KEY=your_key_here \
PROMPT_FILE=/prompts/PROMPT_V5_WORK.md \
MAX_ITERATIONS=3 \
docker-compose up codex-agent
```

Notes:

- `codex-agent` runs `codex exec --full-auto --json` under a small supervisor.
- The prompt is read from `PROMPT_FILE` via stdin.
- Raw event logs are written under `logs/codex-preview/agent-*/runs/`.

### Run Codex Preview

Start the headless agent and browser preview together:

```bash
REPO_PATH=/path/to/repo \
OPENAI_API_KEY=your_key_here \
PROMPT_FILE=/prompts/PROMPT_V5_WORK.md \
MAX_ITERATIONS=3 \
docker-compose up codex-agent codex-preview
```

Then open:

```text
http://localhost:3001
```

Optional app embed inside the preview UI:

```bash
REPO_PATH=/path/to/repo \
OPENAI_API_KEY=your_key_here \
PROMPT_FILE=/prompts/PROMPT_V5_WORK.md \
PREVIEW_APP_URL=http://host.docker.internal:4173 \
docker-compose up codex-agent codex-preview
```

If your target app is running locally, the preview page will embed that URL in an iframe next to the agent status.

### Simple Codex Agent UI

Raw JSONL is useful for automation, but it is the wrong operator surface. The preview service sits on top of the event stream and publishes a small derived state instead.

Recommended shape:

- Run `codex exec --json` inside the `codex-agent` supervisor.
- Parse the JSONL stream and derive operator state.
- Write a few human-friendly files on every event:
  - `logs/codex-preview/agent-1/status.json`
  - `logs/codex-preview/agent-1/summary.md`
  - `logs/codex-preview/agent-1/last-message.txt`
  - `logs/codex-preview/agent-1/runs/<timestamp>.jsonl`

Suggested `status.json` fields:

```json
{
  "state": "running",
  "iteration": 3,
  "max_iterations": 10,
  "started_at": "2026-03-09T10:15:00Z",
  "updated_at": "2026-03-09T10:18:12Z",
  "last_event": "turn.completed",
  "current_task": "Run tests and fix the auth flow regression",
  "last_message": "Implemented the fix and reran the targeted tests.",
  "last_exit_code": 0,
  "files_changed": 4,
  "commit": "abc1234",
  "completion_promise_seen": false,
  "stall_count": 0
}
```

That gives you three low-effort UI options without reading JSONL directly:

1. Terminal status view

   Use `watch -n 2 cat logs/codex-preview/agent-1/summary.md` or a tiny shell script that prints `status.json` in a readable format.

2. Static browser page

   Use `codex-preview`, which serves a minimal page that polls the derived status files every 2-5 seconds and renders:
   - current state
   - iteration progress
   - current task
   - last agent message
   - changed files count
   - latest commit

3. Log-friendly sidecar

   Append one human-readable line per major event to `logs/codex-agent.status.log`, for example:

   ```text
   [10:18:12] iter=3 state=running event=turn.completed files=4 commit=abc1234
   ```

Current implementation choices:

- Keep the UI read-only.
- Do not render raw event payloads by default.
- Treat JSONL as the transport layer and `status.json` as the operator API.
- Stop at a single-agent view first; add multi-agent panels only after the single-agent loop is stable.

This is the Codex equivalent of a Ralph monitor: not a native hook-based loop inside the agent, but a thin supervisor that converts machine events into a small, inspectable status surface.

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
