#!/usr/bin/env python3
"""Focused integration checks for landlock_exec.py (Linux only)."""

from __future__ import annotations

import os
from pathlib import Path
import platform
import json
import signal
import subprocess
import sys
import tempfile
import time


REPO_ROOT = Path(__file__).resolve().parent.parent
WRAPPER = Path(os.environ.get("LANDLOCK_EXEC", REPO_ROOT / "landlock_exec.py"))
RUN_AS = os.environ.get("LANDLOCK_RUN_AS")


def run_sandboxed(
    write_root: Path,
    program: str,
    *arguments: object,
    devices: tuple[str, ...] = (),
    allow_metadata: bool = False,
    environment_file: Path | None = None,
    max_processes: int | None = None,
    state_file: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    command: list[str] = []
    if RUN_AS:
        command.extend(("sudo", "-n", "-E", "-u", RUN_AS))
    command.extend([
        sys.executable,
        "-I",
        str(WRAPPER),
        "--write-root",
        str(write_root),
    ])
    if allow_metadata:
        command.append("--allow-metadata")
    if environment_file is not None:
        command.extend(("--environment-file", str(environment_file)))
    if max_processes is not None:
        command.extend(("--max-processes", str(max_processes)))
    for device in devices:
        command.extend(("--allow-device", device))
    if state_file is not None:
        ack_file = write_root / ".session-ack"
        ack_file.write_text("ready\n")
        command.extend(
            (
                "--session-state",
                str(state_file),
                "--session-ack",
                str(ack_file),
            )
        )
    command.extend(("--", sys.executable, "-c", program))
    command.extend(str(argument) for argument in arguments)
    return subprocess.run(command, text=True, capture_output=True, check=False)


def require_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0:
        raise AssertionError(
            f"{label} failed with {result.returncode}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )


def main() -> int:
    if platform.system() != "Linux":
        print("SKIP: Landlock integration test requires Linux")
        return 0

    with tempfile.TemporaryDirectory(prefix="agentmill-landlock-test.") as temporary:
        base = Path(temporary)
        allowed = base / "allowed"
        outside = base / "outside"
        allowed.mkdir()
        outside.mkdir()
        if RUN_AS:
            # Production prepares the agent-owned clone this way before
            # dropping the evaluator to its independent uid.
            base.chmod(0o755)
            allowed.chmod(0o777)

        result = run_sandboxed(
            allowed,
            "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('ok')",
            allowed / "inside",
        )
        require_success(result, "write below allowed root")
        assert (allowed / "inside").read_text() == "ok"

        reviewer_environment = allowed / "reviewer-environment.json"
        reviewer_environment.write_text(
            json.dumps({"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "ONLY_FIXED": "yes"})
        )
        result = run_sandboxed(
            allowed,
            """
import os, resource
if os.environ != {"PATH": os.environ["PATH"], "ONLY_FIXED": "yes", "LC_CTYPE": "C.UTF-8"}:
    # Python may add LC_CTYPE while coercing the C locale; reject every other
    # inherited variable, especially BASH_ENV and loader/runtime controls.
    unexpected = sorted(set(os.environ) - {"PATH", "ONLY_FIXED", "LC_CTYPE"})
    if unexpected:
        raise SystemExit(f"unexpected inherited environment: {unexpected}")
if os.environ.get("ONLY_FIXED") != "yes":
    raise SystemExit("fixed reviewer environment missing")
soft, hard = resource.getrlimit(resource.RLIMIT_NPROC)
if (soft, hard) != (64, 64):
    raise SystemExit(f"wrong process limit: {(soft, hard)}")
""",
            environment_file=reviewer_environment,
            max_processes=64,
        )
        require_success(result, "replace environment and cap reviewer processes")

        session_state = allowed / "session-state"
        result = run_sandboxed(
            allowed,
            """
import os, sys
pid, pgid, pid_start, pg_start = map(
    int, open(sys.argv[1], encoding="ascii").read().split()
)
if (pid, pgid) != (os.getpid(), os.getpgrp()) or pid_start <= 0 or pg_start < 0:
    raise SystemExit(f"wrong session state: {(pid, pgid, pid_start, pg_start)}")
""",
            session_state,
            state_file=session_state,
        )
        require_success(result, "publish reviewer PID/PGID handshake")

        # The helper must not exec untrusted reviewer code until the parent has
        # copied that handshake to its Landlock-protected state file.
        dynamic_state = allowed / "dynamic-session-state"
        dynamic_ack = allowed / "dynamic-session-ack"
        dynamic_marker = allowed / "dynamic-command-ran"
        dynamic_ack.write_text("")
        command: list[str] = []
        if RUN_AS:
            command.extend(("sudo", "-n", "-E", "-u", RUN_AS))
        command.extend(
            (
                sys.executable,
                "-I",
                str(WRAPPER),
                "--write-root",
                str(allowed),
                "--session-state",
                str(dynamic_state),
                "--session-ack",
                str(dynamic_ack),
                "--",
                sys.executable,
                "-c",
                "from pathlib import Path; import sys; Path(sys.argv[1]).touch()",
                str(dynamic_marker),
            )
        )
        process = subprocess.Popen(
            command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        for _ in range(500):
            if dynamic_state.stat().st_size if dynamic_state.exists() else 0:
                break
            time.sleep(0.01)
        assert dynamic_state.exists() and dynamic_state.stat().st_size
        assert not dynamic_marker.exists(), "reviewer ran before PID/PGID acknowledgment"
        dynamic_ack.write_text("ready\n")
        stdout, stderr = process.communicate(timeout=10)
        if process.returncode != 0:
            raise AssertionError(
                f"dynamic session handshake failed with {process.returncode}\n"
                f"stdout: {stdout}\nstderr: {stderr}"
            )
        assert dynamic_marker.exists(), "acknowledged reviewer command did not run"

        outside_file = outside / "unchanged"
        outside_file.write_text("ORIGINAL")
        result = run_sandboxed(
            allowed,
            """
from pathlib import Path
import sys
try:
    Path(sys.argv[1]).write_text("CHANGED")
except OSError:
    raise SystemExit(0)
raise SystemExit("outside write unexpectedly succeeded")
""",
            outside_file,
        )
        require_success(result, "deny absolute outside write")
        assert outside_file.read_text() == "ORIGINAL"

        (allowed / "escape").symlink_to(outside, target_is_directory=True)
        result = run_sandboxed(
            allowed,
            """
from pathlib import Path
import sys
try:
    Path(sys.argv[1]).write_text("escaped")
except OSError:
    raise SystemExit(0)
raise SystemExit("escaping-symlink write unexpectedly succeeded")
""",
            allowed / "escape" / "escaped",
        )
        require_success(result, "deny write through escaping symlink")
        assert not (outside / "escaped").exists()

        result = run_sandboxed(
            allowed,
            """
import os, sys
try:
    os.unlink(sys.argv[1])
except OSError:
    raise SystemExit(0)
raise SystemExit("outside removal unexpectedly succeeded")
""",
            outside_file,
        )
        require_success(result, "deny outside removal")
        assert outside_file.read_text() == "ORIGINAL"

        # Landlock intentionally does not mediate these inode metadata
        # operations.  The seccomp layer must deny them even in the normal
        # same-uid test, where DAC alone would allow every operation below.
        outside_file.chmod(0o644)
        os.utime(
            outside_file,
            ns=(1_600_000_000_123_456_789, 1_600_000_001_987_654_321),
        )
        original_stat = outside_file.stat()
        result = run_sandboxed(
            allowed,
            """
import errno, os, sys

path = sys.argv[1]
fd = os.open(path, os.O_RDONLY)
try:
    operations = (
        ("chmod", lambda: os.chmod(path, 0o755)),
        ("fchmod", lambda: os.fchmod(fd, 0o755)),
        ("chown", lambda: os.chown(path, -1, os.getgid())),
        ("fchown", lambda: os.fchown(fd, -1, os.getgid())),
        ("utime", lambda: os.utime(path, ns=(1700000000000000000, 1700000000000000000))),
        ("futime", lambda: os.utime(fd, ns=(1700000000000000000, 1700000000000000000))),
        ("setxattr", lambda: os.setxattr(path, b"user.agentmill_seccomp", b"changed")),
        ("fsetxattr", lambda: os.setxattr(fd, b"user.agentmill_seccomp", b"changed")),
        ("removexattr", lambda: os.removexattr(path, b"user.agentmill_seccomp")),
        ("fremovexattr", lambda: os.removexattr(fd, b"user.agentmill_seccomp")),
    )
    for name, operation in operations:
        try:
            operation()
        except OSError as exc:
            if exc.errno != errno.EPERM:
                raise SystemExit(f"{name} returned errno {exc.errno}, expected EPERM")
        else:
            raise SystemExit(f"outside {name} unexpectedly succeeded")
finally:
    os.close(fd)
""",
            outside_file,
        )
        require_success(result, "deny outside metadata changes")
        after_stat = outside_file.stat()
        assert after_stat.st_mode == original_stat.st_mode
        assert after_stat.st_uid == original_stat.st_uid
        assert after_stat.st_gid == original_stat.st_gid
        assert after_stat.st_mtime_ns == original_stat.st_mtime_ns

        # Seccomp cannot make path-based exceptions.  This is a deliberate
        # evaluator tradeoff: content/build writes work in the disposable
        # checkout, but chmod/chown/timestamp/xattr changes do not.
        inside_file = allowed / "metadata-inside"
        inside_file.write_text("inside")
        original_inside_mode = inside_file.stat().st_mode
        result = run_sandboxed(
            allowed,
            """
import errno, os, sys
try:
    os.chmod(sys.argv[1], 0o700)
except OSError as exc:
    if exc.errno == errno.EPERM:
        raise SystemExit(0)
    raise SystemExit(f"inside chmod returned errno {exc.errno}, expected EPERM")
raise SystemExit("inside chmod unexpectedly succeeded")
""",
            inside_file,
        )
        require_success(result, "deny metadata changes inside write root")
        assert inside_file.stat().st_mode == original_inside_mode

        # Setup commands may opt into metadata operations while Landlock still
        # confines their content writes.  Create the file in the sandbox so it
        # is owned by RUN_AS when the cross-uid integration mode is active.
        metadata_allowed_file = allowed / "metadata-allowed"
        result = run_sandboxed(
            allowed,
            """
import os, sys
from pathlib import Path

inside = Path(sys.argv[1])
outside = Path(sys.argv[2])
inside.write_text("inside")
os.chmod(inside, 0o700)
try:
    outside.write_text("CHANGED")
except OSError:
    pass
else:
    raise SystemExit("outside write unexpectedly succeeded with --allow-metadata")
""",
            metadata_allowed_file,
            outside_file,
            allow_metadata=True,
        )
        require_success(result, "allow in-root metadata but deny outside content write")
        assert metadata_allowed_file.stat().st_mode & 0o777 == 0o700
        assert outside_file.read_text() == "ORIGINAL"

        # io_uring has xattr operations that bypass per-syscall-number checks,
        # so all three ring entry points are denied after inherited FDs close.
        result = run_sandboxed(
            allowed,
            """
import ctypes, errno
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
for number in (425, 426, 427):
    ctypes.set_errno(0)
    result = libc.syscall(ctypes.c_long(number), *(ctypes.c_ulong(0),) * 6)
    if result != -1 or ctypes.get_errno() != errno.EPERM:
        raise SystemExit(
            f"io_uring syscall {number} was not denied: "
            f"result={result} errno={ctypes.get_errno()}"
        )
""",
        )
        require_success(result, "deny io_uring metadata bypass")

        # Every evaluator descendant must remain in the published process
        # group so the cross-uid shutdown path can reach it. Codex expects a
        # successful setsid result before each verifier command, so seccomp
        # skips both group-changing syscalls but reports raw success (zero).
        result = run_sandboxed(
            allowed,
            """
import ctypes, os, platform, signal

machine = platform.machine().lower()
if machine == "x86_64":
    setpgid_number, setsid_number, seccomp_number = 109, 112, 317
elif machine in {"aarch64", "arm64"}:
    setpgid_number, setsid_number, seccomp_number = 154, 157, 277
else:
    raise SystemExit(f"unsupported architecture in group test: {machine}")

libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long

# Codex sets a parent-death signal on verifier children. The outer filter must
# leave ordinary prctl operations available while still preventing later
# seccomp filters from relaxing Agent Mill's process-group containment.
libc.prctl.restype = ctypes.c_int
if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:  # PR_SET_PDEATHSIG
    raise SystemExit(f"PR_SET_PDEATHSIG failed: errno={ctypes.get_errno()}")
death_signal = ctypes.c_int()
if libc.prctl(2, ctypes.byref(death_signal), 0, 0, 0) != 0:  # PR_GET_PDEATHSIG
    raise SystemExit(f"PR_GET_PDEATHSIG failed: errno={ctypes.get_errno()}")
if death_signal.value != signal.SIGTERM:
    raise SystemExit(f"wrong parent-death signal: {death_signal.value}")

original_group = os.getpgrp()
ctypes.set_errno(0)
group_result = libc.syscall(
    ctypes.c_long(setpgid_number), ctypes.c_long(0), ctypes.c_long(0)
)
if group_result != 0 or ctypes.get_errno() != 0:
    raise SystemExit(
        f"setpgid was not emulated as success: result={group_result} "
        f"errno={ctypes.get_errno()}"
    )
if os.getpgrp() != original_group:
    raise SystemExit("setpgid emulation changed the reviewer process group")

child = os.fork()
if child == 0:
    original_identity = (os.getpgrp(), os.getsid(0))
    ctypes.set_errno(0)
    session_result = libc.syscall(ctypes.c_long(setsid_number))
    current_identity = (os.getpgrp(), os.getsid(0))
    os._exit(
        0
        if session_result == 0
        and ctypes.get_errno() == 0
        and current_identity == original_identity
        else 3
    )
_, status = os.waitpid(child, 0)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    raise SystemExit(f"setsid child escaped or lacked synthetic success: status={status}")

# Codex adds a restricted-network seccomp filter to verifier children. Stacked
# filters must remain available, and even a newer allow-all filter cannot relax
# Agent Mill's stronger synthetic-success action.
class SockFilter(ctypes.Structure):
    _fields_ = [
        ("code", ctypes.c_uint16),
        ("jt", ctypes.c_uint8),
        ("jf", ctypes.c_uint8),
        ("k", ctypes.c_uint32),
    ]


class SockFprog(ctypes.Structure):
    _fields_ = [
        ("length", ctypes.c_uint16),
        ("filters", ctypes.POINTER(SockFilter)),
    ]


allow_instruction = SockFilter(0x06, 0, 0, 0x7FFF0000)
allow_program = SockFprog(1, ctypes.pointer(allow_instruction))
ctypes.set_errno(0)
filter_result = libc.syscall(
    ctypes.c_long(seccomp_number),
    ctypes.c_uint(1),
    ctypes.c_uint(0),
    ctypes.byref(allow_program),
)
if filter_result != 0 or ctypes.get_errno() != 0:
    raise SystemExit(
        f"could not stack Codex-style seccomp filter: result={filter_result} "
        f"errno={ctypes.get_errno()}"
    )
ctypes.set_errno(0)
stacked_result = libc.syscall(
    ctypes.c_long(setpgid_number), ctypes.c_long(0), ctypes.c_long(0)
)
if stacked_result != 0 or ctypes.get_errno() != 0 or os.getpgrp() != original_group:
    raise SystemExit("stacked filter relaxed or perturbed group containment")
""",
        )
        require_success(result, "emulate CLI group setup without reviewer escape")

        # Same-uid process-injection interfaces could alter an unrestricted
        # ancestor or borrow one of its descriptors, bypassing path confinement.
        result = run_sandboxed(
            allowed,
            """
import ctypes, errno, platform

machine = platform.machine().lower()
if machine == "x86_64":
    syscalls = {
        "ptrace": 101,
        "process_vm_readv": 310,
        "process_vm_writev": 311,
        "pidfd_getfd": 438,
    }
elif machine in {"aarch64", "arm64"}:
    syscalls = {
        "ptrace": 117,
        "process_vm_readv": 270,
        "process_vm_writev": 271,
        "pidfd_getfd": 438,
    }
else:
    raise SystemExit(f"unsupported architecture in injection test: {machine}")

libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
for name, number in syscalls.items():
    ctypes.set_errno(0)
    syscall_result = libc.syscall(
        ctypes.c_long(number), *(ctypes.c_ulong(0),) * 6
    )
    if syscall_result != -1 or ctypes.get_errno() != errno.EPERM:
        raise SystemExit(
            f"{name} was not denied: "
            f"result={syscall_result} errno={ctypes.get_errno()}"
        )
""",
        )
        require_success(result, "deny process-injection syscalls")

        # Filesystem ioctl families expose many persistent metadata mutators
        # (flags, project IDs, verity, fscrypt, and filesystem-specific state).
        # They stay denied even though a few harmless pipe/terminal requests
        # are admitted for the real agent CLIs.
        result = run_sandboxed(
            allowed,
            """
import errno, fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    try:
        # FS_IOC_SETFLAGS (native 64-bit encoding).  Seccomp rejects the ioctl
        # before the kernel interprets either the request or its argument.
        fcntl.ioctl(fd, 0x40086602, bytes(8))
    except OSError as exc:
        if exc.errno == errno.EPERM:
            raise SystemExit(0)
        raise SystemExit(f"ioctl returned errno {exc.errno}, expected EPERM")
    raise SystemExit("metadata ioctl unexpectedly succeeded")
finally:
    os.close(fd)
""",
            outside_file,
        )
        require_success(result, "deny filesystem metadata ioctl")

        # Codex marks subprocess pipes nonblocking and queries their queued
        # bytes.  These descriptor-only requests must work while an unknown
        # request remains fail-closed.
        result = run_sandboxed(
            allowed,
            """
import array, errno, fcntl, os

read_fd, write_fd = os.pipe()
try:
    enabled = array.array("i", [1])
    fcntl.ioctl(read_fd, 0x5421, enabled, True)  # FIONBIO
    os.write(write_fd, b"abc")
    queued = array.array("i", [0])
    fcntl.ioctl(read_fd, 0x541B, queued, True)  # FIONREAD
    if queued[0] != 3:
        raise SystemExit(f"unexpected queued-byte count: {queued[0]}")
    try:
        fcntl.ioctl(read_fd, 0xDEADBEEF, bytes(8))
    except OSError as exc:
        if exc.errno != errno.EPERM:
            raise SystemExit(f"unknown ioctl returned errno {exc.errno}")
    else:
        raise SystemExit("unknown ioctl unexpectedly passed")
finally:
    os.close(read_fd)
    os.close(write_fd)
""",
        )
        require_success(result, "allow only harmless descriptor ioctl requests")

        # Ioctl filtering must not interfere with the pipe-based evaluator
        # protocol or ordinary child execution.  Both are inherited by exec.
        result = run_sandboxed(
            allowed,
            """
import subprocess, sys
print("stdout-ok", flush=True)
print("stderr-ok", file=sys.stderr, flush=True)
child = subprocess.run(
    [sys.executable, "-c", "print('child-ok')"],
    text=True,
    capture_output=True,
    check=False,
)
if child.returncode != 0 or child.stdout.strip() != "child-ok":
    raise SystemExit(f"child execution failed: {child!r}")
""",
        )
        require_success(result, "noninteractive command smoke with filtered ioctl")
        assert result.stdout.strip() == "stdout-ok"
        assert result.stderr.strip() == "stderr-ok"

        # x32 shares AUDIT_ARCH_X86_64 but sets a high bit in syscall numbers.
        # The sandbox must kill such calls rather than interpret them using the
        # native allowlist.  (sudo may mediate child status in RUN_AS mode.)
        if platform.machine().lower() == "x86_64" and not RUN_AS:
            result = run_sandboxed(
                allowed,
                """
import ctypes
ctypes.CDLL(None).syscall(ctypes.c_long(0x40000000 | 39))
raise SystemExit("x32 syscall unexpectedly returned")
""",
            )
            assert result.returncode in {
                -signal.SIGSYS,
                128 + signal.SIGSYS,
            }, result

        move_source = allowed / "move-source"
        move_source.write_text("move")
        move_destination = outside / "move-destination"
        result = run_sandboxed(
            allowed,
            """
import os, sys
try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError:
    raise SystemExit(0)
raise SystemExit("cross-boundary rename unexpectedly succeeded")
""",
            move_source,
            move_destination,
        )
        require_success(result, "deny cross-boundary REFER")
        assert move_source.read_text() == "move"
        assert not move_destination.exists()

        result = run_sandboxed(
            allowed,
            """
try:
    open("/dev/null", "wb").close()
except OSError:
    raise SystemExit(0)
raise SystemExit("unlisted device write unexpectedly succeeded")
""",
        )
        require_success(result, "deny unlisted device")

        result = run_sandboxed(
            allowed,
            'open("/dev/null", "wb").write(b"ok")',
            devices=("/dev/null",),
        )
        require_success(result, "allow explicitly listed /dev/null")

        marker = allowed / "must-not-run"
        result = run_sandboxed(
            allowed,
            "from pathlib import Path; import sys; Path(sys.argv[1]).touch()",
            marker,
            devices=(str(outside_file),),
        )
        assert result.returncode == 125, result
        assert not marker.exists(), "command ran after invalid device setup"

        outside_state = outside / "session-state"
        result = run_sandboxed(
            allowed,
            "from pathlib import Path; import sys; Path(sys.argv[1]).touch()",
            marker,
            state_file=outside_state,
        )
        assert result.returncode == 125, result
        assert not outside_state.exists(), "outside session-state file was created"
        assert not marker.exists(), "command ran after invalid session-state setup"

    if expected_uid := os.environ.get("EXPECTED_AGENT_UID"):
        assert os.getuid() == int(expected_uid)
        assert Path("/workspace").stat().st_uid == int(expected_uid)
    if expected_gid := os.environ.get("EXPECTED_AGENT_GID"):
        assert os.getgid() == int(expected_gid)
        assert Path("/workspace").stat().st_gid == int(expected_gid)

    suffix = " with reviewer uid" if RUN_AS else " at the caller uid"
    print(f"PASS: Landlock plus seccomp confine mutations{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
