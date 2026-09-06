#!/usr/bin/env python3
"""Run a command with writes confined by Landlock and seccomp.

Usage:
    landlock-exec --write-root DIR [--allow-device CHARDEV ...]
                  [--allow-metadata]
                  [--environment-file JSON] [--max-processes N]
                  [--session-state FILE --session-ack FILE]
                  -- COMMAND [ARG ...]

The command may perform every Landlock-mediated filesystem mutation beneath
DIR.  Everywhere else those mutations are denied.  A seccomp filter also
denies metadata-changing chmod, chown, timestamp, and xattr system calls in all
locations because Landlock does not mediate them.  Ioctl is default-denied with
a small allowlist for harmless descriptor and terminal queries needed by the
agent CLI; filesystem-specific requests remain unavailable.  It also prevents
descendants from leaving the recorded reviewer process group.  Each
--allow-device grants write access to exactly one character device, for example
/dev/null.  Standard input/output/error remain inherited.

Setup errors exit 125 and never run COMMAND.  Landlock ABI 3 is the minimum so
that WRITE, creation/removal, REFER (rename/link), and TRUNCATE are all handled.
The wrapper supports Agent Mill's published linux/amd64 and linux/arm64 image
targets; an unknown architecture is rejected rather than weakly sandboxed.

--allow-metadata is reserved for setup commands run as a separate uid that
does not own files outside DIR.  It permits chmod/chown/timestamp/xattr calls
needed while initializing the disposable Git snapshot, while Landlock still confines file data
writes and seccomp still blocks non-allowlisted ioctl requests, process
injection, process-group escape, and io_uring.
"""

from __future__ import annotations

import ctypes
import errno
import json
import os
import platform
import resource
import stat
import sys
import time
from dataclasses import dataclass
from typing import NoReturn, Sequence


# linux/landlock.h.  Keep these numeric constants here so the wrapper remains
# usable in minimal images without kernel headers or third-party packages.
LANDLOCK_CREATE_RULESET_VERSION = 1 << 0
LANDLOCK_RULE_PATH_BENEATH = 1

LANDLOCK_ACCESS_FS_EXECUTE = 1 << 0
LANDLOCK_ACCESS_FS_WRITE_FILE = 1 << 1
LANDLOCK_ACCESS_FS_READ_FILE = 1 << 2
LANDLOCK_ACCESS_FS_READ_DIR = 1 << 3
LANDLOCK_ACCESS_FS_REMOVE_DIR = 1 << 4
LANDLOCK_ACCESS_FS_REMOVE_FILE = 1 << 5
LANDLOCK_ACCESS_FS_MAKE_CHAR = 1 << 6
LANDLOCK_ACCESS_FS_MAKE_DIR = 1 << 7
LANDLOCK_ACCESS_FS_MAKE_REG = 1 << 8
LANDLOCK_ACCESS_FS_MAKE_SOCK = 1 << 9
LANDLOCK_ACCESS_FS_MAKE_FIFO = 1 << 10
LANDLOCK_ACCESS_FS_MAKE_BLOCK = 1 << 11
LANDLOCK_ACCESS_FS_MAKE_SYM = 1 << 12
LANDLOCK_ACCESS_FS_REFER = 1 << 13  # ABI 2
LANDLOCK_ACCESS_FS_TRUNCATE = 1 << 14  # ABI 3
LANDLOCK_ACCESS_FS_IOCTL_DEV = 1 << 15  # ABI 5

PR_SET_NO_NEW_PRIVS = 38
SECCOMP_SET_MODE_FILTER = 1
UINT_MAX = (1 << 32) - 1

# linux/audit.h architecture tags used by struct seccomp_data.  Seccomp filters
# must validate this field before interpreting syscall numbers: in particular,
# x86-64 and its x32 ABI share an audit architecture tag.
AUDIT_ARCH_X86_64 = 0xC000003E
AUDIT_ARCH_AARCH64 = 0xC00000B7
X32_SYSCALL_BIT = 0x40000000

# linux/filter.h classic BPF instructions.
BPF_LD_W_ABS = 0x20
BPF_JMP_JEQ_K = 0x15
BPF_JMP_JSET_K = 0x45
BPF_RET_K = 0x06

# linux/seccomp.h return values and struct seccomp_data field offsets.
SECCOMP_RET_KILL_PROCESS = 0x80000000
SECCOMP_RET_ERRNO = 0x00050000
SECCOMP_RET_ALLOW = 0x7FFF0000
SECCOMP_DATA_NR_OFFSET = 0
SECCOMP_DATA_ARCH_OFFSET = 4
SECCOMP_DATA_ARG1_LOW_OFFSET = 24
SECCOMP_RET_DATA_MASK = 0x0000FFFF

# ioctl request numbers are UAPI constants shared by the supported 64-bit
# little-endian architectures.  Codex uses these on pipes, sockets, and its
# noninteractive stdio while spawning subprocesses.  None can persistently
# mutate a filesystem object; every other ioctl request is rejected.
_ALLOWED_IOCTL_REQUESTS = (
    0x5401,  # TCGETS: read terminal attributes
    0x5413,  # TIOCGWINSZ: read terminal window size
    0x541B,  # FIONREAD: read queued byte count
    0x5421,  # FIONBIO: toggle nonblocking on an open file description
    0x5450,  # FIONCLEX: clear close-on-exec on one descriptor
    0x5451,  # FIOCLEX: set close-on-exec on one descriptor
)

# The explicit lists make the security boundary auditable without depending on
# headers in the minimal runtime image.  New syscalls use the shared numbering
# space, but older metadata interfaces differ between x86-64 and asm-generic
# architectures such as AArch64.
_X86_64_METADATA_SYSCALLS = {
    "chmod": 90,
    "fchmod": 91,
    "chown": 92,
    "fchown": 93,
    "lchown": 94,
    "utime": 132,
    "setxattr": 188,
    "lsetxattr": 189,
    "fsetxattr": 190,
    "removexattr": 197,
    "lremovexattr": 198,
    "fremovexattr": 199,
    "utimes": 235,
    "fchownat": 260,
    "futimesat": 261,
    "fchmodat": 268,
    "utimensat": 280,
    "fchmodat2": 452,
    "setxattrat": 463,
    "removexattrat": 466,
}

_AARCH64_METADATA_SYSCALLS = {
    "setxattr": 5,
    "lsetxattr": 6,
    "fsetxattr": 7,
    "removexattr": 14,
    "lremovexattr": 15,
    "fremovexattr": 16,
    "fchmod": 52,
    "fchmodat": 53,
    "fchownat": 54,
    "fchown": 55,
    "utimensat": 88,
    "fchmodat2": 452,
    "setxattrat": 463,
    "removexattrat": 466,
}

# io_uring offers SETXATTR and FSETXATTR operations whose individual operation
# numbers are invisible to seccomp.  No ring can be inherited because all
# non-standard descriptors are closed before this filter is installed, so
# blocking these entry points closes that alternate metadata path.
_IO_URING_SYSCALLS = (425, 426, 427)  # setup, enter, register
_X86_64_PROCESS_GROUP_SYSCALLS = (109, 112)  # setpgid, setsid
_AARCH64_PROCESS_GROUP_SYSCALLS = (154, 157)  # setpgid, setsid
# ptrace, process_vm_readv/writev, and pidfd_getfd could manipulate or borrow
# descriptors from a same-uid ancestor that installed no Landlock domain.
_X86_64_PROCESS_INJECTION_SYSCALLS = (101, 310, 311, 438)
_AARCH64_PROCESS_INJECTION_SYSCALLS = (117, 270, 271, 438)

_BASE_MUTATION_ACCESS = (
    LANDLOCK_ACCESS_FS_WRITE_FILE
    | LANDLOCK_ACCESS_FS_REMOVE_DIR
    | LANDLOCK_ACCESS_FS_REMOVE_FILE
    | LANDLOCK_ACCESS_FS_MAKE_CHAR
    | LANDLOCK_ACCESS_FS_MAKE_DIR
    | LANDLOCK_ACCESS_FS_MAKE_REG
    | LANDLOCK_ACCESS_FS_MAKE_SOCK
    | LANDLOCK_ACCESS_FS_MAKE_FIFO
    | LANDLOCK_ACCESS_FS_MAKE_BLOCK
    | LANDLOCK_ACCESS_FS_MAKE_SYM
    | LANDLOCK_ACCESS_FS_REFER
    | LANDLOCK_ACCESS_FS_TRUNCATE
)


class _RulesetAttr(ctypes.Structure):
    _fields_ = [("handled_access_fs", ctypes.c_uint64)]


class _PathBeneathAttr(ctypes.Structure):
    _fields_ = [
        ("allowed_access", ctypes.c_uint64),
        ("parent_fd", ctypes.c_int32),
    ]


class _SockFilter(ctypes.Structure):
    _fields_ = [
        ("code", ctypes.c_uint16),
        ("jt", ctypes.c_uint8),
        ("jf", ctypes.c_uint8),
        ("k", ctypes.c_uint32),
    ]


class _SockFprog(ctypes.Structure):
    _fields_ = [
        ("length", ctypes.c_uint16),
        ("filters", ctypes.POINTER(_SockFilter)),
    ]


class UsageError(Exception):
    """Invalid command-line invocation."""


class SetupError(Exception):
    """The sandbox could not be installed safely."""


@dataclass(frozen=True)
class _Syscalls:
    close_range: int
    create_ruleset: int
    add_rule: int
    restrict_self: int
    seccomp: int
    ioctl: int
    audit_arch: int
    metadata_mutations: tuple[int, ...]
    process_group_changes: tuple[int, ...]
    process_injection: tuple[int, ...]
    x32_syscall_bit: int | None


@dataclass(frozen=True)
class _Options:
    write_root: str
    devices: tuple[str, ...]
    allow_metadata: bool
    environment_file: str | None
    max_processes: int | None
    session_state: str | None
    session_ack: str | None
    command: tuple[str, ...]


def _usage(stream: object = sys.stderr) -> None:
    print(
        "usage: landlock-exec --write-root DIR "
        "[--allow-device CHARDEV ...] "
        "[--allow-metadata] "
        "[--environment-file FILE] [--max-processes N] "
        "[--session-state FILE --session-ack FILE] "
        "-- COMMAND [ARG ...]",
        file=stream,
    )


def _parse_args(argv: Sequence[str]) -> _Options:
    write_root: str | None = None
    devices: list[str] = []
    allow_metadata = False
    environment_file: str | None = None
    max_processes: int | None = None
    session_state: str | None = None
    session_ack: str | None = None
    index = 0

    while index < len(argv):
        arg = argv[index]
        if arg == "--":
            command = tuple(argv[index + 1 :])
            if not command:
                raise UsageError("COMMAND is required after --")
            if write_root is None:
                raise UsageError("--write-root DIR is required")
            if (session_state is None) != (session_ack is None):
                raise UsageError(
                    "--session-state and --session-ack must be specified together"
                )
            return _Options(
                write_root,
                tuple(devices),
                allow_metadata,
                environment_file,
                max_processes,
                session_state,
                session_ack,
                command,
            )
        if arg in ("-h", "--help"):
            _usage(sys.stdout)
            raise SystemExit(0)
        if arg == "--write-root":
            index += 1
            if index >= len(argv):
                raise UsageError("--write-root requires a directory")
            if write_root is not None:
                raise UsageError("--write-root may only be specified once")
            write_root = argv[index]
        elif arg.startswith("--write-root="):
            if write_root is not None:
                raise UsageError("--write-root may only be specified once")
            write_root = arg.split("=", 1)[1]
            if not write_root:
                raise UsageError("--write-root requires a directory")
        elif arg == "--allow-device":
            index += 1
            if index >= len(argv):
                raise UsageError("--allow-device requires a character device")
            devices.append(argv[index])
        elif arg.startswith("--allow-device="):
            device = arg.split("=", 1)[1]
            if not device:
                raise UsageError("--allow-device requires a character device")
            devices.append(device)
        elif arg == "--allow-metadata":
            if allow_metadata:
                raise UsageError("--allow-metadata may only be specified once")
            allow_metadata = True
        elif arg == "--environment-file":
            index += 1
            if index >= len(argv):
                raise UsageError("--environment-file requires a file")
            if environment_file is not None:
                raise UsageError("--environment-file may only be specified once")
            environment_file = argv[index]
        elif arg.startswith("--environment-file="):
            if environment_file is not None:
                raise UsageError("--environment-file may only be specified once")
            environment_file = arg.split("=", 1)[1]
            if not environment_file:
                raise UsageError("--environment-file requires a file")
        elif arg == "--max-processes":
            index += 1
            if index >= len(argv):
                raise UsageError("--max-processes requires a positive integer")
            if max_processes is not None:
                raise UsageError("--max-processes may only be specified once")
            try:
                max_processes = int(argv[index])
            except ValueError as exc:
                raise UsageError("--max-processes requires a positive integer") from exc
            if max_processes < 1:
                raise UsageError("--max-processes requires a positive integer")
        elif arg.startswith("--max-processes="):
            if max_processes is not None:
                raise UsageError("--max-processes may only be specified once")
            try:
                max_processes = int(arg.split("=", 1)[1])
            except ValueError as exc:
                raise UsageError("--max-processes requires a positive integer") from exc
            if max_processes < 1:
                raise UsageError("--max-processes requires a positive integer")
        elif arg == "--session-state":
            index += 1
            if index >= len(argv):
                raise UsageError("--session-state requires a file")
            if session_state is not None:
                raise UsageError("--session-state may only be specified once")
            session_state = argv[index]
        elif arg.startswith("--session-state="):
            if session_state is not None:
                raise UsageError("--session-state may only be specified once")
            session_state = arg.split("=", 1)[1]
            if not session_state:
                raise UsageError("--session-state requires a file")
        elif arg == "--session-ack":
            index += 1
            if index >= len(argv):
                raise UsageError("--session-ack requires a file")
            if session_ack is not None:
                raise UsageError("--session-ack may only be specified once")
            session_ack = argv[index]
        elif arg.startswith("--session-ack="):
            if session_ack is not None:
                raise UsageError("--session-ack may only be specified once")
            session_ack = arg.split("=", 1)[1]
            if not session_ack:
                raise UsageError("--session-ack requires a file")
        else:
            raise UsageError(f"unknown argument before --: {arg}")
        index += 1

    raise UsageError("-- COMMAND [ARG ...] is required")


def _syscall_numbers() -> _Syscalls:
    machine = platform.machine().lower()
    if machine == "x86_64":
        audit_arch = AUDIT_ARCH_X86_64
        metadata_mutations = tuple(_X86_64_METADATA_SYSCALLS.values())
        x32_syscall_bit: int | None = X32_SYSCALL_BIT
        seccomp = 317
        ioctl = 16
        process_group_changes = _X86_64_PROCESS_GROUP_SYSCALLS
        process_injection = _X86_64_PROCESS_INJECTION_SYSCALLS
    elif machine in {"aarch64", "arm64"}:
        audit_arch = AUDIT_ARCH_AARCH64
        metadata_mutations = tuple(_AARCH64_METADATA_SYSCALLS.values())
        x32_syscall_bit = None
        seccomp = 277
        ioctl = 29
        process_group_changes = _AARCH64_PROCESS_GROUP_SYSCALLS
        process_injection = _AARCH64_PROCESS_INJECTION_SYSCALLS
    else:
        raise SetupError(f"unsupported Linux architecture: {machine or 'unknown'}")

    return _Syscalls(
        close_range=436,
        create_ruleset=444,
        add_rule=445,
        restrict_self=446,
        seccomp=seccomp,
        ioctl=ioctl,
        audit_arch=audit_arch,
        metadata_mutations=metadata_mutations,
        process_group_changes=process_group_changes,
        process_injection=process_injection,
        x32_syscall_bit=x32_syscall_bit,
    )


def _call_syscall(libc: ctypes.CDLL, number: int, *args: object) -> int:
    ctypes.set_errno(0)
    result = libc.syscall(ctypes.c_long(number), *args)
    if result == -1:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    return int(result)


def _query_abi(libc: ctypes.CDLL, calls: _Syscalls) -> int:
    try:
        abi = _call_syscall(
            libc,
            calls.create_ruleset,
            ctypes.c_void_p(),
            ctypes.c_size_t(0),
            ctypes.c_uint(LANDLOCK_CREATE_RULESET_VERSION),
        )
    except OSError as exc:
        if exc.errno in {errno.ENOSYS, errno.EOPNOTSUPP, errno.EINVAL, errno.EPERM}:
            raise SetupError(
                f"Landlock is unavailable (ABI query failed: {exc.strerror})"
            ) from exc
        raise SetupError(f"Landlock ABI query failed: {exc}") from exc
    if abi < 3:
        raise SetupError(
            f"Landlock ABI {abi} is too old; ABI 3 or newer is required"
        )
    return abi


def _open_path(path: str, *, directory: bool) -> tuple[str, int]:
    if not path:
        raise SetupError("an allowed path may not be empty")
    try:
        resolved = os.path.realpath(path, strict=True)
    except (OSError, TypeError) as exc:
        raise SetupError(f"cannot resolve allowed path {path!r}: {exc}") from exc

    flags = os.O_PATH | os.O_CLOEXEC | os.O_NOFOLLOW
    if directory:
        flags |= os.O_DIRECTORY
    try:
        fd = os.open(resolved, flags)
    except OSError as exc:
        raise SetupError(f"cannot open allowed path {resolved!r}: {exc}") from exc

    try:
        mode = os.fstat(fd).st_mode
        expected = stat.S_ISDIR(mode) if directory else stat.S_ISCHR(mode)
        if not expected:
            kind = "a directory" if directory else "a character device"
            raise SetupError(f"allowed path {resolved!r} is not {kind}")
    except BaseException:
        os.close(fd)
        raise
    return resolved, fd


def _confined_session_path(write_root: str, path: str) -> str:
    """Resolve a handshake path and prove that its parent is under write_root."""
    try:
        resolved_root = os.path.realpath(write_root, strict=True)
        resolved_parent = os.path.realpath(os.path.dirname(path), strict=True)
        if os.path.commonpath((resolved_root, resolved_parent)) != resolved_root:
            raise SetupError("session handshake files must be beneath --write-root")
    except (OSError, TypeError, ValueError) as exc:
        raise SetupError(f"cannot resolve session handshake path {path!r}: {exc}") from exc

    basename = os.path.basename(path)
    if basename in {"", ".", ".."}:
        raise SetupError("session handshake path must name a regular file")
    return os.path.join(resolved_parent, basename)


def _load_environment(write_root: str, environment_file: str | None) -> dict[str, str] | None:
    """Read a supervisor-generated environment without exposing values in argv."""
    if environment_file is None:
        return None
    resolved_file = _confined_session_path(write_root, environment_file)
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        fd = os.open(resolved_file, flags)
    except OSError as exc:
        raise SetupError(f"cannot open environment file {resolved_file!r}: {exc}") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise SetupError("--environment-file must name a regular file")
        if info.st_size > 1024 * 1024:
            raise SetupError("--environment-file is larger than 1 MiB")
        payload = bytearray()
        while len(payload) <= info.st_size:
            chunk = os.read(fd, min(65536, info.st_size + 1 - len(payload)))
            if not chunk:
                break
            payload.extend(chunk)
        if len(payload) != info.st_size:
            raise SetupError("environment file changed while it was read")
    finally:
        os.close(fd)

    try:
        decoded = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SetupError(f"invalid JSON environment file: {exc}") from exc
    if not isinstance(decoded, dict):
        raise SetupError("--environment-file must contain a JSON object")
    environment: dict[str, str] = {}
    for key, value in decoded.items():
        if (
            not isinstance(key, str)
            or not key
            or "=" in key
            or "\x00" in key
            or not isinstance(value, str)
            or "\x00" in value
        ):
            raise SetupError("environment keys and values must be valid strings")
        environment[key] = value
    return environment


def _limit_processes(max_processes: int | None) -> None:
    """Reserve PID-cgroup capacity for the separate-uid supervisor cleanup."""
    if max_processes is None:
        return
    try:
        _soft, hard = resource.getrlimit(resource.RLIMIT_NPROC)
        target = max_processes if hard == resource.RLIM_INFINITY else min(max_processes, hard)
        resource.setrlimit(resource.RLIMIT_NPROC, (target, target))
    except (OSError, ValueError) as exc:
        raise SetupError(f"cannot set reviewer process limit: {exc}") from exc


def _write_session_state(write_root: str, state_file: str | None) -> None:
    """Publish the execing process's PID/PGID before any untrusted code runs."""
    if state_file is None:
        return
    resolved_state = _confined_session_path(write_root, state_file)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        fd = os.open(resolved_state, flags, 0o600)
    except OSError as exc:
        raise SetupError(f"cannot open session-state file {resolved_state!r}: {exc}") from exc
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise SetupError("--session-state must name a regular file")
        pid = os.getpid()
        pgid = os.getpgrp()
        pid_starttime = _process_starttime(pid)
        try:
            pg_starttime = _process_starttime(pgid)
        except SetupError:
            # A process group remains valid after its leader exits. The root
            # controller can still authenticate it from the protected anchor
            # and exact reviewer-uid members.
            pg_starttime = 0
        payload = f"{pid} {pgid} {pid_starttime} {pg_starttime}\n".encode("ascii")
        if os.write(fd, payload) != len(payload):
            raise SetupError("short write to --session-state file")
    finally:
        os.close(fd)


def _process_starttime(pid: int) -> int:
    """Return Linux /proc starttime ticks for PID, robust to ')' in comm."""
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="ascii") as stream:
            line = stream.read()
        marker = line.rfind(")")
        fields = line[marker + 1 :].split() if marker >= 0 else []
        value = int(fields[19])
    except (FileNotFoundError, ProcessLookupError, PermissionError, ValueError, IndexError) as exc:
        raise SetupError(f"cannot read process identity for PID {pid}: {exc}") from exc
    if value <= 0:
        raise SetupError(f"invalid process starttime for PID {pid}")
    return value


def _wait_for_session_ack(write_root: str, ack_file: str | None) -> None:
    """Wait until the parent has cached the PID/PGID outside reviewer writes."""
    if ack_file is None:
        return
    resolved_ack = _confined_session_path(write_root, ack_file)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        try:
            fd = os.open(resolved_ack, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        except FileNotFoundError:
            time.sleep(0.01)
            continue
        except OSError as exc:
            raise SetupError(f"cannot open session-ack file {resolved_ack!r}: {exc}") from exc
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise SetupError("--session-ack must name a regular file")
            value = os.read(fd, 32)
        finally:
            os.close(fd)
        if value == b"ready\n":
            return
        if value:
            raise SetupError("invalid --session-ack value")
        time.sleep(0.01)
    raise SetupError("timed out waiting for parent session acknowledgment")


def _add_path_rule(
    libc: ctypes.CDLL,
    calls: _Syscalls,
    ruleset_fd: int,
    path_fd: int,
    allowed_access: int,
) -> None:
    attr = _PathBeneathAttr(
        allowed_access=allowed_access,
        parent_fd=path_fd,
    )
    _call_syscall(
        libc,
        calls.add_rule,
        ctypes.c_int(ruleset_fd),
        ctypes.c_int(LANDLOCK_RULE_PATH_BENEATH),
        ctypes.byref(attr),
        ctypes.c_uint(0),
    )


def _install_landlock(write_root: str, devices: Sequence[str]) -> tuple[ctypes.CDLL, _Syscalls]:
    if sys.platform != "linux":
        raise SetupError(f"Landlock requires Linux (running on {sys.platform})")
    if not hasattr(os, "O_PATH"):
        raise SetupError("this Python build does not expose Linux O_PATH")

    calls = _syscall_numbers()
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    abi = _query_abi(libc, calls)
    handled_access = _BASE_MUTATION_ACCESS
    if abi >= 5:
        handled_access |= LANDLOCK_ACCESS_FS_IOCTL_DEV

    root_name, root_fd = _open_path(write_root, directory=True)
    device_fds: list[tuple[str, int]] = []
    ruleset_fd = -1
    try:
        for device in devices:
            device_fds.append(_open_path(device, directory=False))

        attr = _RulesetAttr(handled_access_fs=handled_access)
        try:
            ruleset_fd = _call_syscall(
                libc,
                calls.create_ruleset,
                ctypes.byref(attr),
                ctypes.c_size_t(ctypes.sizeof(attr)),
                ctypes.c_uint(0),
            )
            _add_path_rule(libc, calls, ruleset_fd, root_fd, handled_access)

            device_access = LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_TRUNCATE
            if abi >= 5:
                device_access |= LANDLOCK_ACCESS_FS_IOCTL_DEV
            for _device_name, device_fd in device_fds:
                _add_path_rule(libc, calls, ruleset_fd, device_fd, device_access)

            libc.prctl.restype = ctypes.c_int
            libc.prctl.argtypes = [
                ctypes.c_int,
                ctypes.c_ulong,
                ctypes.c_ulong,
                ctypes.c_ulong,
                ctypes.c_ulong,
            ]
            ctypes.set_errno(0)
            if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1:
                error_number = ctypes.get_errno()
                raise OSError(error_number, os.strerror(error_number))
            _call_syscall(
                libc,
                calls.restrict_self,
                ctypes.c_int(ruleset_fd),
                ctypes.c_uint(0),
            )
        except OSError as exc:
            raise SetupError(f"cannot install Landlock rules for {root_name!r}: {exc}") from exc
    finally:
        if ruleset_fd >= 0:
            os.close(ruleset_fd)
        os.close(root_fd)
        for _device_name, device_fd in device_fds:
            os.close(device_fd)

    return libc, calls


def _close_extra_fds(libc: ctypes.CDLL, calls: _Syscalls) -> None:
    """Close inherited descriptors that would bypass path-based checks."""
    try:
        _call_syscall(
            libc,
            calls.close_range,
            ctypes.c_uint(3),
            ctypes.c_uint(UINT_MAX),
            ctypes.c_uint(0),
        )
    except OSError as exc:
        raise SetupError(f"cannot close inherited file descriptors: {exc}") from exc


def _install_seccomp(
    libc: ctypes.CDLL,
    calls: _Syscalls,
    *,
    allow_metadata: bool,
) -> None:
    """Deny non-path mutation and process-escape mechanisms."""
    instructions: list[tuple[int, int, int, int]] = [
        # A filter that interprets numbers for the wrong ABI is a sandbox
        # bypass, so terminate instead of returning an ordinary syscall error.
        (BPF_LD_W_ABS, 0, 0, SECCOMP_DATA_ARCH_OFFSET),
        (BPF_JMP_JEQ_K, 1, 0, calls.audit_arch),
        (BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS),
        (BPF_LD_W_ABS, 0, 0, SECCOMP_DATA_NR_OFFSET),
    ]

    if calls.x32_syscall_bit is not None:
        # AUDIT_ARCH_X86_64 also identifies x32, which ORs this bit into every
        # syscall number.  Reject the ABI rather than leave an aliasing bypass.
        instructions.extend(
            [
                (BPF_JMP_JSET_K, 0, 1, calls.x32_syscall_bit),
                (BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS),
            ]
        )

    error_result = SECCOMP_RET_ERRNO | (errno.EPERM & SECCOMP_RET_DATA_MASK)

    # ioctl cannot be filtered by pathname.  Default-deny its request argument,
    # admitting only descriptor/terminal operations that Codex needs for
    # ordinary subprocess pipes.  This retains the fail-closed posture for
    # inode flags, project IDs, verity, encryption policy, filesystem-specific
    # mutators, and future requests without breaking the supported CLI.
    ioctl_handler_length = 2 * len(_ALLOWED_IOCTL_REQUESTS) + 2
    instructions.append(
        (BPF_JMP_JEQ_K, 0, ioctl_handler_length, calls.ioctl)
    )
    instructions.append((BPF_LD_W_ABS, 0, 0, SECCOMP_DATA_ARG1_LOW_OFFSET))
    for request in _ALLOWED_IOCTL_REQUESTS:
        instructions.extend(
            [
                (BPF_JMP_JEQ_K, 0, 1, request),
                (BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW),
            ]
        )
    instructions.append((BPF_RET_K, 0, 0, error_result))

    # Codex prepares verifier children with setsid() and treats every return
    # other than -1 as success. SECCOMP_RET_ERRNO with data zero makes the
    # kernel skip these syscalls while returning raw success (0). This keeps
    # the CLI compatible without letting descendants leave the authenticated
    # reviewer process group. ERRNO outranks ALLOW and USER_NOTIF when filters
    # are stacked, so Codex may add its own network filter but cannot cause the
    # skipped process-group calls to execute.
    group_result = SECCOMP_RET_ERRNO
    for syscall_number in calls.process_group_changes:
        instructions.extend(
            [
                (BPF_JMP_JEQ_K, 0, 1, syscall_number),
                (BPF_RET_K, 0, 0, group_result),
            ]
        )

    denied_syscalls = [*calls.process_injection, *_IO_URING_SYSCALLS]
    if not allow_metadata:
        denied_syscalls.extend(calls.metadata_mutations)
    denied = tuple(dict.fromkeys(denied_syscalls))
    for syscall_number in denied:
        # Match executes RET_ERRNO; no match skips it and tests the next number.
        instructions.extend(
            [
                (BPF_JMP_JEQ_K, 0, 1, syscall_number),
                (BPF_RET_K, 0, 0, error_result),
            ]
        )
    instructions.append((BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW))

    filter_array_type = _SockFilter * len(instructions)
    filter_array = filter_array_type(
        *(_SockFilter(*instruction) for instruction in instructions)
    )
    program = _SockFprog(
        length=len(filter_array),
        filters=ctypes.cast(filter_array, ctypes.POINTER(_SockFilter)),
    )

    try:
        _call_syscall(
            libc,
            calls.seccomp,
            ctypes.c_uint(SECCOMP_SET_MODE_FILTER),
            ctypes.c_uint(0),
            ctypes.byref(program),
        )
    except OSError as exc:
        raise SetupError(f"cannot install metadata seccomp filter: {exc}") from exc


def _fatal(message: str, status: int) -> NoReturn:
    print(f"landlock-exec: {message}", file=sys.stderr, flush=True)
    raise SystemExit(status)


def main(argv: Sequence[str] | None = None) -> NoReturn:
    try:
        options = _parse_args(sys.argv[1:] if argv is None else argv)
    except UsageError as exc:
        _usage()
        _fatal(str(exc), 2)

    try:
        environment = _load_environment(options.write_root, options.environment_file)
        _limit_processes(options.max_processes)
        _write_session_state(options.write_root, options.session_state)
        _wait_for_session_ack(options.write_root, options.session_ack)
        libc, calls = _install_landlock(options.write_root, options.devices)
        _close_extra_fds(libc, calls)
        _install_seccomp(
            libc,
            calls,
            allow_metadata=options.allow_metadata,
        )
    except SetupError as exc:
        _fatal(f"refusing to run command: {exc}", 125)

    try:
        if environment is None:
            os.execvp(options.command[0], options.command)
        else:
            os.execvpe(options.command[0], options.command, environment)
    except OSError as exc:
        _fatal(f"cannot exec {options.command[0]!r}: {exc}", 126)


if __name__ == "__main__":
    main()
