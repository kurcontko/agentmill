<p align="center">
  <img src="assets/agentmill.png" alt="AgentMill" width="200">
</p>

<h1 align="center">AgentMill</h1>

<p align="center">
  A Docker container that runs an AI agent CLI in a respawning loop.<br>
  Point it at a repo and a prompt — it works, commits, and repeats.<br>
  <strong>Tasks go in, code comes out.</strong>
</p>

<p align="center">
  <a href="https://github.com/kurcontko/agentmill/actions/workflows/ci.yml"><img src="https://github.com/kurcontko/agentmill/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

The whole framework is one shell script. Each iteration runs `claude -p` or
`codex exec` with fresh context, lets the agent work and commit, then respawns.
The repo — `PROGRESS.md` plus git history — is the only memory, so long runs never
degrade as a context window fills.

What the loop adds around the bare `while true; do claude -p ...` idea:

- **Structured output** — the agent's final message, error status, and event
  stream are parsed, not scraped, for both backends.
- **Stop conditions** — the agent ending its reply with `TASK_COMPLETE`,
  an iteration cap, N no-progress iterations, or N consecutive failures
  (with exponential backoff). A hung CLI is killed by a per-iteration timeout.
- **The ratchet** — set `CHECK_CMD` (e.g. your test suite) and any iteration
  that breaks it is reverted. Kept history is always green; a bad iteration
  costs only tokens.
- **A paper trail** — commit-keyed session logs plus one JSON line per
  iteration in `logs/results.jsonl`.

## Quick start

```bash
./mill init                      # create .env — set auth + REPO_PATH
./mill build                     # build the container image
nano prompts/PROMPT.md           # describe the task (or drop a TASK.md in the repo)
./mill run ~/path/to/repo        # go. Ctrl-C finishes the iteration and exits.
```

Auth in `.env`: `ANTHROPIC_API_KEY` (or `CLAUDE_CODE_OAUTH_TOKEN` from
`claude setup-token`) for claude; `OPENAI_API_KEY` for codex.

## Usage

```bash
mill run [repo] [--agent claude|codex] [--model M] [--iterations N]
         [--prompt FILE] [--dind] [-d]
mill shell [repo]      # interactive shell inside the container
mill logs              # follow the running loop
mill ps | stop | build | init
```

Parallel agents need no framework — one worktree per agent:

```bash
git -C ~/repo worktree add ../repo-b agent-b
./mill run ~/repo -d && ./mill run ../repo-b -d
```

## Configuration

Everything lives in `.env` (see `.env.example`); flags override it.

| Var | Default | Meaning |
|-----|---------|---------|
| `AGENT` | `claude` | `claude` or `codex` |
| `MODEL` | `sonnet` | passed through to the CLI |
| `MAX_ITERATIONS` | `0` | 0 = unbounded |
| `MAX_ERRORS` / `MAX_NOOPS` | `3` / `3` | consecutive failures / no-progress iterations before stopping |
| `ITER_TIMEOUT` | `3600` | seconds per iteration |
| `DONE_PROMISE` | `TASK_COMPLETE` | substring of the final message that stops the loop |
| `SETUP_CMD` | — | runs once before the loop (`uv sync`, `npm ci`, …) |
| `CHECK_CMD` | — | the ratchet: failure reverts the iteration |

## How the agent installs things

The image is deliberately generic — node (for the CLIs), git, jq, python3.
Repo toolchains are the agent's job: it has passwordless `sudo apt-get`
(scoped to apt only) and installs what the work needs, or you make it
deterministic with `SETUP_CMD`. For repos whose work itself needs Docker
(testcontainers, image builds), `--dind` starts a docker:dind sidecar and
points the agent at it — the host docker socket is never mounted.

## Security

The agent runs with permission checks bypassed **inside the container** —
that is the point: the container is the boundary. It gets your API key and
your repo, nothing else. Don't run `loop.sh` on your host.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © Michal Kurc
