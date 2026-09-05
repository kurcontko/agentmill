#!/usr/bin/python3 -I
"""Trusted container entrypoint; workers never receive runtime sudo.

The supervisor retains only Docker's explicitly granted SETUID/SETGID/KILL
capabilities. It starts the worker with empty capabilities and NNP, and accepts
two RPCs from the worker uid: run the fixed Landlock helper as the reviewer,
or invoke the fixed identity-validating reviewer controller. Root never runs
repository commands, reads reviewer environment files, or accepts caller env.
"""
from __future__ import annotations

import array
import ctypes
import json
import os
import pwd
import select
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

SOCKET_PATH = "/run/agentmill/reviewer.sock"
MAX_REQUEST = 2 * 1024 * 1024
FIXED_ENV = {"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"}


def read_exact(connection: socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        data = connection.recv(length - len(result))
        if not data:
            raise ConnectionError("incomplete reviewer request")
        result.extend(data)
    return bytes(result)


def validate_request(request: object) -> list[str]:
    if (not isinstance(request, list) or not request
            or any(not isinstance(arg, str) or "\0" in arg for arg in request)):
        raise ValueError("expected an argument vector")
    if request[0] == "control":
        if (len(request) != 6 or request[1] not in ("0", "TERM", "KILL")
                or any(not arg.isascii() or not arg.isdigit() for arg in request[2:])):
            raise ValueError("invalid controller request")
    elif request[0] != "exec":
        raise ValueError("unknown reviewer operation")
    return request


def kill_group(pid: int, sig: int) -> None:
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


def wait_confined(process: subprocess.Popen, connection: socket.socket,
                  deadline: float, grace: int) -> int:
    """Keep the leader unreaped until its descendants have been killed.

    WNOWAIT pins the PID/PGID identity during cleanup. A dead RPC client or an
    expired deadline cannot strand a reviewer, even if the worker loop crashes.
    """
    expired = False
    stopping = False
    while os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
        now = time.monotonic()
        readable, _, _ = select.select([connection], [], [], 0.05)
        disconnected = bool(readable)  # no further client messages are legal
        if not stopping and (now >= deadline or disconnected):
            expired = now >= deadline
            stopping = True
            deadline = now + grace
            kill_group(process.pid, signal.SIGTERM)
        if stopping and now >= deadline:
            kill_group(process.pid, signal.SIGKILL)
    kill_group(process.pid, signal.SIGKILL)
    status = process.wait()
    return 124 if expired else (128 - status if status < 0 else status)


class ReviewerServer:
    def __init__(self, agent: pwd.struct_passwd, reviewer: pwd.struct_passwd,
                 timeout: int, grace: int):
        self.agent, self.reviewer = agent, reviewer
        self.timeout, self.grace = timeout, grace
        self.slots = threading.BoundedSemaphore(8)
        self.executions = threading.BoundedSemaphore(2)
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        # The image owns this directory; neither uid can replace the socket.
        try:
            os.unlink(SOCKET_PATH)  # stale socket after a container restart
        except FileNotFoundError:
            pass
        self.socket.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o660)
        self.socket.listen(8)

    def handle(self, connection: socket.socket) -> None:
        descriptors: list[int] = []
        acquired = False
        process = None
        status = 125
        try:
            connection.settimeout(5)
            _, uid, _ = struct.unpack("3i", connection.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            if uid != self.agent.pw_uid:
                raise ValueError("only the worker uid may request a reviewer")
            marker, ancillary, flags, _ = connection.recvmsg(1, socket.CMSG_SPACE(12))
            for level, kind, data in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    received = array.array("i")
                    received.frombytes(data[:len(data) - len(data) % received.itemsize])
                    descriptors.extend(received)
            if marker != b"R" or flags & socket.MSG_CTRUNC or len(descriptors) != 3:
                raise ValueError("expected exactly three I/O descriptors")
            length = struct.unpack("!I", read_exact(connection, 4))[0]
            if length > MAX_REQUEST:
                raise ValueError("request too large")
            request = validate_request(json.loads(read_exact(connection, length)))
            connection.settimeout(None)
            if request[0] == "control":
                # Root output goes only to this protocol socket. Never write
                # worker-supplied descriptors while holding root privileges.
                result = subprocess.run(
                    ["/usr/bin/python3", "-I", "/usr/local/bin/agentmill-reviewer-control",
                     *request[1:]], env=FIXED_ENV, cwd="/", stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                    check=False)
                status = result.returncode
            else:
                acquired = self.executions.acquire(blocking=False)
                if not acquired:
                    raise ValueError("reviewer execution limit reached")
                # Credential dropping is done by subprocess before exec. The
                # helper loads all caller data only after this transition.
                process = subprocess.Popen(
                    ["/usr/bin/python3", "-I", "/usr/local/bin/landlock-exec", *request[1:]],
                    user=self.reviewer.pw_uid, group=self.reviewer.pw_gid, extra_groups=[],
                    env=FIXED_ENV, cwd="/", start_new_session=True,
                    stdin=descriptors[0], stdout=descriptors[1], stderr=descriptors[2])
                status = wait_confined(process, connection,
                                       time.monotonic() + self.timeout, self.grace)
        except (OSError, ValueError, subprocess.SubprocessError):
            status = 125
        finally:
            if process is not None and process.returncode is None:
                kill_group(process.pid, signal.SIGKILL)
                process.wait()
            for descriptor in descriptors:
                os.close(descriptor)
            if acquired:
                self.executions.release()
            try:
                connection.sendall(struct.pack("!I", status if status >= 0 else 125))
            except OSError:
                pass
            connection.close()
            self.slots.release()

    def serve(self) -> None:
        while True:
            connection, _ = self.socket.accept()
            if not self.slots.acquire(blocking=False):
                connection.close()
                continue
            threading.Thread(target=self.handle, args=(connection,), daemon=True).start()


def main() -> int:
    if os.geteuid() != 0:
        raise RuntimeError("container entrypoint must start as root to drop credentials")
    worker_env = dict(os.environ)
    timeout = int(worker_env.get("ITER_TIMEOUT", "3600"))
    grace = int(worker_env.get("SHUTDOWN_GRACE", "30"))
    if timeout <= 0 or grace < 0:
        raise ValueError("invalid timeout or shutdown grace")
    agent, reviewer = pwd.getpwnam("agent"), pwd.getpwnam("agentmill-reviewer")
    os.environ.clear()
    os.environ.update(FIXED_ENV)
    # NNP is inherited by both uids, including when launched outside mill.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(38, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "cannot set no-new-privileges")
    # The image directory has setgid and the worker group, so the socket gets
    # that group without requiring CAP_CHOWN at runtime.
    server = ReviewerServer(agent, reviewer, timeout, grace)
    threading.Thread(target=server.serve, daemon=True).start()
    worker_env.setdefault("HOME", agent.pw_dir)
    command = sys.argv[1:] or ["/loop.sh"]
    worker = subprocess.Popen(command, user=agent.pw_uid, group=agent.pw_gid,
                              extra_groups=[], env=worker_env)
    def forward(signum: int, _frame: object) -> None:
        if worker.poll() is None:
            worker.send_signal(signum)
    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    status = worker.wait()
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    raise SystemExit(main())
