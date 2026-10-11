"""One bounded repair loop, and a verify-only run. Native flags stay in adapters."""

from contextlib import contextmanager
from dataclasses import asdict
import json
from pathlib import Path
import shutil
import signal
import threading

from .adapters import get_adapter
from .checks import check_candidate, feedback
from .contracts import REPLY_SCHEMA, RunOutcome, RunSpec, RunStopped, SessionRequest, preserve_failure
from .executor import Executor
from .ledger import Ledger
from .records import Records, atomic_json, runs_root
from .workspace import Workspace


RUN_ERRORS = (RunStopped, OSError, ValueError, KeyError)
# A session that ended without a valid reply, including one that reached its own
# time limit. Its captured work can seed one more session; a second consecutive
# failure (for example, bad credentials or a hung CLI) stops the run.
SESSION_FAILURES = frozenset({
    "session_failed", "session_timeout", "invalid_native_output", "invalid_native_terminal",
    "output_after_native_terminal", "native_turn_failed", "multiple_native_turns",
    "invalid_agent_reply"})


def count_lines(path):
    try:
        with Path(path).open("rb") as stream:
            return sum(1 for _ in stream)
    except OSError:
        return 0


def run_session(spec, executor, workspace, records, outcome, command, directory, inputs):
    """Stop the worker before capture; preservation must not replace its failure.

    Returns (reply, candidate, session_failure). A session failure is returned rather
    than raised only after its work was captured and recorded.
    """
    output = reply = primary = None
    captured = False
    try:
        with executor.container(workspace.path, inputs=inputs, worker=True) as container:
            container.setup(directory / "worker")
            version = container.execute(f"source /tmp/agentmill-setup.env; {spec.agent} --version",
                                        directory, "version", 30)
            executor.require(version, "agent_executable")
            outcome.environment["agent_version"] = version.stdout.read_text().strip()
            def progress(elapsed):
                records.emit("session.progress", session=outcome.sessions, elapsed_seconds=round(elapsed),
                             native_events=count_lines(directory / "native.log"))
            output = container.session(command, directory, progress)
            # Validate before teardown so cleanup cannot replace a native failure.
            executor.require(output, "session")
            reply, telemetry = get_adapter(spec.agent).parse_result(output)
            outcome.agent_reply = asdict(reply)
        atomic_json(directory / "reply.json", outcome.agent_reply)
        atomic_json(directory / "telemetry.json", telemetry)
    except RUN_ERRORS as error:
        primary = error
    try:
        records.emit("session.finished", session=outcome.sessions,
                     returncode=output.returncode if output else None,
                     stop_reason=str(primary) if primary else None,
                     agent_status=(outcome.agent_reply or {}).get("status"))
    except RUN_ERRORS as error:
        primary = preserve_failure(primary, error, outcome.errors, f"session record failed: {error}")
    retryable = isinstance(primary, RunStopped) and primary.reason in SESSION_FAILURES
    if (primary and not retryable) or (reply and reply.status == "blocked"):
        executor.finalize()
    try:
        if not executor.worker_stopped:
            raise RunStopped("capture_unsafe_worker_running")
        maintenance = executor.preservation_mode()
        previous = workspace.latest
        try:
            candidate = workspace.capture(outcome.sessions, maintenance=maintenance)
        except RunStopped as error:
            if maintenance or str(error) not in ("cancelled", "run_duration_limit"):
                raise
            # Interruption can arrive between capture's Git commands. Restart once
            # against the same stopped workspace using the remaining finalization budget.
            primary = preserve_failure(primary, error, outcome.errors)
            executor.finalize()
            candidate = workspace.capture(outcome.sessions, maintenance=True)
        if candidate != previous:
            outcome.candidate_check_status = "unchecked"
    except RUN_ERRORS as error:
        failure = error if isinstance(error, RunStopped) else RunStopped("candidate_capture_failed")
        primary = preserve_failure(primary, failure, outcome.errors,
            f"candidate capture failed: {error}; artifacts cover only the last captured "
            f"revision {workspace.latest}; uncaptured work remains in {workspace.path}")
    else:
        try:
            records.emit("candidate.captured", session=outcome.sessions, candidate_sha=candidate)
            captured = True
        except RUN_ERRORS as error:
            primary = preserve_failure(primary, error, outcome.errors, f"candidate record failed: {error}")
    if primary and not (retryable and captured):
        raise primary
    return reply, candidate, primary


def finish_run(executor, workspace, records, outcome, failure):
    executor.finalize()
    if workspace:
        outcome.base_revision = workspace.base
        outcome.latest_candidate_sha = workspace.latest
    if workspace and workspace.base:
        try:
            executor.guard(maintenance=True)
            outcome.artifacts.update(workspace.export(outcome.last_passing_candidate_sha,
                                                      best=outcome.best_candidate_sha))
        except RUN_ERRORS as error:
            failure = preserve_failure(failure, RunStopped("artifact_export_failed"), outcome.errors,
                                       f"artifact export failed: {error}")
    outcome.finish(failure, cancellation=executor.cancellation)
    records.finish(outcome)


def record_checks(spec, executor, workspace, records, outcome, ledger, revision, session=0):
    """Check one candidate and enter the complete result set in the ledger."""
    passed, results = check_candidate(spec, executor, workspace, records, outcome, revision, session)
    grew = ledger.record(session, revision, results)
    outcome.best_candidate_sha = ledger.best
    outcome.ledger = ledger.summary()
    return passed, results, grew


UNCHANGED_CLAIM = ("That reply claimed done, but the candidate is identical to the base revision, which "
                   "already passed every check. An unchanged candidate cannot complete this run: make the "
                   "change the task asks for, or reply blocked if you believe none is needed.")


def session_prompt(spec, outcome, ledger, baseline, previous, failure=None, unchanged_claim=False):
    if outcome.agent_reply:
        handoff = json.dumps(outcome.agent_reply)
        if unchanged_claim:
            handoff += "\n" + UNCHANGED_CLAIM
    elif failure:
        handoff = (f"The previous session ended without a valid reply ({failure.reason}). "
                   "Its file changes were kept in this workspace.")
    else:
        handoff = "No previous session."
    return (
        "Complete the task below in this private workspace. Make changes directly; AgentMill captures "
        "them after you exit. Commits are optional. Do not push. Do not weaken checks to claim success. "
        "Return the required JSON reply: status done only when the task is complete, continue when "
        "more work remains, or blocked when outside input is required. Include a concise summary, "
        "next_step, and question (null when absent). Your claim is checked independently.\n\n"
        f"Task:\n{spec.task}\n\nAcceptance checks (all must pass on the captured candidate; "
        f"status is the latest candidate's):\n{ledger.render()}\n\nBaseline checks: {baseline}. A failing baseline can be repaired.\n"
        f"Session {outcome.sessions}/{spec.max_sessions}.\nPrevious reply:\n{handoff}\n\n"
        f"Latest check evidence (logs may be truncated):\n{feedback(previous)}\n"
    )


def check_inputs(spec, runs_dir):
    source_path = Path(spec.source).expanduser()
    storage = Path(runs_dir) if runs_dir else runs_root()
    if source_path.is_dir():
        git_dir = source_path / ".git"
        if not git_dir.exists() and not git_dir.is_symlink():
            raise ValueError(f"source is not the root of a Git checkout (no .git in {source_path})")
        if git_dir.is_symlink() or not git_dir.is_dir():
            raise ValueError("source .git is not a directory; linked worktrees and submodule "
                             "checkouts are not supported, so use the main checkout or a Git URL")
        if storage.resolve().is_relative_to(source_path.resolve()):
            raise ValueError("run directory must be outside the source checkout")
    # Reject unusable native inputs before cloning, setup or baseline checks.
    # The executor rechecks before mounting in case a file disappears during a run.
    for field in ("agent_config", "auth_file"):
        path = getattr(spec, field)
        if path and not Path(path).is_file():
            raise ValueError(f"{field} must be a regular file")
    if spec.check_dir and not Path(spec.check_dir).is_dir():
        raise ValueError("check_dir must be a directory")


@contextmanager
def signals_cancel(executor):
    previous_handlers = {}
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[sig] = signal.signal(sig, executor.cancel)
    try:
        yield
    finally:
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)


def verify(spec: RunSpec, on_event=None, *, runs_dir=None) -> RunOutcome:
    """Check one committed revision in fresh containers. No agent runs."""
    check_inputs(spec, runs_dir)
    records = Records(runs_dir, on_event)
    outcome = RunOutcome(records.run_id, mode="verify")
    outcome.artifacts = {"run_directory": str(records.directory)}
    executor = Executor(spec, records.directory, errors=outcome.errors)
    ledger = Ledger(spec.checks, records.directory / "ledger.json", bool(spec.check_dir))
    failure = RunStopped("startup_failed")
    with signals_cancel(executor):
        try:
            atomic_json(records.directory / "spec.json", spec.to_dict())
            records.emit("verify.started", source=spec.source, revision=spec.revision,
                         checks=[check.id for check in spec.checks],
                         input_policy="Only the selected committed revision; source working files are not included.")
            outcome.environment = executor.inspect_image()
            if spec.check_dir:
                shutil.copytree(spec.check_dir, records.directory / "verifier", symlinks=True)
            workspace = Workspace(executor, records.directory)
            outcome.base_revision = outcome.latest_candidate_sha = workspace.prepare(spec.source, spec.revision)
            atomic_json(records.directory / "input.json", {"source": spec.source, "base_revision": workspace.base})
            records.emit("candidate.captured", session=0, candidate_sha=workspace.base)
            passed, _, _ = record_checks(spec, executor, workspace, records, outcome, ledger, workspace.base)
            executor.guard()
            failure = None if passed else RunStopped("checks_failed", 2)
        except RUN_ERRORS as error:
            failure = error
        finally:
            executor.finalize()
            outcome.finish(failure, cancellation=executor.cancellation, success="checks_passed")
            records.finish(outcome)
    return outcome


def run(spec: RunSpec, on_event=None, *, runs_dir=None) -> RunOutcome:
    check_inputs(spec, runs_dir)
    records = Records(runs_dir, on_event)
    outcome = RunOutcome(records.run_id)
    outcome.artifacts = {"run_directory": str(records.directory),
                         "workspace": str(records.directory / "workspace")}
    executor = Executor(spec, records.directory, errors=outcome.errors)
    ledger = Ledger(spec.checks, records.directory / "ledger.json", bool(spec.check_dir))
    workspace = None
    failure = RunStopped("startup_failed")
    with signals_cancel(executor):
        try:
            atomic_json(records.directory / "spec.json", spec.to_dict())
            (records.directory / "task.txt").write_text(spec.task, encoding="utf-8")
            records.emit("run.started", source=spec.source, revision=spec.revision,
                         workspace=outcome.artifacts["workspace"], agent=spec.agent,
                         max_sessions=spec.max_sessions, max_duration=spec.max_duration,
                         setup_timeout=spec.setup_timeout, session_timeout=spec.session_timeout,
                         check_timeout=spec.check_timeout,
                         input_policy="Only the selected committed revision; source working files are not included.")
            # Fail on a missing image or unreachable Docker before cloning the source.
            outcome.environment = executor.inspect_image()
            if spec.check_dir:
                # Snapshot held-out checks once; only check containers mount this copy.
                shutil.copytree(spec.check_dir, records.directory / "verifier", symlinks=True)
            workspace = Workspace(executor, records.directory)
            workspace.prepare(spec.source, spec.revision)
            atomic_json(records.directory / "spec.json", {**spec.to_dict(), "revision": workspace.base})
            # Record the resolved input once; never resolve a branch again during this run.
            atomic_json(records.directory / "input.json", {"source": spec.source, "base_revision": workspace.base})
            records.emit("candidate.captured", session=0, candidate_sha=workspace.base)
            passed, previous, _ = record_checks(spec, executor, workspace, records, outcome, ledger, workspace.base)
            baseline = "passed" if passed else "failed"
            if passed:
                outcome.errors.append("every check already passes at the base revision, so the checks cannot "
                                      "show that the task was done; add a check that fails before the change")
            adapter = get_adapter(spec.agent)
            retried = None
            stalled = 0
            unchanged_claim = False
            for session in range(1, spec.max_sessions + 1):
                executor.guard()
                outcome.sessions = session
                directory = records.directory / "sessions" / f"{session:04d}"
                inputs = directory / "inputs"
                inputs.mkdir(parents=True)
                prompt = session_prompt(spec, outcome, ledger, baseline, previous, retried, unchanged_claim)
                outcome.agent_reply = None
                (directory / "prompt.txt").write_text(prompt, encoding="utf-8")
                (inputs / "prompt.txt").write_text(prompt, encoding="utf-8")
                atomic_json(inputs / "reply.schema.json", REPLY_SCHEMA)
                command = adapter.build_command(SessionRequest(spec.model, spec.profile, bool(spec.agent_config)))
                atomic_json(directory / "command.json", asdict(command))
                records.emit("session.started", session=session, max_sessions=spec.max_sessions, logs=str(directory))
                reply, candidate, session_failure = run_session(
                    spec, executor, workspace, records, outcome, command, directory, inputs)
                if cancellation := executor.cancellation:
                    raise cancellation
                grew = unchanged_claim = False
                if session_failure:
                    if retried or session == spec.max_sessions:
                        raise session_failure
                    retried = session_failure
                    outcome.errors.append(f"session {session} ended without a valid reply "
                                          f"({retried.reason}); its captured work seeds the next session")
                    executor.guard()
                    # Check changed work for feedback and last-passing evidence; it cannot complete the run.
                    if not previous or previous[0]["candidate_sha"] != candidate:
                        passed, previous, grew = record_checks(spec, executor, workspace, records, outcome,
                                                               ledger, candidate, session)
                else:
                    retried = None
                    if reply.status == "blocked":
                        raise RunStopped("agent_blocked", 3)
                    executor.guard()
                    passed, previous, grew = record_checks(spec, executor, workspace, records, outcome,
                                                           ledger, candidate, session)
                    # Success is decided within the run budget; required exports may use
                    # the single finalization allowance after that decision.
                    executor.guard()
                    # Checks that already passed at the base cannot certify an unchanged candidate.
                    unchanged_claim = (reply.status == "done" and passed
                                       and workspace.same_tree(candidate, workspace.base))
                    if reply.status == "done" and passed and not unchanged_claim:
                        failure = None
                        break
                stalled = 0 if grew else stalled + 1
                if spec.stall_sessions and stalled >= spec.stall_sessions and session < spec.max_sessions:
                    outcome.errors.append(f"no new check passed in {stalled} consecutive sessions")
                    raise RunStopped("stalled", 2)
            else:
                raise RunStopped("unchanged_candidate" if unchanged_claim else "session_limit", 2)
        except RUN_ERRORS as error:
            failure = error
        finally:
            finish_run(executor, workspace, records, outcome, failure)
    return outcome
