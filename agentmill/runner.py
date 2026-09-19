"""One bounded repair loop. Native flags stay in adapters."""

from dataclasses import asdict
import json
from pathlib import Path
import signal
import threading
import time

from .adapters import get_adapter
from .checks import check_candidate, feedback
from .contracts import REPLY_SCHEMA, RunOutcome, RunSpec, RunStopped, SessionRequest
from .executor import Executor
from .records import Records, atomic_json, runs_root
from .workspace import Workspace


RUN_ERRORS = (RunStopped, OSError, ValueError, KeyError)


def run_session(spec, executor, workspace, records, outcome, command, directory, inputs):
    """Stop the worker before capture; preservation must not replace its failure."""
    output = reply = primary = None
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
        outcome.errors.append(f"session record failed: {error}")
        primary = primary or error
    if primary or (reply and reply.status == "blocked") or executor.cancelled or executor.deadline <= time.monotonic():
        executor.finalize()
    try:
        if not executor.worker_stopped:
            raise RunStopped("capture_unsafe_worker_running")
        candidate = workspace.capture(outcome.sessions, maintenance=executor.finalize_deadline is not None)
        outcome.latest_candidate_sha = candidate
        outcome.candidate_check_status = "unchecked"
    except RUN_ERRORS as error:
        outcome.errors.append(f"candidate capture failed: {error}; artifacts cover only the last captured "
                              f"revision {outcome.latest_candidate_sha}; uncaptured work remains in {workspace.path}")
        if primary is None:
            primary = error if isinstance(error, RunStopped) else RunStopped("candidate_capture_failed")
    else:
        try:
            records.emit("candidate.captured", session=outcome.sessions, candidate_sha=candidate)
        except RUN_ERRORS as error:
            outcome.errors.append(f"candidate record failed: {error}")
            primary = primary or error
    if primary:
        raise primary
    return reply, candidate


def finish_run(executor, workspace, records, outcome):
    executor.finalize()
    if workspace and outcome.base_revision:
        try:
            executor.guard(maintenance=True)
            outcome.artifacts.update(workspace.export(outcome.last_passing_candidate_sha))
        except RUN_ERRORS as error:
            outcome.errors.append(f"artifact export failed: {error}")
            if outcome.exit_code == 0:
                outcome.status, outcome.stop_reason, outcome.exit_code = "failed", "artifact_export_failed", 1
    outcome.errors.extend(executor.errors)
    if executor.cancelled:
        if outcome.stop_reason != "cancelled":
            outcome.errors.append(f"cancelled while handling: {outcome.stop_reason}")
        outcome.status, outcome.stop_reason = "cancelled", "cancelled"
        outcome.exit_code = 128 + executor.cancelled
    records.finish(outcome)


def session_prompt(spec, outcome, baseline, previous):
    handoff = json.dumps(outcome.agent_reply) if outcome.agent_reply else "No previous session."
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
    if source_path.is_dir() and storage.resolve().is_relative_to(source_path.resolve()):
        raise ValueError("run directory must be outside the source checkout")
    # Reject unusable native inputs before cloning, setup or baseline checks.
    # The executor rechecks before mounting in case a file disappears during a run.
    for field in ("agent_config", "auth_file"):
        path = getattr(spec, field)
        if path and not Path(path).is_file():
            raise ValueError(f"{field} must be a regular file")
    records = Records(runs_dir, on_event)
    outcome = RunOutcome(records.run_id)
    outcome.artifacts = {"run_directory": str(records.directory),
                         "workspace": str(records.directory / "workspace")}
    executor = Executor(spec, records.directory)
    previous_handlers = {}
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[sig] = signal.signal(sig, executor.cancel)
    workspace = None
    try:
        atomic_json(records.directory / "spec.json", spec.to_dict())
        (records.directory / "task.txt").write_text(spec.task, encoding="utf-8")
        records.emit("run.started", source=spec.source, revision=spec.revision,
                     workspace=outcome.artifacts["workspace"], agent=spec.agent,
                     max_sessions=spec.max_sessions, max_duration=spec.max_duration,
                     setup_timeout=spec.setup_timeout, session_timeout=spec.session_timeout,
                     check_timeout=spec.check_timeout,
                     input_policy="Only the selected committed revision; source working files are not included.")
        workspace = Workspace(executor, records.directory)
        outcome.base_revision = workspace.prepare(spec.source, spec.revision)
        outcome.latest_candidate_sha = outcome.base_revision
        atomic_json(records.directory / "spec.json", {**spec.to_dict(), "revision": workspace.base})
        # Record the resolved input once; never resolve a branch again during this run.
        atomic_json(records.directory / "input.json", {"source": spec.source, "base_revision": workspace.base})
        records.emit("candidate.captured", session=0, candidate_sha=workspace.base)
        outcome.environment = executor.inspect_image()
        passed, previous = check_candidate(spec, executor, workspace, records, outcome, workspace.base)
        baseline = "passed" if passed else "failed"
        adapter = get_adapter(spec.agent)
        for session in range(1, spec.max_sessions + 1):
            executor.guard()
            outcome.sessions = session
            directory = records.directory / "sessions" / f"{session:04d}"
            inputs = directory / "inputs"
            inputs.mkdir(parents=True)
            prompt = session_prompt(spec, outcome, baseline, previous)
            outcome.agent_reply = None
            (directory / "prompt.txt").write_text(prompt, encoding="utf-8")
            (inputs / "prompt.txt").write_text(prompt, encoding="utf-8")
            atomic_json(inputs / "reply.schema.json", REPLY_SCHEMA)
            command = adapter.build_command(SessionRequest(spec.model, spec.profile, bool(spec.agent_config)))
            atomic_json(directory / "command.json", {"argv": command.argv, "stdin": command.stdin,
                                                     "reply_path": command.reply_path})
            records.emit("session.started", session=session, max_sessions=spec.max_sessions, logs=str(directory))
            reply, candidate = run_session(spec, executor, workspace, records, outcome, command, directory, inputs)
            if executor.cancelled:
                executor.guard()
            if reply.status == "blocked":
                raise RunStopped("agent_blocked", 3)
            executor.guard()
            passed, previous = check_candidate(spec, executor, workspace, records, outcome, candidate, session)
            # Success is decided within the run budget; required exports may use
            # the single finalization allowance after that decision.
            executor.guard()
            if reply.status == "done" and passed:
                outcome.status, outcome.stop_reason, outcome.exit_code = "checked_complete", "checked_complete", 0
                break
        else:
            raise RunStopped("session_limit", 2)
    except RunStopped as error:
        outcome.stop_reason, outcome.exit_code = error.reason, error.exit_code
        outcome.status = {2: "incomplete", 3: "blocked", 130: "cancelled", 143: "cancelled"}.get(error.exit_code, "failed")
    except (OSError, ValueError, KeyError) as error:
        outcome.stop_reason, outcome.exit_code, outcome.status = "runtime_error", 1, "failed"
        outcome.errors.append(f"{type(error).__name__}: {error}")
    finally:
        try:
            finish_run(executor, workspace, records, outcome)
        finally:
            for sig, handler in previous_handlers.items():
                signal.signal(sig, handler)
    return outcome
