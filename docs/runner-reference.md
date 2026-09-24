# Runner reference

See the [quick start](../README.md) for the ordinary run/inspect workflow.
These interfaces support the same single-run contract; the Python API and internal
record layouts are experimental.

## Launch inputs and defaults

`agentmill run --help` lists the supported flags. Source defaults to `REPO_PATH`, then
the current directory, and may be a regular checkout, Git URL, or exported bundle.
The selected revision is resolved once and retained. Uncommitted source changes
are never imported. Explicit flags override fields in `--spec`.

Host Git commands use the enclosing run or finalization deadline, rather than a
fixed per-command timeout. Initial source cloning remains independent of the
source object store. Worker and check checkouts copy objects from the private
snapshot store with `--local --no-hardlinks`: no repacking, shared object
alternates, or writable hardlinks to the supervisor's store.

Before cloning, the runner checks that the source directory is a checkout root
and that Docker can inspect the selected image. A missing image stops with
`image_unavailable` (`docker pull` the published image, or `./mill build` in a
checkout); an unreachable daemon stops
with `docker_unavailable`. Other failed Docker or Git operations report
`runtime_failed` with the tool's last error output and the operation log path.
Docker Desktop and Colima only share some host directories with their VM; keep
`--runs-dir` under a shared directory such as your home directory. AgentMill
bind-mounts local paths, so it needs a local daemon: a remote `DOCKER_HOST` or
Docker context (for example over SSH) fails with the same unshared-path error.

The checkout's `./mill` launcher can load environment defaults from its own `.env`;
the installed Python entrypoint does not. Both accept `CHECK_CMD` and
`AGENTMILL_IMAGE` from their environment. Choose `--setup` explicitly for the
project; it defaults to `true`. Use commands such as `uv run ...`, or export/activate
tools during setup; exported shell variables carry into that container's later
commands. Preparation is repeated in fresh containers, not shared with checks.

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
With `--check-dir`, check containers also receive the launch-time snapshot of that
directory (`verifier/` in the run directory) read-only at `/checks`; worker
containers never do. Candidate code runs in the same check container and can read
those files.

**Docker is the execution isolation boundary.** Codex explicitly uses
`--sandbox danger-full-access` and noninteractive approval policy inside that
container: nested Codex namespace sandboxing is incompatible with the default
Docker restrictions tested here. Claude uses `dontAsk` with coding-tool approvals
and `--strict-mcp-config`, so MCP servers declared by the repository are not
started. The repository's own `.claude/` settings, hooks and `CLAUDE.md` still
apply inside the worker, with the same container privileges as the agent's
shell tool. Codex runs with a fresh `CODEX_HOME`; only an explicitly selected
`--agent-config` or `--auth-file` is copied into it.
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
  verifier/                 # --check-dir snapshot, mounted only into checks
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
[the explicit untracked credential exclusions](../agentmill/workspace.py).
Worker-controlled Git hooks, config, index, and commits are not authoritative;
the supervisor captures bytes using its own Git repository and index. New nested
Git repositories are rejected. Existing tracked sensitive files remain tracked;
filename exclusions are not a secret scanner. Inspect artifacts before sharing.
Logs and retained workspaces can also contain sensitive data.

The patch is the base-to-last-successfully-captured-candidate diff. If capture
failed, it does not contain uncaptured workspace changes; the outcome reports
that failure. Partial exports are not advertised as completed artifacts.
The self-contained bundle includes
`agentmill-base`, `agentmill-candidate`, and, when available, `agentmill-passing`
refs; its `HEAD` identifies the latest candidate, so it can be the source of a new
run. It carries reachable history rather than requiring an external base commit.
Bundle creation shares the single 30-second finalization allowance with cleanup
and capture. Large repositories can exceed it; required export failure is reported
as non-success, with the captured candidate and workspace retained. There is no
claim-only or patch-only fallback that silently converts that failure to success.
Importing, merging, committing to your branch, and pushing are explicit
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
`session.progress` (about once a minute: `elapsed_seconds` and `native_events`),
`session.finished`, `candidate.captured`, `check.finished`, and `run.finished`.
Session/check events identify the session; baseline checks use session 0.
`outcome.json` is authoritative, even if the consumer missed the final event.
It identifies the latest captured and last passing revisions independently.
`candidate_check_status` describes the latest check attempt on the captured
candidate (`unchecked`, `passed`, `failed`, or `error`); a partial check set cannot
establish a pass. A blocked reply leaves a changed capture unchecked. An unchanged
capture retains the same revision's historical check evidence; non-blocked replies
still trigger fresh checks, even for an unchanged revision. Run completion requires the full
completion contract in the README, including cleanup and export.
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
`pip install .`; its `agentmill` entrypoint provides `run`, `show`, and `diff`. Image
building and optional `init` convenience live in the checkout's `./mill` launcher.
