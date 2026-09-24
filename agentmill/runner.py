"""One bounded repair loop. Native flags stay in adapters."""

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
            output = container.session(command, directory)
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
            outcome.artifacts.update(workspace.export(outcome.last_passing_candidate_sha))
        except RUN_ERRORS as error:
            failure = preserve_failure(failure, RunStopped("artifact_export_failed"), outcome.errors,
                                       f"artifact export failed: {error}")
    outcome.finish(failure, cancellation=executor.cancellation)
    records.finish(outcome)


def session_prompt(spec, outcome, baseline, previous, failure=None):
    if outcome.agent_reply:
        handoff = json.dumps(outcome.agent_reply)
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
        f"Task:\n{spec.task}\n\nChecks:\n" + "\n".join(spec.checks) +
        f"\n\nBaseline checks: {baseline}. A failing baseline can be repaired.\n"
        f"Session {outcome.sessions}/{spec.max_sessions}.\nPrevious reply:\n{handoff}\n\n"
        f"Latest check evidence (logs may be truncated):\n{feedback(previous)}\n"
    )


def run(spec: RunSpec, on_event=None, *, runs_dir=None) -> RunOutcome:
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
    records = Records(runs_dir, on_event)
    outcome = RunOutcome(records.run_id)
    outcome.artifacts = {"run_directory": str(records.directory),
                         "workspace": str(records.directory / "workspace")}
    executor = Executor(spec, records.directory, errors=outcome.errors)
    previous_handlers = {}
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[sig] = signal.signal(sig, executor.cancel)
    workspace = None
    failure = RunStopped("startup_failed")
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
        passed, previous = check_candidate(spec, executor, workspace, records, outcome, workspace.base)
        baseline = "passed" if passed else "failed"
        adapter = get_adapter(spec.agent)
        retried = None
        for session in range(1, spec.max_sessions + 1):
            executor.guard()
            outcome.sessions = session
            directory = records.directory / "sessions" / f"{session:04d}"
            inputs = directory / "inputs"
            inputs.mkdir(parents=True)
            prompt = session_prompt(spec, outcome, baseline, previous, retried)
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
            if session_failure:
                if retried or session == spec.max_sessions:
                    raise session_failure
                retried = session_failure
                outcome.errors.append(f"session {session} ended without a valid reply "
                                      f"({retried.reason}); its captured work seeds the next session")
                executor.guard()
                # Check changed work for feedback and last-passing evidence; it cannot complete the run.
                if not previous or previous[0]["candidate_sha"] != candidate:
                    passed, previous = check_candidate(spec, executor, workspace, records, outcome,
                                                       candidate, session)
                continue
            retried = None
            if reply.status == "blocked":
                raise RunStopped("agent_blocked", 3)
            executor.guard()
            passed, previous = check_candidate(spec, executor, workspace, records, outcome, candidate, session)
            # Success is decided within the run budget; required exports may use
            # the single finalization allowance after that decision.
            executor.guard()
            if reply.status == "done" and passed:
                failure = None
                break
        else:
            raise RunStopped("session_limit", 2)
    except RUN_ERRORS as error:
        failure = error
    finally:
        try:
            finish_run(executor, workspace, records, outcome, failure)
        finally:
            for sig, handler in previous_handlers.items():
                signal.signal(sig, handler)
    return outcome
