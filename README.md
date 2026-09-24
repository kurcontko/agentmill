# AgentMill

**A checked, unattended run of `claude -p` or `codex exec`.** Give AgentMill a
repository, a task, and the checks that define "done". It runs the agent in a
container on a private clone, checks the result in a clean container, and returns
a verdict your scripts and CI can act on, with the patch, a Git bundle and the
full record. It never touches your checkout and never pushes.

```text
$ agentmill run . --agent claude --task "Make the retry tests pass" --check "uv run pytest -q"
Baseline: failed — uv run pytest -q

Session 1/3
  Agent claim: done
  Check: failed — uv run pytest -q        # the agent's "done" is only a claim

Session 2/3
  Agent claim: done
  Check: passed — uv run pytest -q

Result: checked_complete (checked_complete)
Candidate: a0ba02aaeaa2 (checks passed); last passing: a0ba02aaeaa2
Diff: agentmill diff r_3ad7c03c9b33412d
```

*(Abridged output.)*

## Why AgentMill

- **"Done" is verified, not trusted.** Completion requires a valid native result,
  a `done` reply, and every check passing on the captured snapshot, run in a fresh
  container with no agent credentials. Failing checks become feedback for the next
  session, within your session and time budget.
- **Your machine and checkout stay out of it.** The agent works on a private clone
  of a committed revision inside a container. Host Git never runs against the
  agent's `.git`, so hooks or `core.fsmonitor` settings it writes never execute on
  your machine.
- **Every outcome is explicit and recoverable.** Exit codes separate complete,
  incomplete, blocked and failed. The latest and last-passing versions are both
  kept, and crashed or timed-out sessions keep their captured work.
- **Held-out checks.** `--check-dir` gives checks files the agent never receives.

Loops that re-run an agent until it prints a completion promise trust the agent
and run on your host. Sandboxes isolate an agent but don't decide whether the task
is done. AgentMill is the bounded run with an independent verdict in between. It
is one command, not a platform: no scheduler, agent team or daemon.

## Quick start

You need a local Docker daemon and Python 3.11+.

```bash
docker pull ghcr.io/kurcontko/agentmill:0.1.0
export ANTHROPIC_API_KEY=...   # or CLAUDE_CODE_OAUTH_TOKEN; CODEX_API_KEY with --agent codex
uvx agentmill run /path/to/repo --agent claude \
  --task "Fix retry handling without changing the public API." \
  --setup "uv sync --frozen" --check "uv run pytest -q"
```

`pipx install agentmill` or `pip install agentmill` work too. Then inspect and
review the result:

```bash
agentmill list
agentmill show latest
agentmill diff latest > result.patch
git clone --branch agentmill-candidate -- /path/to/result.bundle review   # path printed by the run
```

From a source checkout, `./mill build` builds `agentmill:latest` and `./mill run`
takes the same flags.

## How a run works

1. Clone the committed revision (`HEAD` by default) into private storage. Staged,
   unstaged, untracked and ignored files in your checkout are not included.
2. Run setup and your checks once, as a baseline. A failing baseline can be repaired.
3. Run up to `--max-sessions` native sessions (default 3) within `--max-duration`
   (default 30m). After each session: stop the container, capture the changes, run
   the checks on that snapshot in a fresh container, and feed the results into the
   next session.
4. Stop on `done` with all checks passing, a `blocked` reply, a limit, or a
   failure, then export `result.patch` and `result.bundle`.

| Exit | Meaning |
| --- | --- |
| 0 | Checked completion |
| 1 | Execution, Docker/image, setup/check infrastructure, protocol, capture, or artifact failure |
| 2 | Incomplete at a session count, session timeout, or total time limit |
| 3 | Blocked; the agent needs outside input (its question is in the summary) |
| 130 / 143 | Cancelled by SIGINT / SIGTERM |

A session that crashes, returns no valid reply, or times out keeps its captured
work and seeds the next session; two failures in a row stop the run. Missing
`outcome.json` means unknown or interrupted, never success. The
[runner reference](https://github.com/kurcontko/agentmill/blob/main/docs/runner-reference.md#completion-failures-and-deadlines)
has the exact rules.

## Options you will use

- `--task TEXT` or `--task-file FILE`. Without either, a `MILL.md` in the source is
  used; `./mill init` creates one.
- `--check CMD`, repeatable and required. Exit 126/127 means the command is
  unavailable and stops the run; any other failure is feedback.
- `--setup CMD` runs in every fresh container: the baseline, each session and each
  check. A three-session run can run it seven times, so keep it fast.
- `--check-dir DIR` snapshots held-out checks and mounts them read-only at
  `/checks` in check containers only.
- `--max-sessions`, `--max-duration`, `--setup-timeout`, `--session-timeout`,
  `--check-timeout`. Durations accept seconds or `s`, `m`, `h`.
- `--json` streams AgentMill events as JSONL; `--spec run.json` takes all fields
  from a file.

`agentmill run --help` lists everything. Authentication options, native
configuration files, the JSON event vocabulary, retained records and the
experimental Python API are in the
[runner reference](https://github.com/kurcontko/agentmill/blob/main/docs/runner-reference.md).

## Security

**Containers have open network access, and workers can read the credential you
select.** A prompt-injected agent could send the repository or that credential to
any host. Use a dedicated, low-limit key, and read the
[threat model](https://github.com/kurcontko/agentmill/blob/main/SECURITY.md#threat-model)
before running AgentMill on sensitive code.

Repository tests can be edited by the agent, so passing them is evidence, not
proof. `--check-dir` keeps checks out of the agent's reach, but candidate code
still runs beside them and can read or interfere with them: protected checks raise
confidence; they do not prove correctness.

## Limits

- Requires a local Docker daemon; remote Docker hosts and contexts cannot mount
  local paths. Validated on macOS arm64 with Colima and Linux amd64 in CI.
- Linked worktrees and submodules are not supported as sources.
- No CPU, memory, disk or spend quotas; time and session limits are enforced.
- The Python API and record layouts are experimental.

## Documentation

- [Runner reference](https://github.com/kurcontko/agentmill/blob/main/docs/runner-reference.md)
- [Security policy and threat model](https://github.com/kurcontko/agentmill/blob/main/SECURITY.md)
- [Changelog](https://github.com/kurcontko/agentmill/blob/main/CHANGELOG.md)

MIT licensed.
