"""One process supervisor and one Docker execution path."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time
import uuid

from .contracts import ProcessOutput, RunStopped, preserve_failure


DOCKER_UNREACHABLE = ("cannot connect to the docker daemon", "failed to connect to the docker api",
                      "is the docker daemon running")


def stderr_tail(path, limit=600):
    try:
        with Path(path).open("rb") as stream:
            stream.seek(max(0, Path(path).stat().st_size - limit))
            text = stream.read().decode("utf-8", errors="replace")
    except OSError:
        return ""
    return " / ".join(line.strip() for line in text.splitlines() if line.strip())[-limit:]


def command_name(argv):
    """Name a tool invocation without its option values, e.g. `git clone`."""
    words, skip = [Path(argv[0]).name], False
    for word in argv[1:]:
        if skip:
            skip = False
        elif word in ("-c", "-C", "--git-dir", "--work-tree"):
            skip = True
        elif not word.startswith("-"):
            words.append(word)
            break
    return " ".join(words)


def runtime_hint(detail):
    text = (detail or "").lower()
    if any(marker in text for marker in DOCKER_UNREACHABLE):
        return ". Docker is not reachable: start Docker Desktop, Colima, or the Docker daemon"
    if "bind source path does not exist" in text:
        return (". Docker cannot see this host path: keep --runs-dir in a directory shared with "
                "the Docker VM, such as one under your home directory")
    return ""


class Executor:
    progress_interval = 60

    def __init__(self, spec, directory, *, errors=None):
        self.spec = spec
        self.directory = Path(directory)
        self.deadline = time.monotonic() + spec.max_duration
        self.finalize_deadline = None
        self.cancelled = 0
        self.image = spec.image
        self.operation = 0
        self.worker_stopped = True
        self.errors = [] if errors is None else errors

    def cancel(self, signum, _frame=None):
        self.cancelled = self.cancelled or signum

    def finalize(self):
        if self.finalize_deadline is None:
            self.finalize_deadline = time.monotonic() + 30

    @property
    def cancellation(self):
        return RunStopped("cancelled", 128 + self.cancelled) if self.cancelled else None

    def preservation_mode(self):
        """Use preservation after a stop or once finalization has begun."""
        if self._stop_reason(self.deadline):
            self.finalize()
        return self.finalize_deadline is not None

    def _budget_deadline(self, maintenance):
        return self.finalize_deadline if maintenance and self.finalize_deadline is not None else self.deadline

    def _stop_reason(self, deadline, *, maintenance=False, expired="run_duration_limit", now=None):
        if self.cancelled and not maintenance:
            return "cancelled"
        if (time.monotonic() if now is None else now) >= deadline:
            return expired
        return None

    def guard(self, *, maintenance=False):
        now = time.monotonic()
        if maintenance:
            if self.finalize_deadline is None and self._stop_reason(self.deadline, now=now):
                self.finalize()
        expired = "finalization_timeout" if maintenance and self.finalize_deadline is not None else "run_duration_limit"
        reason = self._stop_reason(self._budget_deadline(maintenance), maintenance=maintenance, expired=expired, now=now)
        if reason:
            code = {"cancelled": 128 + self.cancelled, "run_duration_limit": 2}.get(reason, 1)
            raise RunStopped(reason, code)

    @staticmethod
    def kill_group(process, sig):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass

    def command(self, argv, stdout, stderr, timeout, *, stdin=None, env=None, maintenance=False, cwd=None,
                progress=None):
        start = time.monotonic()
        reason = None
        process = None
        self.guard(maintenance=maintenance)
        stdout, stderr = Path(stdout), Path(stderr)
        stdout.parent.mkdir(parents=True, exist_ok=True)
        with stdout.open("wb") as out, stderr.open("wb") as err:
            input_stream = open(stdin, "rb") if stdin else None
            try:
                self.guard(maintenance=maintenance)
                budget_deadline = self._budget_deadline(maintenance)
                # None omits only the per-command cap; the enclosing budget is finite.
                phase_deadline = start + timeout if timeout is not None else budget_deadline
                deadline = min(phase_deadline, budget_deadline)
                expired = "run_duration_limit" if not maintenance and self.deadline <= phase_deadline else "timeout"
                process = subprocess.Popen(argv, stdin=input_stream or subprocess.DEVNULL,
                                           stdout=out, stderr=err, env=env, cwd=cwd, start_new_session=True)
                next_progress = start + self.progress_interval
                while process.poll() is None:
                    reason = self._stop_reason(deadline, maintenance=maintenance, expired=expired)
                    if reason:
                        break
                    if progress and time.monotonic() >= next_progress:
                        next_progress += self.progress_interval
                        try:
                            progress(time.monotonic() - start)
                        except (OSError, ValueError):
                            # A failed progress record must never affect the supervised process.
                            progress = None
                    time.sleep(0.025)
            finally:
                if process:
                    self.kill_group(process, signal.SIGTERM)
                    try:
                        process.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        pass
                    self.kill_group(process, signal.SIGKILL)
                    process.wait()
                if input_stream:
                    input_stream.close()
        if self.cancelled and not maintenance:
            reason = "cancelled"
        # Run-ending interruptions start finalization; a phase timeout leaves that
        # decision to its caller, which may continue with the remaining run budget.
        if reason in ("cancelled", "run_duration_limit") and not maintenance:
            self.finalize()
        return ProcessOutput(process.returncode, stdout, stderr, time.monotonic() - start, reason)

    def require(self, output, phase):
        if output.stop_reason == "cancelled":
            raise RunStopped("cancelled", 128 + self.cancelled)
        if output.stop_reason == "run_duration_limit":
            raise RunStopped("run_duration_limit", 2)
        if output.stop_reason:
            raise RunStopped(f"{phase}_{output.stop_reason}", 2 if phase == "session" else 1)
        if output.returncode:
            raise RunStopped(f"{phase}_failed")

    def control(self, argv, *, timeout=30, maintenance=False, env=None):
        self.operation += 1
        folder = self.directory / "operations"
        output = self.command(argv, folder / f"{self.operation:04d}.log",
                              folder / f"{self.operation:04d}.stderr.log", timeout,
                              maintenance=maintenance, env=env)
        # Interruptions explain themselves; a failed or stalled tool needs its own words.
        detail = None
        if output.stop_reason == "timeout" or (output.returncode and output.stop_reason is None):
            detail = stderr_tail(output.stderr)
            status = "timed out" if output.stop_reason else f"exited {output.returncode}"
            self.errors.append(f"{command_name(argv)} {status}: {detail or 'no error output'}"
                               f" (log: {output.stderr}){runtime_hint(detail)}")
        try:
            self.require(output, "runtime")
        except RunStopped as error:
            error.detail = detail
            raise
        return output.stdout.read_bytes()

    def inspect_image(self):
        try:
            data = json.loads(self.control(["docker", "image", "inspect", self.spec.image]))
        except RunStopped as error:
            text = (error.detail or "").lower()
            if any(marker in text for marker in DOCKER_UNREACHABLE):
                raise RunStopped("docker_unavailable") from error
            if "no such image" in text or "no such object" in text:
                image = self.spec.image
                fix = (f"pull it with `docker pull {image}`" if "/" in image
                       else "build it with `./mill build` from an AgentMill checkout")
                self.errors.append(f"image {image} is not available locally; {fix}, or select one with --image")
                raise RunStopped("image_unavailable") from error
            raise
        self.image = data[0]["Id"]
        return {"image": self.spec.image, "image_id": self.image,
                "repo_digests": data[0].get("RepoDigests", []),
                "os": data[0].get("Os"), "architecture": data[0].get("Architecture")}

    @staticmethod
    def mount(path, target, readonly=False):
        path = Path(path).resolve()
        if "," in str(path):
            raise ValueError("Docker mount paths cannot contain commas")
        return ["--mount", f"type=bind,src={path},dst={target}" + (",readonly" if readonly else "")]

    @contextmanager
    def container(self, workspace, *, inputs=None, worker=False):
        name = f"agentmill-{self.directory.name}-{uuid.uuid4().hex[:8]}"
        argv = ["docker", "create", "--init", "--name", name,
                "--label", f"agentmill.run={self.directory.name}",
                "--tmpfs", "/scratch:rw,mode=1777",
                "--tmpfs", f"/home/agentmill:rw,mode=0700,uid={os.getuid()},gid={os.getgid()}",
                "--user", f"{os.getuid()}:{os.getgid()}", "--cap-drop", "ALL",
                "--security-opt", "no-new-privileges", "--workdir", "/workspace",
                "--env", "HOME=/home/agentmill", "--env", "CODEX_HOME=/home/agentmill/.codex",
                "--env", "UV_PROJECT_ENVIRONMENT=/tmp/agentmill-venv",
                "--env", "GIT_CONFIG_COUNT=1", "--env", "GIT_CONFIG_KEY_0=safe.directory",
                "--env", "GIT_CONFIG_VALUE_0=/workspace",
                "--env", "GIT_AUTHOR_NAME=AgentMill", "--env", "GIT_AUTHOR_EMAIL=agentmill@localhost",
                "--env", "GIT_COMMITTER_NAME=AgentMill", "--env", "GIT_COMMITTER_EMAIL=agentmill@localhost",
                *self.mount(workspace, "/workspace")]
        if inputs:
            argv += self.mount(inputs, "/inputs", True)
        if not worker and self.spec.check_dir:
            # Held-out checks: the run's snapshot, read-only, never in a worker container.
            argv += self.mount(self.directory / "verifier", "/checks", True)
        if worker:
            for field, target in (("agent_config", "/native/config"), ("auth_file", "/native/auth.json")):
                path = getattr(self.spec, field)
                if path:
                    if not Path(path).is_file():
                        raise ValueError(f"{field} must be a regular file")
                    argv += self.mount(path, target, True)
        argv += ["--entrypoint", "sleep", self.image, "infinity"]
        try:
            if worker:
                self.worker_stopped = False
            self.control(argv)
            self.control(["docker", "start", name])
            yield Container(self, name)
        finally:
            primary = sys.exception()
            # Even a failed create client may have created a daemon-owned container.
            stopped = self._remove_container(name)
            if worker:
                self.worker_stopped = stopped
            if not stopped:
                error = RunStopped("container_cleanup_failed")
                if preserve_failure(primary, error, self.errors,
                                    f"container_cleanup_failed: shutdown of {name} could not be confirmed") is error:
                    raise error

    def _remove_container(self, name):
        folder = self.directory / "operations"
        try:
            for action, options in (("stop", ("--time", "2")), ("rm", ("--force",))):
                self.command(["docker", action, *options, name], folder / f"{name}-{action}.log",
                             folder / f"{name}-{action}.stderr.log", 5, maintenance=True)
            # Listing requires a healthy daemon. A failed inspect alone could mean an outage.
            remaining = self.control(["docker", "ps", "-aq", "--filter", f"name=^/{name}$"],
                                     timeout=5, maintenance=True)
            return not remaining.strip()
        except (OSError, RunStopped):
            return False


class Container:
    def __init__(self, executor, name):
        self.executor = executor
        self.name = name

    def execute(self, script, directory, label, timeout, *, credentials=False, progress=None):
        directory = Path(directory)
        argv = ["docker", "exec"]
        if credentials:
            for name in self.executor.spec.credential_env:
                if name in os.environ:
                    argv += ["--env", name]
        argv += [self.name, "bash", "-ec", script]
        return self.executor.command(argv, directory / f"{label}.log",
                                     directory / f"{label}.stderr.log", timeout, progress=progress)

    def setup(self, directory):
        script = ("mkdir -p \"$HOME\" /scratch; export -p > /tmp/agentmill-setup.env;\n" + self.executor.spec.setup +
                  "\nexport -p > /tmp/agentmill-setup.env")
        result = self.execute(script, directory, "setup", self.executor.spec.setup_timeout)
        self.executor.require(result, "setup")

    def session(self, command, directory, progress=None):
        spec = self.executor.spec
        prefix = 'source /tmp/agentmill-setup.env; mkdir -p "$CODEX_HOME"; '
        if spec.agent == "codex" and spec.agent_config:
            filename = f"{spec.profile}.config.toml" if spec.profile else "config.toml"
            prefix += f'cp /native/config "$CODEX_HOME/{filename}"; '
        if spec.auth_file:
            prefix += 'cp /native/auth.json "$CODEX_HOME/auth.json"; '
        prefix += "exec " + shlex.join(command.argv) + " < " + shlex.quote(command.stdin)
        result = self.execute(prefix, directory, "native", spec.session_timeout, credentials=True,
                              progress=progress)
        native = Path(directory) / "native.jsonl"
        result.stdout.rename(native)
        result.stdout = native
        return result

    def check(self, command, directory, number):
        return self.execute("source /tmp/agentmill-setup.env;\n" + command,
                            directory, f"check-{number:02d}", self.executor.spec.check_timeout)
