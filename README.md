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

- **Structured output** — the agent answers against a schema
  (`{done, summary, blocked}`), and each session's cost, turns, tokens, and
  error status are parsed from the event stream, not scraped. Both backends.
- **Stop conditions** — a verified completion claim, an iteration cap, a spend
  cap, N no-progress (or `blocked`) iterations, N consecutive failures with
  exponential backoff, or `mill stop --soft`. A hung CLI gets TERM at the
  per-iteration timeout and SIGKILL after a bounded grace period.
- **The ratchet** — set `CHECK_CMD` (e.g. your test suite) and any iteration
  that breaks it is reverted, including one the CLI crashed or timed out
  halfway through; `METRIC_CMD` adds a second gate, keeping an iteration only
  if a benchmark number strictly improves. Kept history is always green. Because
  a revert discards the worktree, the loop refuses to start on a dirty repo.
- **Verified completion** — "done" is a claim, not a stop: `DONE_CMD` (or a
  green `CHECK_CMD`) must pass, and with `EVALUATOR=true` a read-only reviewer
  session judges the whole run's diff before the loop ends.
- **A paper trail** — per-iteration `.summary` digests beside commit-keyed
  event logs, one JSON line per iteration in `results.jsonl`, a `metrics.tsv`
  ledger in metric mode, and `mill logs --results` to tabulate it.

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
like everything else. The body is handed to the agent verbatim every iteration
— edit it to steer a running loop. Optional frontmatter carries per-repo
settings (lowercase env var names; secrets stay out):

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

- [ ] `pytest -q` green, no `argparse` import left.
```

`prompts/PROMPT.md` is the framework prompt — how to work (one task per
session, `PROGRESS.md`, the failed-approaches log). It rarely needs editing;
`--prompt FILE` swaps it.

`PROGRESS.md` is the agent's memory across respawns. When it does not exist
yet, the first session is an initializer: it turns the mission into a checklist,
makes sure a verifier exists, commits, and exits without doing feature work.

## Usage

```bash
mill [-C DIR] run   [--agent claude|codex] [--model M] [--iterations N]
                    [--prompt FILE] [--dind] [-d]
mill [-C DIR] shell [--dind]   # interactive shell inside the container
mill [-C DIR] logs             # follow the loop, else the last summaries
mill [-C DIR] logs --raw       # tail the last iteration's full event log
mill [-C DIR] logs --results   # results.jsonl as a table
mill [-C DIR] steer "..."      # one-shot note for the next session
mill [-C DIR] stop             # stop this checkout's container
mill [-C DIR] stop --soft      # finish the current iteration, then stop
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

## Completion contract

The agent's final message is a JSON object; `done: true` is a claim, not a stop.
Before the loop honours it, `DONE_CMD` must pass (or, if unset, `CHECK_CMD` must
have been green on this iteration), and with `EVALUATOR=true` a fresh read-only
session (`prompts/EVALUATOR.md`) reviews the run's commits and diffstat against
the mission, re-runs the verifier, and returns `PASS` or `NEEDS_WORK`.

A rejection is appended to `PROGRESS.md`, committed, and the loop keeps going,
so the next session sees why its predecessor's claim did not stick. CLIs that
return no structured reply fall back to `DONE_PROMISE` in the final message.

## Steering a running loop

`MILL.md` is re-read every iteration: editing the mission steers the loop
without restarting it. For everything else there is a git-excluded drop-box in
the checkout's `.mill/`.

```bash
mill steer "stop refactoring, get the failing e2e test green first"
mill steer               # print the pending note
mill stop --soft         # finish the current iteration, then stop
```

A steer is one-shot: the next session gets it in an `<operator-steer>` block and
the loop deletes the file as it reads it. `mill stop --soft` is the polite
brake — no session is cut off mid-work.

## Metric mode

`METRIC_CMD` turns the loop into a benchmark optimizer: its last stdout line is
the score, measured once on the clean tree for a baseline and again after every
iteration. Only a strict improvement is kept.

```markdown
---
check_cmd: pytest -q
metric_cmd: python3 bench.py     # last line: 0.8123
metric_direction: max            # min for loss/latency, max for accuracy
---
```

The current best rides in every session's preamble, and each iteration appends a
row to `logs/<container>/metrics.tsv` (`iter sha metric best status summary`). A
worse score — or output that is not a number — is reverted.

## Cost

`MAX_BUDGET_USD` / `MAX_TURNS` bound one session (claude only);
`MAX_TOTAL_BUDGET_USD` stops the loop once the run's summed spend reaches it.
All three are claude only — codex reports no cost, so cap a codex run with
`MAX_ITERATIONS` instead.

```bash
MAX_BUDGET_USD=2 MAX_TOTAL_BUDGET_USD=50 MAX_TURNS=80 mill run -d
mill logs --results
# ITER  STATUS    COMMITS  COST      TURNS  TIME
# 1     kept      2        $1.24     37     412s
```

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
| `MIN_TURNS` | `2` | a session ending in fewer turns without touching the repo counts as an error, not a no-op (0 = off) |
| `MAX_TURNS` / `MAX_BUDGET_USD` | `0` / — | claude only: per-session turn and spend caps (0 / empty = none) |
| `MAX_TOTAL_BUDGET_USD` | — | claude only: loop-wide spend cap; the loop stops when the summed cost reaches it |
| `DONE_PROMISE` | `TASK_COMPLETE` | fallback stop signal when the CLI returned no structured reply |
| `SETUP_CMD` | — | runs once before the loop (`uv sync`, `npm ci`, …) |
| `CHECK_CMD` | — | the ratchet: failure reverts the iteration |
| `DONE_CMD` | — | completion verifier; empty = require `CHECK_CMD` green instead |
| `EVALUATOR` | `false` | run a read-only reviewer session before honouring a done claim |
| `METRIC_CMD` / `METRIC_DIRECTION` | — / `min` | metric ratchet: last stdout line is the score; `min` or `max` is better |
| `CLAUDE_BARE` | `false` | claude only: `--bare`, skipping `CLAUDE.md` and hook discovery |

## How the agent installs things

The image is deliberately generic — node (for the CLIs), git, jq, python3, and
a docker client for `--dind`. Repo toolchains are the agent's job: it has passwordless `sudo apt-get` (scoped
to apt only) and installs what the work needs, or you make it deterministic with
`SETUP_CMD`. For repos whose work itself needs Docker (testcontainers, image
builds), `--dind` starts a docker:dind sidecar, waits for its TCP endpoint, then
points the image's docker client at it — the host socket is never mounted.

## Security

The agent runs with permission checks bypassed **inside the container** — that
is the point: the container is the boundary. It gets your API key and your repo,
nothing else. API-key values are passed through the Docker client's environment,
not its process arguments. Don't run `loop.sh` on your host.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © Michal Kurc
