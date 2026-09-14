"""Container entrypoint for the opt-in, foreground Claude loop. Stdlib only."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


SCHEMA = {
    "type": "object",
    "properties": {"done": {"type": "boolean"}, "summary": {"type": "string"}},
    "required": ["done", "summary"],
    "additionalProperties": False,
}


class RunStopped(Exception):
    """A command failed, timed out, or was cancelled."""


class BasicLoop:
    def __init__(self, args):
        self.args = args
        self.cancelled = 0
        self.iteration = 0
        self.claimed = False
        self.checked_commit = None
        self.reason = "startup_failed"

    def cancel(self, signum, _frame):
        self.cancelled = self.cancelled or signum

    @staticmethod
    def kill_group(process, signum):
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass

    def command(self, argv, label):
        """Give each command a session, a deadline, and bounded group cleanup."""
        if self.cancelled:
            raise RunStopped("cancelled")
        print(f"[{self.iteration}] {label}", flush=True)
        with (self.args.logs / f"{label}.log").open("wb") as output:
            with (self.args.logs / f"{label}.stderr.log").open("wb") as errors:
                process = subprocess.Popen(
                    argv, cwd=self.args.repo, stdin=subprocess.DEVNULL,
                    stdout=output, stderr=errors, start_new_session=True,
                )
                deadline = time.monotonic() + self.args.timeout
                try:
                    while process.poll() is None:
                        if self.cancelled or time.monotonic() >= deadline:
                            raise RunStopped("cancelled" if self.cancelled else f"{label}_timeout")
                        time.sleep(0.05)
                finally:
                    # Kill leftover children even if their leader exited normally.
                    self.kill_group(process, signal.SIGTERM)
                    if process.poll() is None:
                        try:
                            process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            pass
                    self.kill_group(process, signal.SIGKILL)
                    process.wait()
        if self.cancelled:
            raise RunStopped("cancelled")
        if process.returncode:
            raise RunStopped(f"{label}_failed")

    def git(self, *arguments):
        return subprocess.check_output(
            ["git", "-c", "core.fsmonitor=false", *arguments],
            cwd=self.args.repo, timeout=10, text=True, stderr=subprocess.PIPE,
        ).strip()

    def require_clean(self):
        if self.git("status", "--porcelain", "--untracked-files=all"):
            raise RunStopped("dirty_checkout")

    def verify(self, label):
        self.checked_commit = None
        before = self.git("rev-parse", "HEAD")
        self.command(["bash", "-c", self.args.check], label)
        self.require_clean()
        if before != self.git("rev-parse", "HEAD"):
            raise RunStopped("verifier_changed_commit")
        return before

    def run(self):
        self.require_clean()
        mission = (self.args.repo / "MILL.md").read_text()
        if not mission.strip():
            raise RunStopped("empty_mission")
        self.verify("baseline")
        prompt = (
            "Work on the mission below. Read PROGRESS.md and git history for the handoff "
            "from previous sessions. Make useful progress, update PROGRESS.md with what "
            "you did and what remains, and commit your changes. Leave a clean checkout. "
            "Do not push. Do not weaken the checks to make them pass. Set done=true only "
            "when the entire mission is complete; otherwise set done=false. Return a "
            "short summary with the structured result.\n\n"
            f"Verification command: {self.args.check}\n\nMission:\n{mission}"
        )
        for self.iteration in range(1, self.args.iterations + 1):
            self.claimed = False
            self.checked_commit = None
            label = f"session-{self.iteration}"
            argv = ["claude", "-p", prompt, "--dangerously-skip-permissions",
                    "--output-format", "json", "--json-schema", json.dumps(SCHEMA)]
            if self.args.model:
                argv += ["--model", self.args.model]
            self.command(argv, label)
            result = json.loads((self.args.logs / f"{label}.log").read_text())
            if (not isinstance(result, dict) or result.get("type") != "result"
                    or result.get("subtype") != "success" or result.get("is_error") is not False):
                raise RunStopped("invalid_agent_result")
            reply = result.get("structured_output")
            if (not isinstance(reply, dict) or type(reply.get("done")) is not bool
                    or not isinstance(reply.get("summary"), str)):
                raise RunStopped("invalid_agent_result")
            self.claimed = reply["done"]
            print(reply["summary"], flush=True)
            self.require_clean()
            self.checked_commit = self.verify(f"check-{self.iteration}")
            if self.claimed:
                self.reason = "verified_complete"
                return 0
        self.reason = "iteration_limit"
        return 2


def positive(value):
    number = int(value)
    if not 1 <= number <= 999999:
        raise argparse.ArgumentTypeError("must be between 1 and 999999")
    return number


def main(repo=Path("/workspace"), logs=Path("/logs")):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=positive, default=5)
    parser.add_argument("--timeout", type=positive, default=1800)
    parser.add_argument("--model", default="")
    args = parser.parse_args()
    args.repo, args.logs = repo, logs
    args.check = os.environ.get("CHECK_CMD", "")
    if not args.check.strip():
        parser.error("CHECK_CMD is required")
    args.logs.mkdir(parents=True, exist_ok=True)
    run = BasicLoop(args)
    signal.signal(signal.SIGINT, run.cancel)
    signal.signal(signal.SIGTERM, run.cancel)
    code = 1
    try:
        # Numeric host UID may not have a passwd entry in the image.
        claude_home = Path.home()
        claude_home.mkdir(parents=True, exist_ok=True)
        config = claude_home / ".claude.json"
        if not config.exists():
            config.write_text('{"hasCompletedOnboarding":true}\n')
        code = run.run()
    except (RunStopped, OSError, ValueError, subprocess.SubprocessError) as error:
        run.reason = str(error) if isinstance(error, RunStopped) else "runtime_error"
        print(f"Stopped: {error}", flush=True)
    if run.cancelled:
        code, run.reason = 128 + run.cancelled, "cancelled"
    outcome = {
        "schema_version": 1, "exit_code": code, "reason": run.reason,
        "iterations": run.iteration, "agent_claimed_done": run.claimed,
        "checked_commit": run.checked_commit,
    }
    temporary = args.logs / "outcome.tmp"
    temporary.write_text(json.dumps(outcome, indent=2) + "\n")
    temporary.replace(args.logs / "outcome.json")
    print(f"Outcome: {run.reason} (exit {code})", flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
