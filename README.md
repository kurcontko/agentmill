# AgentMill

A Docker container that runs Claude CLI in a respawning loop. Give it a git repo and a prompt — it clones, works, commits, pushes, and repeats. Tasks go in, code comes out.

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

## How It Works

Each iteration of the loop:

1. `git pull --rebase` to get latest changes
2. Run `claude -p "$(cat PROMPT.md)"` with full autonomy
3. Commit all changes with a timestamp
4. Push to origin (retries on conflict)
5. Log the session to `./logs/`
6. Repeat

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
