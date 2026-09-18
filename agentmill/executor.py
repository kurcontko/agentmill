"""One process supervisor and one Docker execution path."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time
import uuid

from .contracts import ProcessOutput, RunStopped


class Executor:
    def __init__(self, spec, directory):
        self.spec = spec
        self.directory = Path(directory)
        self.deadline = time.monotonic() + spec.max_duration
        self.finalize_deadline = None
        self.cancelled = 0
        self.image = spec.image
        self.operation = 0
        self.worker_stopped = True

    def cancel(self, signum, _frame=None):
        self.cancelled = self.cancelled or signum

    def finalize(self):
        if self.finalize_deadline is None:
            self.finalize_deadline = time.monotonic() + 30

    def guard(self):
        if self.cancelled:
            raise RunStopped("cancelled", 128 + self.cancelled)
        if time.monotonic() >= self.deadline:
            raise RunStopped("run_duration_limit", 2)

    @staticmethod
    def kill_group(process, sig):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass

    def command(self, argv, stdout, stderr, timeout, *, stdin=None, env=None, maintenance=False, cwd=None):
        start = time.monotonic()
        phase_deadline = start + timeout
        deadline = min(phase_deadline, (self.finalize_deadline or phase_deadline)
                       if maintenance else self.deadline)
        reason = None
        process = None
        stdout, stderr = Path(stdout), Path(stderr)
        stdout.parent.mkdir(parents=True, exist_ok=True)
        if not maintenance:
            self.guard()
        with stdout.open("wb") as out, stderr.open("wb") as err:
            input_stream = open(stdin, "rb") if stdin else None
            try:
                process = subprocess.Popen(argv, stdin=input_stream or subprocess.DEVNULL,
                                           stdout=out, stderr=err, env=env, cwd=cwd, start_new_session=True)
                while process.poll() is None:
                    if self.cancelled and not maintenance:
                        reason = "cancelled"
                        break
                    if time.monotonic() >= deadline:
                        reason = "run_duration_limit" if not maintenance and self.deadline <= phase_deadline else "timeout"
                        break
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
        if reason and not maintenance:
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
        self.require(output, "runtime")
        return output.stdout.read_bytes()

    def inspect_image(self):
        data = json.loads(self.control(["docker", "image", "inspect", self.spec.image]))
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
        if worker:
            for field, target in (("agent_config", "/native/config"), ("auth_file", "/native/auth.json")):
                path = getattr(self.spec, field)
                if path:
                    if not Path(path).is_file():
                        raise ValueError(f"{field} must be a regular file")
                    argv += self.mount(path, target, True)
        argv += ["--entrypoint", "sleep", self.image, "infinity"]
        attempted = False
        try:
            attempted = True
            if worker:
                self.worker_stopped = False
            self.control(argv)
            self.control(["docker", "start", name])
            yield Container(self, name)
        finally:
            if attempted:
                # Never merely kill docker exec: the daemon owns the worker processes.
                stopped = self._remove_container(name)
                if worker:
                    self.worker_stopped = stopped
                if not stopped:
                    raise RunStopped("container_cleanup_failed")

    def _remove_container(self, name):
        if self.cancelled or time.monotonic() >= self.deadline:
            self.finalize()
        folder = self.directory / "operations"
        self.command(["docker", "stop", "--time", "2", name], folder / f"{name}-stop.log",
                     folder / f"{name}-stop.stderr.log", 5, maintenance=True)
        self.command(["docker", "rm", "--force", name], folder / f"{name}-rm.log",
                     folder / f"{name}-rm.stderr.log", 5, maintenance=True)
        # Listing requires a healthy daemon. A failed inspect alone could mean an outage.
        try:
            remaining = self.control(["docker", "ps", "-aq", "--filter", f"name=^/{name}$"],
                                     timeout=5, maintenance=True)
            return not remaining.strip()
        except (OSError, RunStopped):
            return False


class Container:
    def __init__(self, executor, name):
        self.executor = executor
        self.name = name

    def execute(self, script, directory, label, timeout, *, credentials=False):
        directory = Path(directory)
        argv = ["docker", "exec"]
        if credentials:
            for name in self.executor.spec.credential_env:
                if name in os.environ:
                    argv += ["--env", name]
        argv += [self.name, "bash", "-ec", script]
        return self.executor.command(argv, directory / f"{label}.log",
                                     directory / f"{label}.stderr.log", timeout)

    def setup(self, directory):
        script = ("mkdir -p \"$HOME\" /scratch; export -p > /tmp/agentmill-setup.env;\n" + self.executor.spec.setup +
                  "\nexport -p > /tmp/agentmill-setup.env")
        result = self.execute(script, directory, "setup", self.executor.spec.setup_timeout)
        self.executor.require(result, "setup")

    def session(self, command, directory):
        spec = self.executor.spec
        prefix = 'source /tmp/agentmill-setup.env; mkdir -p "$CODEX_HOME"; '
        if spec.agent == "codex" and spec.agent_config:
            filename = f"{spec.profile}.config.toml" if spec.profile else "config.toml"
            prefix += f'cp /native/config "$CODEX_HOME/{filename}"; '
        if spec.auth_file:
            prefix += 'cp /native/auth.json "$CODEX_HOME/auth.json"; '
        prefix += "exec " + shlex.join(command.argv) + " < " + shlex.quote(command.stdin)
        result = self.execute(prefix, directory, "native", spec.session_timeout, credentials=True)
        native = Path(directory) / "native.jsonl"
        result.stdout.rename(native)
        result.stdout = native
        return result

    def check(self, command, directory, number):
        return self.execute("source /tmp/agentmill-setup.env;\n" + command,
                            directory, f"check-{number:02d}", self.executor.spec.check_timeout)
