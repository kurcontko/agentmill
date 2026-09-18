# AgentMill

Give a native coding agent a task, a private workspace, and a bounded opportunity
to work. AgentMill captures its changes, runs your checks, and returns an honest
result.

AgentMill runs `codex exec` or `claude -p` in Docker. The native CLI owns reasoning,
tools, context management, and native subagents. AgentMill owns the run lifecycle.
There is no scheduler, reviewer agent, daemon, database, or task graph in the core.

## Quick start

Requires Python 3.11+, Git, and a running local Docker daemon on Linux or macOS.
From this checkout:

```bash
./mill build
export CODEX_API_KEY=... # or select Claude's native environment authentication
./mill run /path/to/repo \
  --agent codex \
  --task "Fix retry handling without changing the public API." \
  --setup "uv sync --frozen" \
  --check "uv run pytest -q"
```

Or:

```bash
./mill run /path/to/repo \
  --agent claude \
  --task-file task.md \
  --setup "npm ci" \
  --check "npm test" \
  --check "npm run lint" \
  --max-sessions 5 \
  --max-duration 30m

./mill show r_0123456789abcdef
./mill diff r_0123456789abcdef
```

`--task` and `--task-file` need no repository configuration or committed mission
file. If neither is supplied, a local `MILL.md` is read as an optional task input.
The task is snapshotted separately into the run directory. `mill init [repo]`
creates that optional file; no wizard or commit is required.

The source defaults to `REPO_PATH`, then the current directory. **Only the selected
committed revision is included** (`--revision HEAD` by default). Staged, unstaged,
untracked, and ignored source files remain untouched and are not copied. The
source is never mounted into a container. Source inputs may also be a Git URL or
an exported bundle. Linked source worktrees and submodules are currently rejected.

The shell launcher can load environment defaults from the installation's `.env`.
`CHECK_CMD` and `AGENTMILL_IMAGE` are supported shortcuts. Setup defaults to `true`:
choose an explicit setup command for the project. A custom image can supply
additional tools with `--image your-image:tag`; its resolved image ID is pinned
for the run. The packaged image includes Python, uv, Git, Node, Claude and Codex.

## What a result means

Each session is one fresh native CLI invocation. After it stops, AgentMill
captures eligible changes, including new files. Native commits are optional.
Checks run in a fresh checkout and fresh container prepared from that exact
candidate, with the same setup command and **no supplied agent credentials**.
Setup runs again for every check environment and every native session. Use
explicit commands such as `uv run ...`, or activate tools in the setup command;
exported shell variables are carried into that container's subsequent commands.

A failing baseline is recorded and can be repaired. Ordinary failing checks
become bounded feedback for the next session. Failed candidates stay in the
workspace. AgentMill never resets useful changes to the last passing revision.

`checked_complete` means exactly:

1. The native process and its terminal protocol completed successfully.
2. Its validated structured reply claimed `done`.
3. Every configured check passed on the captured candidate.

At least one check is required. This is evidence about your checks, not proof
that every requirement is satisfied. Repository-owned tests can be modified by
the agent. Independent acceptance tests and review belong above this runner.

The outcome distinguishes `latest_candidate_sha` from
`last_passing_candidate_sha`. The latter may be the baseline or an earlier
candidate, and does not itself imply task completion. A blocked agent returns
its question. Missing executables, setup failures, malformed terminal replies,
and check infrastructure failures stop the run. Check exit codes 126/127 are
classified as unavailable commands; other nonzero exits are repair feedback.

Checks may create build products, but changing tracked candidate files makes the
check invalid. Setup must not change tracked source in check environments.
Generated dependencies and build outputs should be ignored by the repository.

| Exit | Meaning |
| --- | --- |
| 0 | Checked completion |
| 1 | Runtime, setup, check infrastructure, protocol, or artifact failure |
| 2 | Incomplete at a session count, session timeout, or total time limit |
| 3 | Blocked; outside input required |
| 130 / 143 | Cancelled by SIGINT / SIGTERM |

## Bounds and cancellation

Defaults are **3 sessions and 30 minutes total**. Setup and each check have a
5-minute timeout; each native session has a 15-minute timeout. Override them with
`--max-sessions`, `--max-duration`, `--setup-timeout`, `--session-timeout`, and
`--check-timeout`. Durations accept seconds, `s`, `m`, or `h`. Each operation is
also bounded by the remaining total time. The launch summary prints the limits.

Cancellation stops the Docker container, waits a short grace period, and forcibly
removes it if necessary. Capture only proceeds after the worker is confirmed
stopped. A bounded finalization allowance of up to 30 seconds is used for cleanup,
preservation, and export after a limit or cancellation. If capture or export
fails, the outcome reports the failure and the private workspace remains for
inspection. An abruptly killed supervisor may have no final outcome; `show`
reports unknown, never success. There is no automatic resume or crash recovery.

## Authentication and isolation

By default, only these selected variables are forwarded to the native session:

- Codex: `CODEX_API_KEY`.
- Claude: `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`.

Repeat `--credential-env NAME` to explicitly replace that selection, for example
to use native provider configuration or a custom endpoint. Names, never values,
are stored in the spec. Native invocation flags and unmodified native output are
retained. Usage telemetry identifies its native source; missing usage stays
unknown and Claude cost fields are estimates. There is no universal dollar cap.

`--agent-config FILE` selects one native configuration file: Codex TOML or Claude
settings JSON. Codex additionally supports `--profile NAME` with an explicitly
selected profile TOML file, and `--auth-file /path/to/auth.json` for native account
authentication. Only those selected files are mounted read-only into the worker;
Codex receives an ephemeral writable copy. Refreshed account tokens are not
written back to the source auth file. No entire home directory is copied.
Selected config/auth paths must be regular files; the runner validates them
before preparing the source or running setup and baseline checks.

Containers run as the invoking user's numeric UID/GID, drop capabilities, and
use `no-new-privileges`. They have network access. The worker sees only its private
checkout, read-only session inputs, temporary scratch space, and selected native
configuration/authentication. The supervisor's snapshot repository, outcome, and
logs are not mounted. Checks use different containers with no native auth/config
mounts or forwarded agent credentials. Custom images must not bake in credentials.

**Docker is the execution isolation boundary.** Codex explicitly uses
`--sandbox danger-full-access` and noninteractive approval policy inside that
container: nested Codex namespace sandboxing is incompatible with the default
Docker restrictions tested here. Claude uses `dontAsk` with coding-tool approvals.
No Docker socket is mounted into either worker or check containers.

## Captures and artifacts

Runs live under `${XDG_STATE_HOME:-$HOME/.local/state}/agentmill/runs/`, or
`--runs-dir DIR`. Storage must be outside the source checkout.

```text
r_<id>/
  spec.json                 # frozen commands, limits, resolved revision
  input.json                # source and pinned base
  task.txt
  events.jsonl
  outcome.json              # atomic, final once written
  workspace/                # retained working files, including unfinished work
  snapshots.git/            # supervisor-owned candidate history
  baseline/                 # setup and baseline check evidence
  checks/                   # retained scratch checkouts
  sessions/0001/
    prompt.txt
    inputs/
    command.json
    native.jsonl
    native.stderr.log
    reply.json
    telemetry.json
    checks.json
    worker/                 # worker setup evidence
  operations/               # Git and Docker diagnostics
  artifacts/
    result.patch
    result.bundle
```

Capture preserves tracked-file edits/deletions, regular new files, executable
bits, symlinks, and binary content. It ignores repository-ignored new files and
[the explicit untracked credential exclusions](agentmill/workspace.py).
Worker-controlled Git hooks, config, index, and commits are not authoritative;
the supervisor captures bytes using its own Git repository and index. New nested
Git repositories are rejected. Existing tracked sensitive files remain tracked;
filename exclusions are not a secret scanner. Inspect artifacts before sharing.
Logs and retained workspaces can also contain sensitive data.

The patch is the base-to-latest-candidate diff. The self-contained bundle includes
`agentmill-base`, `agentmill-candidate`, and, when available, `agentmill-passing`
refs; its `HEAD` identifies the latest candidate, so it can be the source of a new
run. Importing, merging, committing to your branch, and pushing are explicit
user or ADE actions. For example, inspect a result in another directory:

```bash
git clone -b agentmill-candidate /path/to/result.bundle /tmp/review-result
```

## Machine and Python interfaces

```bash
./mill run --spec run.json --json
```

`--spec` accepts exactly the `RunSpec` fields; explicit CLI flags override it.
JSON durations are numbers of seconds. Paths are relative to the calling working
directory. Example:

```json
{
  "source": "/projects/payments",
  "revision": "HEAD",
  "task": "Fix retry handling without changing the public API.",
  "agent": "codex",
  "setup": "uv sync --frozen",
  "checks": ["uv run pytest -q"],
  "max_sessions": 3,
  "max_duration": 1800
}
```

JSON mode writes only AgentMill JSONL events to stdout. Diagnostics go to stderr;
native output stays in session files. Events carry `schema_version`, `run_id`,
`seq`, and a UTC timestamp. The vocabulary is `run.started`, `session.started`,
`session.finished`, `candidate.captured`, `check.finished`, and `run.finished`.
Session/check events identify the session; baseline checks use session 0.
`outcome.json` is authoritative, even if the consumer missed the final event.
The CLI detaches a closed or stalled output stream after a bounded write attempt
(100 ms per message). A detached JSON stream may end with a partial line. Read
`events.jsonl` for the complete event sequence; slow consumers do not stop a run.

The Python API is experimental. Its `on_event` callback runs synchronously and
must return promptly; callers own any callback queuing or backpressure handling.
The CLI's bounded output forwarding does not apply to arbitrary Python callbacks.

```python
from agentmill import RunSpec, run

outcome = run(RunSpec(
    source="/projects/payments",
    revision="HEAD",
    task="Fix retry handling without changing the public API.",
    agent="codex",
    setup="uv sync --frozen",
    checks=("uv run pytest -q",),
), on_event=print)
```

The Python package has no runtime dependencies and can be installed with
`pip install .`; its `mill` entrypoint provides `run`, `show`, and `diff`. Image
building and optional `init`/`legacy` conveniences live in the checkout's `./mill`.

## Development

```bash
python3 -m unittest discover -s tests -p 'test_basic_loop.py'
python3 -m unittest discover -s tests -p 'test_adapters.py'
python3 -m unittest discover -s tests -p 'test_workspace.py'
shellcheck mill
# Real Docker lifecycle, deterministic native fixtures, no provider billing:
AGENTMILL_SMOKE_IMAGE=agentmill:latest python3 tests/smoke_basic_image.py
```

The packaged versions are pinned in `Dockerfile`; each run records the actual
native CLI version and resolved image identity. Adapter changes require terminal
protocol fixtures and the shared lifecycle contract tests.

## Legacy users

The former Compose runtime remains under `mill legacy`. It is not used by the
checked runner. See [legacy documentation](docs/legacy.md). The previous
`--iterations` spelling aliases `--max-sessions`; replace `--timeout` with explicit
phase timeouts or `--max-duration`. Automatic setup detection is legacy behavior;
the new runner uses your explicit `--setup` command.
