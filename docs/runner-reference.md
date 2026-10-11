# Runner reference

See the [README](../README.md) for the quick start and the ordinary run/inspect workflow.
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
  ledger.json               # per-check results for each checked candidate
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
    best.patch              # only when the latest candidate lost a check
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
and `agentmill-best` refs; its `HEAD` identifies the latest candidate, so it can be the source of a new
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

## Acceptance ledger

Each check has an ID: `check-1`, `check-2`, ... for `--check` commands, or the `id`
given in a job file. After every complete check set, the supervisor records each
check's status (`passed`, `failed`, `error`, or `not_run`) for that candidate in
`ledger.json`, beside the run's other supervisor-owned records. The worker never
receives the file. Its prompt shows a rendered copy: each check's latest status,
how many checks the best candidate passes, and which checks regressed.

With `--check-dir`, a check whose command reads `/checks` is held out: the worker
cannot run it. The prompt shows such a check's ID, status and description, but not
its command, and says that its result reaches the next session.

The best candidate is the latest one whose passing set includes every check the
previous best passed. The baseline is the first best. A candidate that passes a
check the best one failed, but loses another, is a regression rather than
progress.

A check in a job file may add `progress`, a pattern with one group that captures a
number in the check's standard output; the last match counts and higher is better:

```toml
[[checks]]
id = "speed"
run = "python bench.py"            # prints "speedup: 3154.2x", fails below 5000
progress = 'speedup: ([\d.]+)x'
```

The ledger records the number for each candidate (`values` in each history entry
and in the summary, `best_values` for the best candidate), and the prompt shows the
latest and the highest seen. When two candidates pass the same checks, the newer
one becomes the best only if none of the best candidate's numbers fell or went
missing. Use it for a check that stays red while its result improves: a benchmark
threshold, or `'(\d+) passed'` for one check that runs a whole suite.
 `outcome.json` reports `best_candidate_sha` and a `ledger` summary
(`total`, `best_passed`, `latest`, `regressed`, `first_passed_session`, `values`,
`best_values`). When the
best and latest candidates differ, export adds `best.patch` and the
`agentmill-best` ref.

`--stall-sessions N` (or `stall_sessions` in a job file) stops the run with
`stalled` (exit 2) after N consecutive sessions in which the best passing set did
not grow and no `progress` number rose above its highest value so far. A session that fails without a valid reply counts as one of them. The
final session ends with `session_limit` instead. Stall detection is off by default.

A candidate whose tree is identical to the base revision cannot complete a run,
even when its reply is `done` and every check passes: those checks already passed
before the agent started. The next session is told why. If the final session makes
the same claim, the run stops with `unchanged_candidate` (exit 2). When every check
passes at baseline, the outcome also notes that the checks cannot show the task
was done.

## Verifying a revision

`agentmill verify [source] --revision REV --check CMD ...` prepares the committed
revision exactly like a run's input and checks it once, in fresh check
containers with no agent credentials and with `--check-dir` if given. No worker
container starts. It writes a normal run directory with `mode: "verify"` in the
outcome. Exit 0 (`checks_passed`) means every check passed. Exit 2
(`checks_failed`) means at least one check failed; the ledger names which. Exit 1
means verification could not complete. `--spec` reads only `source`, `revision`,
`checks`, `check_dir`, `setup`, `image` and the duration fields from a job file.
To verify a run's result, pass its `result.bundle` with `--revision
agentmill-candidate` or `agentmill-best`.

## Completion, failures and deadlines

`checked_complete` requires a successful native terminal envelope, a validated
`done` claim, and every configured check passing on the latest captured
candidate, which must differ from the base revision's tree. Required cleanup, capture, and export must also succeed. An earlier
passing revision never establishes completion of newer work.

A failing baseline can be repaired. Ordinary failing checks become feedback for
another bounded session; partial work is retained. A valid `blocked` reply stops
after cleanup and capture, without starting another check environment. Its
changed candidate is unchecked, and its question is preserved. An unchanged
candidate retains its historical check evidence; no new checks run for blocked
work.

A native session that exits with an error, ends without a valid reply, or reaches
`--session-timeout` still has its work captured. If sessions remain, that work is
checked when it changed and seeds the next session, which is told why the previous
one ended. A second consecutive failure, or one in the final session, stops the run
with that failure (exit 2 for a timeout, otherwise 1). A failed session can never
complete a run. Missing executables, Docker or image problems, and setup/check
infrastructure faults stop the run immediately. Check exits 126/127 mean
unavailable commands; other nonzero exits are repair feedback. There is no
infrastructure retry or resume.

An execution failure stays primary when capture or export also fails; secondary
diagnostics remain visible. Cancellation retains its signal-derived exit code,
including a signal during export after an in-budget success decision; already
captured artifacts and passing-check evidence remain available. Capture requires
confirmed worker shutdown. If capture fails, artifacts describe only the last
successfully captured revision; uncaptured work remains in the workspace and is
identified in diagnostics.

Normal work and the success decision must fit within the run deadline. A single,
nonrenewing finalization allowance of up to 30 seconds permits cleanup, capture,
and export after stopping, or export after an in-budget success decision. If the
run deadline or cancellation interrupts capture, one retry may use that same
finalization allowance, after confirmed worker shutdown. Expired finalization
admits no new subprocess, including Git export. These are supervisor policies,
not strict wall-clock guarantees under kernel/filesystem stalls or a dead Docker
daemon. Cleanup uncertainty is reported, never treated as success.

Host Git operations use the remaining run budget, without a separate 30-second
command cap. Finalization still has the single 30-second allowance. The bundle is
self-contained and includes history; a sufficiently large export can exceed that
allowance. Required export failure prevents checked completion and leaves the
captured candidate and workspace available for inspection.

## Inspecting runs

Storage defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/agentmill/runs/`.
`--runs-dir DIR` selects another location outside the source checkout; the printed
inspection commands preserve that location and quote paths. Human summaries go
to stderr. `list` prints one run per line to stdout (`--json` for objects);
`show --json` returns the outcome; `diff` writes the exported patch to stdout.
`show` and `diff` accept `latest`. `run --json` writes supervisor events to stdout
and retains native output separately. A slow display is detached; the event file
and atomic outcome remain authoritative. Missing `outcome.json` means
unknown/interrupted, never success. Runs are never deleted automatically; remove a
run's directory to reclaim its space.

Review an exported bundle in a clean checkout, then run the relevant setup and
checks there:

```bash
git clone --branch agentmill-candidate -- "/path/to/result.bundle" "/path/to/new-review"
```

Do not run host Git against the retained worker workspace's `.git`: the worker
could have changed its configuration or hooks. Importing, applying, merging, and
pushing are your explicit actions. AgentMill does none of them automatically.

Setup runs in fresh containers: once for the baseline, once per worker session,
and once per non-blocked candidate check, so a three-session run can execute
setup seven times. Exported setup variables carry into later commands in that
container; dependencies and environment state are not shared across containers.
Setup and check commands must not change tracked candidate files; ignored build
products are allowed.

## Machine and Python interfaces

```bash
./mill run --spec run.json --json
```

`--spec` accepts exactly the `RunSpec` fields, as TOML (a `.toml` file) or JSON;
explicit CLI flags override it. Durations are numbers of seconds or strings such
as `"45m"` and `"8h"`. Each check is a command string or a table with `run` and
optional `id` and `describe`. Paths are relative to the calling working
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
`seq`, and a UTC timestamp. The vocabulary is `run.started` (or `verify.started`), `session.started`,
`session.progress` (about once a minute: `elapsed_seconds` and `native_events`),
`session.finished`, `candidate.captured`, `check.finished`, and `run.finished`.
Session/check events identify the session; baseline checks use session 0.
`check.finished` also carries the check's `check_id`.
`outcome.json` is authoritative, even if the consumer missed the final event.
It identifies the latest captured and last passing revisions independently.
`candidate_check_status` describes the latest check attempt on the captured
candidate (`unchecked`, `passed`, `failed`, or `error`); a partial check set cannot
establish a pass. A blocked reply leaves a changed capture unchecked. An unchanged
capture retains the same revision's historical check evidence; non-blocked replies
still trigger fresh checks, even for an unchanged revision. Run completion requires the full
completion rules above, including cleanup and export.
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
