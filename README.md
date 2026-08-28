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
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

## Why AgentMill

There are plenty of autonomous loop runners now. AgentMill differs on four things:

- **Container-first, not sandbox-as-a-flag.** The loop is *defined* by `docker-compose.yml` — isolation isn't an opt-in mode bolted onto a host script. Nothing touches your machine's Claude config, `PATH`, or working tree.
- **Real multi-agent, not multi-window.** `mill multi ~/repo 3` starts three headless agents on the same upstream, each in its own workspace, each pushing to its own branch (`agent-1`, `agent-2`, …), rebasing and retrying on conflict with a hard retry cap. No tmux, no supervision, no worktree juggling.
- **Shared memory between agents.** Agents read and write `memory/` as flock-guarded append-only markdown, so what agent 2 learns at iteration 40 is available to agent 1 at iteration 41. Inspect it with `mill memory`.
- **Fresh context every iteration.** Each pass runs Claude from a clean context, commits, and respawns — long runs don't degrade as the window fills.

Every iteration appends to `logs/results.tsv` (agent, files changed, commits, status), so a 200-iteration overnight run is auditable after the fact with `mill history`.

**Use something else if** you want to supervise parallel agents from a GUI and review each diff by hand — that's a different job, well served by the worktree-and-dashboard tools. AgentMill is for work you want to leave running.

## Quick Start

1. **Configure** — copy `.env.example` to `.env`, set `REPO_PATH` and auth
2. **Write your prompt** — edit `prompts/PROMPT.md` with the task
3. **Run** — pick a mode below
4. **Stop** — `docker compose down` (finishes current session, commits WIP, exits cleanly)

```bash
cp .env.example .env   # then edit REPO_PATH and auth
nano prompts/PROMPT.md  # describe the task
```

## Authentication

Set one of these in `.env`:

- **API Key** — set `ANTHROPIC_API_KEY`
- **OAuth Token** — run `claude setup-token` on the host, set `CLAUDE_CODE_OAUTH_TOKEN`

For GitHub Actions PR review with Claude Code and DeepSeek, see [`docs/claude-code-github-actions.md`](docs/claude-code-github-actions.md).

## How to Run

Pick the mode that fits your workflow:

---

### 1. `headless` — fire and forget

Claude runs in a loop in the background. No UI — output goes to `./logs/`. Restarts automatically on crash. Best for CI, overnight runs, or when you don't need to watch.

```bash
REPO_PATH=/path/to/repo docker compose up headless

# Use REPO_PATH from .env, or pass /path/to/repo to override it
./mill run --iterations 3
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

---

### 5. `harness` — Manage-Execute-Audit (LongHorizon-Harness)

AgentMill is not the agent here. [LongHorizon-Harness](https://github.com/AMAP-ML/LongHorizon-Harness) drives `claude`/`codex` itself in a manager → executor → auditor loop; AgentMill supplies the sandbox, the mounted repo, and a dashboard port. Requires a checkout of the harness source at `LH_HARNESS_PATH` (default `../LongHorizon-Harness`).

```bash
# One-shot run against the repo
./mill mea ~/repo --task "port the CLI to argparse and cover it with tests"

# Long task from a file, bounded rounds, no end-of-round dashboard gate
./mill mea ~/repo --task-file TASK.md --rounds 8 --unattended

# Or drop into a shell with lhrun/lhdash helpers wired up
./mill mea ~/repo --shell
```

The run pauses at each end-of-round human gate on the dashboard (`http://localhost:8080/`) unless `--unattended` is passed. See [`docs/longhorizon-mea.md`](docs/longhorizon-mea.md) for the integration assessment.

## Configuration

**All modes:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `REPO_PATH` | *(required unless passed)* | Absolute path to the repo on your host; `mill run/watch/multi/shell [repo]` can override it |
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

**Harness (`mill mea`) only:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `LH_HARNESS_PATH` | `../LongHorizon-Harness` | Path to the LongHorizon-Harness source (mounted read-only, editable-installed) |
| `DASHBOARD_PORT` | `8080` | Published harness dashboard port |
| `OPENAI_API_KEY` | — | Only needed for `--agent codex` / mixed-backend runs |
| `ANTHROPIC_BASE_URL` | — | Point the Claude CLI at a different Anthropic-compatible endpoint (all modes) |

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

## Security

Claude runs with `--dangerously-skip-permissions` inside the container. That is intentional — the container *is* the boundary, which is why AgentMill is container-first. Do not run the entrypoints directly on your host.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © Michal Kurc
