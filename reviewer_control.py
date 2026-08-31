#!/usr/bin/python3 -I
"""Root-side liveness/signal control for AgentMill's dedicated reviewer uid.

The primary agent may invoke this fixed, root-owned program through one narrow
sudoers entry.  It can inspect or signal only a process group authenticated by
the pre-exec reviewer handshake, and only when that group still contains a
process whose four uid fields all belong to ``agentmill-reviewer``.
"""

from __future__ import annotations

import os
import pwd
import re
import signal
import sys
import time
from dataclasses import dataclass


_DECIMAL = re.compile(r"[1-9][0-9]*\Z")
_SIGNALS = {"0": 0, "TERM": signal.SIGTERM, "KILL": signal.SIGKILL}
_KILL_DRAIN_SECONDS = 2.0
_INTERNAL_DEADLINE_SECONDS = 3
# Keep "confirmed no authenticated reviewer member" distinct from sudo's own
# conventional rc=1 setup/policy failures. The shell maps this private code to
# its logical dead state only after the root helper has completed its scan.
CONFIRMED_DEAD = 10


class Refusal(Exception):
    """The requested target is malformed, stale, or outside the boundary."""


@dataclass(frozen=True)
class Process:
    pid: int
    pgrp: int
    starttime: int
    state: str
    uids: tuple[int, int, int, int]


def _positive(value: str, label: str) -> int:
    if not _DECIMAL.fullmatch(value):
        raise Refusal(f"{label} must be a positive decimal integer")
    parsed = int(value)
    if parsed <= 1:
        raise Refusal(f"{label} must be greater than 1")
    return parsed


def _starttime(value: str, label: str, *, allow_zero: bool = False) -> int:
    if allow_zero and value == "0":
        return 0
    return _positive(value, label)


def _read_process(pid: int) -> Process | None:
    try:
        with open(f"/proc/{pid}/status", "rb") as stream:
            status_payload = stream.read()
        with open(f"/proc/{pid}/stat", "rb") as stream:
            stat_line = stream.read()
    except (FileNotFoundError, ProcessLookupError):
        return None
    except OSError as exc:
        raise Refusal(f"cannot inspect reviewer process {pid}: {exc}") from exc

    uid_lines = [line for line in status_payload.splitlines() if line.startswith(b"Uid:")]
    if len(uid_lines) != 1:
        raise Refusal(f"invalid uid identity for reviewer process {pid}")
    try:
        uid_fields = tuple(int(item) for item in uid_lines[0].split()[1:])
    except ValueError as exc:
        raise Refusal(f"invalid uid identity for reviewer process {pid}") from exc
    if len(uid_fields) != 4:
        raise Refusal(f"invalid uid identity for reviewer process {pid}")

    # comm is parenthesized and may itself contain spaces or ')'; fields after
    # the final ')' begin with state (field 3). pgrp is field 5 and starttime
    # is field 22, therefore indexes 2 and 19 in this suffix.
    marker = stat_line.rfind(b")")
    if marker < 0:
        raise Refusal(f"invalid stat identity for reviewer process {pid}")
    fields = stat_line[marker + 1 :].split()
    if len(fields) <= 19:
        raise Refusal(f"invalid stat identity for reviewer process {pid}")
    try:
        return Process(
            pid=pid,
            pgrp=int(fields[2]),
            starttime=int(fields[19]),
            state=fields[0].decode("ascii"),
            uids=uid_fields,  # type: ignore[arg-type]
        )
    except (UnicodeError, ValueError) as exc:
        raise Refusal(f"invalid stat identity for reviewer process {pid}") from exc


def _reviewer_members(pgid: int, reviewer_uid: int) -> list[Process]:
    members: list[Process] = []
    try:
        entries = os.scandir("/proc")
    except OSError as exc:
        raise Refusal(f"cannot scan /proc: {exc}") from exc
    with entries:
        for entry in entries:
            if not entry.name.isascii() or not entry.name.isdecimal():
                continue
            process = _read_process(int(entry.name))
            if process is None or process.state == "Z" or process.pgrp != pgid:
                continue
            if process.uids == (reviewer_uid,) * 4:
                members.append(process)
    return members


def _group_exists(pgid: int) -> bool:
    """Ask the kernel whether PGID still names a process group.

    A /proc directory walk is not an atomic liveness test: a hostile process
    can fork a successor and exit while the walk is consuming its buffered
    directory entries.  killpg(..., 0) is the authoritative check and ESRCH
    is the only state that may be reported to the shell as confirmed dead.
    """
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except OSError as exc:
        raise Refusal(f"cannot probe reviewer process group {pgid}: {exc}") from exc
    return True


def _validate_identity(
    pid: int,
    pgid: int,
    pid_starttime: int,
    pg_starttime: int,
    reviewer_uid: int,
) -> list[Process]:
    if pgid == os.getpgrp():
        raise Refusal("refusing to target the control helper's own process group")

    anchor = _read_process(pid)
    if anchor is not None:
        if anchor.uids != (reviewer_uid,) * 4:
            raise Refusal("reviewer PID no longer belongs to the reviewer uid")
        if anchor.pgrp != pgid or anchor.starttime != pid_starttime:
            raise Refusal("reviewer PID identity no longer matches the handshake")

    leader = _read_process(pgid)
    if leader is not None and pg_starttime:
        if leader.starttime != pg_starttime:
            raise Refusal("reviewer process-group leader was reused")

    members = _reviewer_members(pgid, reviewer_uid)
    if not members:
        if _group_exists(pgid):
            raise Refusal(
                "reviewer process group exists without an authenticated member"
            )
        return []
    # If the anchor PID disappeared, live members retain the group identity;
    # Linux cannot reuse that pgrp number while any such member remains.
    if anchor is None and leader is None:
        return members
    if anchor is None and leader is not None and not pg_starttime:
        raise Refusal("cannot authenticate a replacement process-group leader")
    return members


def _usage() -> None:
    print(
        "usage: agentmill-reviewer-control 0|TERM|KILL "
        "PID PGID PID_STARTTIME PG_LEADER_STARTTIME",
        file=sys.stderr,
    )


def main() -> int:
    # Do not rely solely on the caller's non-root timeout to stop a setuid-root
    # sudo child. This process owns its own hard deadline, including NSS and
    # /proc operations.
    signal.signal(signal.SIGALRM, lambda _signum, _frame: os._exit(124))
    signal.alarm(_INTERNAL_DEADLINE_SECONDS)
    if os.geteuid() != 0:
        print("agentmill-reviewer-control: must run as root", file=sys.stderr)
        return 125
    if len(sys.argv) != 6 or sys.argv[1] not in _SIGNALS:
        _usage()
        return 2
    try:
        pid = _positive(sys.argv[2], "PID")
        pgid = _positive(sys.argv[3], "PGID")
        pid_starttime = _starttime(sys.argv[4], "PID starttime")
        pg_starttime = _starttime(
            sys.argv[5], "process-group leader starttime", allow_zero=True
        )
        reviewer_uid = pwd.getpwnam("agentmill-reviewer").pw_uid
        members = _validate_identity(
            pid, pgid, pid_starttime, pg_starttime, reviewer_uid
        )
    except (KeyError, Refusal) as exc:
        print(f"agentmill-reviewer-control: refusing request: {exc}", file=sys.stderr)
        return 2

    requested = _SIGNALS[sys.argv[1]]
    if not members:
        return CONFIRMED_DEAD
    if requested == 0:
        return 0

    try:
        os.killpg(pgid, requested)
    except ProcessLookupError:
        return CONFIRMED_DEAD
    except OSError as exc:
        print(f"agentmill-reviewer-control: killpg failed: {exc}", file=sys.stderr)
        return 125

    if requested != signal.SIGKILL:
        return 0
    deadline = time.monotonic() + _KILL_DRAIN_SECONDS
    while time.monotonic() < deadline:
        if not _group_exists(pgid):
            return 0
        time.sleep(0.01)
    print("agentmill-reviewer-control: reviewer group did not drain", file=sys.stderr)
    return 124


if __name__ == "__main__":
    try:
        status = main()
    except Exception as exc:
        print(f"agentmill-reviewer-control: internal failure: {exc}", file=sys.stderr)
        status = 125
    raise SystemExit(status)
