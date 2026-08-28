<p align="center">
  <img src="assets/agentmill.png" alt="AgentMill" width="200">
</p>

<h1 align="center">AgentMill</h1>

<p align="center">
  A Docker container that runs an AI agent CLI in a respawning loop.<br>
  Drop a MILL.md in a repo — it works, commits, and repeats.<br>
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
  (with exponential backoff). A hung CLI gets TERM at the per-iteration
  timeout and SIGKILL after a bounded grace period.
- **The ratchet** — set `CHECK_CMD` (e.g. your test suite) and any iteration
  that breaks it is reverted, including one the CLI crashed or timed out
  halfway through. Kept history is always green; a bad iteration costs only
  tokens. Because a revert discards the worktree, the loop refuses to start on
  a repo with uncommitted changes.
- **A paper trail** — commit-keyed session logs plus one JSON line per
  iteration in `logs/<container>/results.jsonl`, one directory per checkout.

## Quick start

```bash
git clone https://github.com/kurcontko/agentmill && cd agentmill
./mill build                     # build the container image
ln -s "$PWD/mill" ~/.local/bin/mill   # or any directory on your PATH

cd ~/path/to/repo
mill init                        # writes MILL.md here + ~/.config/agentmill/env once
$EDITOR ~/.config/agentmill/env  # set your auth key
$EDITOR MILL.md                  # describe the mission
mill run                         # go. Ctrl-C stops the agent, commits, exits.
```

Like `git`, `mill` acts on the repository containing the current directory;
`mill -C DIR …` targets another one.

Auth in `~/.config/agentmill/env`: `ANTHROPIC_API_KEY` (or
`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`) for claude;
`OPENAI_API_KEY` for codex.

## MILL.md

The mission lives with the code, so it is reviewed, versioned, and branched
like everything else. The body is handed to the agent verbatim every
iteration — edit it to steer a running loop. An optional frontmatter block
carries per-repo settings (lowercase env var names; secrets stay out):

```markdown
---
check_cmd: pytest -q
setup_cmd: uv sync
max_iterations: 20
---
# Mission

Port the CLI from argparse to click. Behaviour must stay identical;
the test suite is the spec.

## Definition of done

- `pytest -q` green, no `argparse` import left.
```

`prompts/PROMPT.md` is the framework prompt — how to work (one task per
session, `PROGRESS.md`, the failed-approaches log). It rarely needs editing;
`--prompt FILE` swaps it.

## Usage

```bash
mill [-C DIR] run   [--agent claude|codex] [--model M] [--iterations N]
                    [--prompt FILE] [--dind] [-d]
mill [-C DIR] shell [--dind]   # interactive shell inside the container
mill [-C DIR] logs             # follow this checkout's loop
mill [-C DIR] stop             # stop this checkout's container
mill stop --all                # stop every agentmill container
mill [-C DIR] init | ps | build
```

Parallel agents need no framework — one worktree per agent:

```bash
git worktree add ../repo-b agent-b
mill run -d && mill -C ../repo-b run -d
mill -C ../repo-b stop           # stops only that one
```

On a Linux host, `mill build` builds the image with your uid/gid so the
container can write the bind-mounted repo (Docker Desktop maps ownership
itself).

## Configuration

Precedence: flags > environment > `MILL.md` frontmatter >
`~/.config/agentmill/env` (`KEY=value`, see `.env.example`; override the
path with `AGENTMILL_CONFIG`). Values may be quoted; an unquoted value ends
at an inline ` # comment`. Every key below works in either file.

| Var | Default | Meaning |
|-----|---------|---------|
| `AGENT` | `claude` | `claude` or `codex` |
| `MODEL` | — | passed through to the CLI; empty = the CLI's own default |
| `FALLBACK_MODEL` | — | claude only: `--fallback-model` when `MODEL` is overloaded |
| `MAX_ITERATIONS` | `0` | 0 = unbounded |
| `MAX_ERRORS` / `MAX_NOOPS` | `3` / `3` | consecutive failures / no-progress iterations before stopping (0 = unbounded) |
| `ERROR_BACKOFF` / `MAX_BACKOFF` | `30` / `900` | seconds: `ERROR_BACKOFF * 2^n` after n failures, capped |
| `ITER_TIMEOUT` | `3600` | seconds per iteration |
| `SHUTDOWN_GRACE` | `30` | seconds before a timed-out or signalled agent is killed |
| `DIND_READY_TIMEOUT` | `30` | seconds to wait for the `--dind` TCP endpoint |
| `DONE_PROMISE` | `TASK_COMPLETE` | substring of the final message that stops the loop |
| `SETUP_CMD` | — | runs once before the loop (`uv sync`, `npm ci`, …) |
| `CHECK_CMD` | — | the ratchet: failure reverts the iteration |

## How the agent installs things

The image is deliberately generic — node (for the CLIs), git, jq, python3, and
a docker client for `--dind`.
Repo toolchains are the agent's job: it has passwordless `sudo apt-get`
(scoped to apt only) and installs what the work needs, or you make it
deterministic with `SETUP_CMD`. For repos whose work itself needs Docker
(testcontainers, image builds), `--dind` starts a docker:dind sidecar and
waits for its TCP endpoint before starting the agent. It then points the
image's docker client at it — the host docker socket is never mounted.

## Security

The agent runs with permission checks bypassed **inside the container** —
that is the point: the container is the boundary. It gets your API key and
your repo, nothing else. API-key values are passed through the Docker client's
environment, not its process arguments. Don't run `loop.sh` on your host.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © Michal Kurc
