# AgentMill

Give `codex exec` or `claude -p` one coding task in a **private repository checkout**.
AgentMill bounds its sessions, captures its changes, runs your checks, and returns
an explicit result. The native CLI owns reasoning and tools; an external caller
owns scheduling, review, approval, and publication.

**Input is a committed revision** (`HEAD` by default). Your staged, unstaged,
untracked, and ignored source files stay untouched and are not included. The
source checkout is never mounted into a worker. Use `--revision` to select another
commit. Linked source worktrees and submodules are currently unsupported.

## Run a task

You need Python 3.11+, Git, and a running local Docker daemon. From this checkout,
build the runtime image locally:

```bash
./mill build
```

Choose setup and checks appropriate to the target repository. For example:

```bash
export CODEX_API_KEY=...
./mill run /path/to/repo --agent codex \
  --task "Fix retry handling without changing the public API." \
  --setup "uv sync --frozen" --check "uv run pytest -q"
```

Or use Claude with its native environment authentication:

```bash
export ANTHROPIC_API_KEY=... # alternatively, CLAUDE_CODE_OAUTH_TOKEN
./mill run /path/to/repo --agent claude \
  --task-file task.md --setup "npm ci" --check "npm test"
```

No wizard or committed configuration file is required. Task inputs are snapshotted
into the run directory. A local `MILL.md` is an optional fallback;
`./mill init [repo]` creates it. At least one `--check` is required; repeat the flag for multiple
commands. Setup defaults to `true`.

Checks normally run the repository's own tests, which the agent can edit. To keep
some checks out of the agent's reach, pass `--check-dir DIR`: AgentMill snapshots
that directory at launch and mounts it read-only at `/checks` in check containers
only. Workers never receive it, though they see the check commands and truncated
check output.

```bash
./mill run /path/to/repo --agent claude --task-file task.md \
  --check "uv run pytest -q" --check "uv run pytest -q /checks/acceptance"
```

Defaults are **three native sessions and 30 minutes total**. One session means
one CLI invocation, not one model turn. `--max-sessions 1` lets a caller own any
subsequent attempt. Use `--max-duration`, `--setup-timeout`, `--session-timeout`,
and `--check-timeout` for tighter bounds; durations accept seconds, `s`, `m`, or `h`.
Phase defaults are 5 minutes for setup/checks and 15 minutes for a native session.

## Inspect the result

The final summary gives the agent's claim or blocking question, stop reason,
latest captured candidate, check status, and actual artifact/log locations.
Use the run ID printed by your run:

```bash
./mill show r_0123456789abcdef
./mill diff r_0123456789abcdef
```

Storage defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/agentmill/runs/`.
`--runs-dir DIR` selects another location outside the source checkout; the printed
inspection commands preserve that location and quote paths. Human summaries go
to stderr. `show --json` returns the outcome; `diff` writes the exported patch to
stdout. `run --json` writes supervisor events to stdout and retains native output
separately. A slow display is detached; the event file and atomic outcome remain
authoritative. Missing `outcome.json` means **unknown/interrupted**, never success.

Review an exported bundle in a clean checkout:

```bash
git clone --branch agentmill-candidate -- "/path/to/result.bundle" "/path/to/new-review"
```

Run the relevant setup and checks in that review checkout. Do not run host Git
against the retained worker workspace's `.git`: the worker could have changed
its configuration or hooks. Importing, applying, merging, and pushing are your
explicit actions. AgentMill does none of them automatically.

## What completion means

`checked_complete` requires a successful native terminal envelope, a validated
`done` claim, and **every configured check passing on the latest captured
candidate**. Required cleanup, capture, and export must also succeed. An earlier
passing revision never establishes completion of newer work.

A failing baseline can be repaired. Ordinary failing checks become feedback for
another bounded session; partial work is retained. A valid `blocked` reply stops
after cleanup and capture, without starting another check environment. Its
changed candidate is unchecked, and its question is preserved. An unchanged
candidate retains its historical check evidence; no new checks run for blocked
work.

A native session that exits with an error or ends without a valid reply still has
its work captured. If sessions remain, that work is checked when it changed and
seeds the next session, which is told the previous one failed. A second
consecutive failure, or one in the final session, stops the run with that failure.
A failed session can never complete a run. Missing executables, Docker or image
problems, and setup/check infrastructure faults stop the run immediately.
Check exits 126/127 mean unavailable commands; other nonzero exits are repair
feedback. There is no infrastructure retry or resume.

| Exit | Meaning |
| --- | --- |
| 0 | Checked completion |
| 1 | Execution, setup/check infrastructure, protocol, capture, or artifact failure |
| 2 | Incomplete at a session count, session timeout, or total time limit |
| 3 | Blocked; outside input required |
| 130 / 143 | Cancelled by SIGINT / SIGTERM |

An execution failure stays primary when capture or export also fails; secondary
diagnostics remain visible. Cancellation retains its signal-derived exit code,
including a signal during export after an in-budget success decision; already
captured artifacts and passing-check evidence remain available.
Capture requires confirmed worker shutdown. If capture fails, artifacts describe
only the **last successfully captured** revision; uncaptured work remains in the
workspace and is identified in diagnostics.

Normal work and the success decision must fit within the run deadline. A single,
nonrenewing finalization allowance of up to 30 seconds permits cleanup, capture,
and export after stopping, or export after an in-budget success decision. If the
run deadline or cancellation interrupts capture, one retry may use that same
finalization allowance, after confirmed worker shutdown. Expired finalization
admits no new subprocess, including Git export. These are supervisor
policies, not strict wall-clock guarantees under kernel/filesystem stalls or a
dead Docker daemon. Cleanup uncertainty is reported, never treated as success.

Host Git operations use the remaining run budget, without a separate 30-second
command cap. Finalization still has the single 30-second allowance. The bundle is
self-contained and includes history; a sufficiently large export can exceed that
allowance. Required export failure prevents checked completion and leaves the
captured candidate and workspace available for inspection.

## Setup and trust

Setup runs in fresh containers: once for the baseline, once per worker session,
and once per non-blocked candidate check. A three-session run can execute setup
seven times. Exported setup variables carry into later commands in that container;
dependencies and environment state are not shared across containers. Checks use
fresh candidate checkouts and receive **no supplied worker credentials**. Check
setup/check commands must not change tracked candidate files; ignored build
products are allowed.

Repository-owned tests may be edited by the agent. Passing them is useful
evidence, not independent proof of every requirement. `--check-dir` keeps the
agent from editing those checks, but candidate code still runs beside them in the
check container and can read or interfere with them: protected checks raise
confidence; they do not prove correctness. Containers have network
access. Filename exclusions are not a secret scanner; logs and retained work
may contain sensitive data. Time/session limits are not universal billing,
CPU, memory, or disk quotas. Read the [isolation and authentication reference](docs/runner-reference.md).

## Installation and further details

The supported workflow uses a source checkout and a locally built image. It does
not require a published package or registry image. Validation covers macOS arm64 with Colima
and Linux amd64 in CI; other OS/architecture combinations are not release-validated.

To install the Python entrypoint into a virtual environment, from this checkout:

```bash
python3 -m venv "$HOME/.venvs/agentmill"
source "$HOME/.venvs/agentmill/bin/activate"
python -m pip install .
agentmill --help
```

The installed `agentmill` provides **run, show, and diff** with standard-library runtime
dependencies and defaults to the published image for its version,
`ghcr.io/kurcontko/agentmill:<version>` (`docker pull` it once). The checkout's
`./mill` launcher runs the same CLI against its locally built `agentmill:latest`
and also provides `build`, `init`, and a `.env` loader. `--image` or
`AGENTMILL_IMAGE` selects another image; runs record its resolved ID.

- [Native config/auth inputs, JSON specs/events, Python API, and retained records](docs/runner-reference.md)

The Python API and internal record details remain experimental. There is no
scheduler, graph engine, agent team, daemon, or shared execution environment.
