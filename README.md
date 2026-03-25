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

### Option A: CLI (recommended)

Run agents directly from your project directory — no `.env` files, no `docker compose`.

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/kurcontko/autonomous-agents/main/install.sh | bash

# Build the image (first time only)
git clone https://github.com/kurcontko/autonomous-agents.git /tmp/agentmill
agentmill build /tmp/agentmill

# Run from your project
cd your-project
export ANTHROPIC_API_KEY=sk-...
agentmill run                                    # headless single agent
agentmill run --agents 3 --model opus            # multi-agent
agentmill watch --ralph --max-iterations 10      # autonomous TUI
agentmill tui                                    # interactive TUI
agentmill stop                                   # stop running agents
```

Per-project config: place `.agentmill.yml` in your repo root:

```yaml
model: sonnet
prompt: ./prompts/task.md
max_iterations: 5
auto_setup: true
```

See `agentmill --help` for all options.

### Option B: Docker Compose

For advanced setups or when you prefer docker compose.

1. **Configure** — copy `.env.example` to `.env`, set `REPO_PATH` and auth
2. **Write your prompt** — edit `prompts/PROMPT.md` with the task
3. **Run** — pick a mode below
4. **Stop** — `docker compose down` (finishes current session, commits WIP, exits cleanly)

```bash
cp .env.example .env   # then edit REPO_PATH and auth
nano prompts/PROMPT.md  # describe the task
```

## Authentication

Set one of these in your environment (CLI) or `.env` (docker compose):

- **API Key** — set `ANTHROPIC_API_KEY`
- **OAuth Token** — run `claude setup-token` on the host, set `CLAUDE_CODE_OAUTH_TOKEN`

## How to Run (Docker Compose)

Pick the mode that fits your workflow:

---

### 1. `headless` — fire and forget

Claude runs in a loop in the background. No UI — output goes to `./logs/`. Restarts automatically on crash. Best for CI, overnight runs, or when you don't need to watch.

```bash
REPO_PATH=/path/to/repo docker compose up headless
```

Loop: pull → run Claude → commit → push → wait → repeat.

---

### 2. `watch` — autonomous TUI, you observe

Full Claude Code TUI in your terminal. Claude works autonomously (all tool calls auto-approved) while you watch file edits, tool calls, and reasoning in real time. You're an observer, not a driver.

```bash
# Single autonomous session, then exit
REPO_PATH=/path/to/repo docker compose run watch

# With Ralph loop — bounded iteration (runs up to N times, then stops)
REPO_PATH=/path/to/repo AUTO_RALPH=true AUTO_RALPH_MAX_ITERATIONS=10 \
  docker compose run watch

# With respawn — restart Claude automatically after each session
REPO_PATH=/path/to/repo RESPAWN=true docker compose run watch
```

---

### 3. `interactive` — you drive

Plain Claude Code TUI. No prompt injected, no automation. You type, Claude responds. Same as running `claude` locally, but inside the container with the repo and tools already set up.

```bash
REPO_PATH=/path/to/repo docker compose run interactive
```

---

### 4. `agent-1`, `agent-2`, `agent-3` — parallel workers

Multiple headless agents on the same repo. Each pushes to its own branch (`agent-1`, `agent-2`, etc.) and rebases on conflict. Assign different prompts for different roles.

```bash
# Two agents, different tasks
PROMPT_FILE_1=/prompts/features.md PROMPT_FILE_2=/prompts/tests.md \
  REPO_PATH=/path/to/repo docker compose up agent-1 agent-2

# Three agents, same branch (rebase on conflict)
AGENT_BRANCH=main REPO_PATH=/path/to/repo docker compose up agent-1 agent-2 agent-3
```

## Configuration

**All modes:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `REPO_PATH` | *(required)* | Absolute path to the repo on your host |
| `ANTHROPIC_API_KEY` | — | API key auth |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | OAuth token auth (alternative to API key) |
| `MODEL` | `sonnet` | Claude model (`sonnet`, `opus`, etc.) |
| `PROMPT_FILE` | `/prompts/PROMPT.md` | Prompt file path inside the container |
| `GIT_USER` | `agentmill` | Git commit author name |
| `GIT_EMAIL` | `agent@agentmill` | Git commit author email |
| `AUTO_SETUP` | `true` | Auto-detect and install repo dependencies on start |
| `REPO_SETUP_COMMAND` | — | Custom bootstrap command (overrides auto-detect) |
| `EXTRA_PYTHON_TOOLS` | — | Additional pip packages to install (e.g. `ruff pytest`) |

**Headless / multi-agent only:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `MAX_ITERATIONS` | `0` (infinite) | Stop after N loop iterations |
| `LOOP_DELAY` | `5` | Seconds between iterations |
| `AUTO_COMMIT` | `wip` | `wip` = commit uncommitted changes as safety net, `on` = always commit, `off` = never |
| `AGENT_BRANCH` | auto | Branch name for multi-agent (default: `agent-$ID`) |
| `PROMPT_FILE_1/2/3` | `PROMPT_FILE` | Per-agent prompt overrides (multi-agent only) |

**Watch / interactive only:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `RESPAWN` | `false` | Restart Claude automatically after each session |
| `LOOP_DELAY` | `5` | Seconds between respawns |
| `SKIP_PROMPT` | `false` | Skip prompt injection (set automatically for `interactive`) |
| `AUTO_RALPH` | `false` | Auto-start Ralph loop for bounded autonomous iteration |
| `AUTO_RALPH_MAX_ITERATIONS` | `10` | Max Ralph loop iterations |
| `AUTO_RALPH_COMPLETION_PROMISE` | `TASK_COMPLETE` | Token that signals task completion to Ralph |

## Auto-Setup

When `AUTO_SETUP=true` (default), AgentMill bootstraps the repo's dev environment:

1. `REPO_SETUP_COMMAND` if set, otherwise:
2. `pyproject.toml` + `uv.lock` → `uv sync --frozen`
3. `pyproject.toml` alone → `pip install .`
4. `requirements.txt` → `pip install -r requirements.txt`

The `.venv/bin` is prepended to `PATH`, so tools like `pytest` and `ruff` are available to Claude.

**Recommendation:** Add a `Makefile` to your upstream repo with an `install` target that sets up the full dev environment. Then point AgentMill at it:

```bash
REPO_SETUP_COMMAND='make install' docker compose up headless
```

This keeps build logic in the repo where it belongs, and any setup — system deps, virtual envs, code generation — just works.

## Volumes

| Host | Container | Purpose |
|------|-----------|---------|
| `./prompts` | `/prompts` | Agent prompt files |
| `./logs` | `/workspace/logs` | Session logs |
| `$REPO_PATH` | `/workspace/repo` or `/workspace/upstream` | Target repository |
| `~/.claude.json` | `/home/agent/.host-claude.json` | Host Claude config (read-only) |
| `~/.claude/settings.json` | `/home/agent/.claude/settings.host.json` | Host settings (read-only) |

## Apple Silicon

If a dependency lacks a Linux `arm64` wheel, build or force x86 emulation:

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose build
```
