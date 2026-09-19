"""Checks always start from a captured revision in a fresh environment."""

from pathlib import Path
import sys

from .contracts import RunStopped
from .records import atomic_json


def check_candidate(spec, executor, workspace, records, outcome, revision, session=0):
    directory = records.directory / (f"sessions/{session:04d}" if session else "baseline")
    directory.mkdir(parents=True, exist_ok=True)
    checkout = records.directory / "checks" / (f"{session:04d}")
    checkout.parent.mkdir(exist_ok=True)
    workspace.checkout(revision, checkout)
    results = []
    try:
        with executor.container(checkout) as container:
            container.setup(directory)
            if not workspace.unchanged(revision, checkout):
                raise RunStopped("check_setup_changed_candidate")
            for number, command in enumerate(spec.checks, 1):
                output = container.check(command, directory, number)
                result = {
                    "candidate_sha": revision, "session": session, "command": command,
                    "status": "error" if output.stop_reason or output.returncode in (126, 127)
                    else ("passed" if output.returncode == 0 else "failed"),
                    "returncode": output.returncode, "stop_reason": output.stop_reason,
                    "elapsed_seconds": output.elapsed, "stdout": str(output.stdout),
                    "stderr": str(output.stderr), "image_id": executor.image,
                    "container": container.name,
                }
                results.append(result)
                outcome.checks.append(result)
                changed = not output.stop_reason and not workspace.unchanged(revision, checkout)
                if changed:
                    result["status"] = "error"
                    result["stop_reason"] = "check_changed_candidate"
                if output.stop_reason:
                    executor.require(output, "check")
                if output.returncode in (126, 127):
                    raise RunStopped("check_command_unavailable")
                if changed:
                    raise RunStopped("check_changed_candidate")
        # Also inspect after container removal: check-created background processes
        # must not change tracked source between the final command and shutdown.
        if not workspace.unchanged(revision, checkout):
            results[-1]["status"] = "error"
            results[-1]["stop_reason"] = "check_changed_candidate"
            raise RunStopped("check_changed_candidate")
        passed = all(result["status"] == "passed" for result in results)
        if passed:
            outcome.last_passing_candidate_sha = revision
        return passed, results
    finally:
        primary = sys.exception()
        try:
            atomic_json(directory / "checks.json", results)
            for result in results:
                records.emit("check.finished", **result)
        except (OSError, ValueError) as error:
            if primary is None:
                raise
            executor.errors.append(f"check record failed: {error}")


def feedback(results, limit=12000):
    """Keep complete logs on disk, but bound the next prompt's check evidence."""
    parts = []
    for result in results:
        parts.append(f"Command: {result['command']}\nStatus: {result['status']} (exit {result['returncode']})")
        for key in ("stdout", "stderr"):
            path = Path(result[key])
            if path.exists():
                with path.open("rb") as stream:
                    stream.seek(max(0, path.stat().st_size - 3000))
                    tail = stream.read(3000).decode("utf-8", errors="replace")
                parts.append(f"{key} tail:\n{tail}")
    text = "\n".join(parts)
    return text if len(text) <= limit else "[Earlier feedback truncated]\n" + text[-limit:]
