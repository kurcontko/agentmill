"""Deterministic run records. This module never infers success from agent prose."""

import argparse
import json
import os
from pathlib import Path
import tempfile
import sys
from datetime import datetime, timezone


def write_json(path, record):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix=".outcome-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def outcome_main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("run_id")
    parser.add_argument("exit_code", type=int)
    parser.add_argument("stop_reason")
    parser.add_argument("claimed", choices=("true", "false"))
    parser.add_argument("checks")
    parser.add_argument("review")
    parser.add_argument("checked_commit")
    parser.add_argument("iterations", type=int)
    args = parser.parse_args()
    outcome = {0: "complete", 2: "incomplete", 3: "blocked",
               4: "cancelled", 130: "cancelled", 143: "cancelled"}.get(
                   args.exit_code, "failed")
    if outcome == "complete" and (
        args.claimed != "true" or args.checks != "passed"
        or args.review not in ("passed", "not_run") or not args.checked_commit
    ):
        raise ValueError("verified completion requires recorded acceptance evidence")
    write_json(args.path, {
        "schema_version": 1,
        "run_id": args.run_id,
        "completion": outcome,
        "stop_reason": args.stop_reason,
        "exit_code": args.exit_code,
        "agent_claimed_done": args.claimed == "true",
        "verification": {"checks": args.checks, "review": args.review,
                         "checked_commit": args.checked_commit or None},
        "iterations": args.iterations,
        "ended_at": datetime.now(timezone.utc).isoformat(),
    })


def observation_main(arguments):
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("command")
    parser.add_argument("exit_code", type=int)
    parser.add_argument("checked_commit")
    parser.add_argument("output")
    parser.add_argument("--patch")
    parser.add_argument("--summary")
    parser.add_argument("--accepted-commit")
    args = parser.parse_args(arguments)
    with open(args.output, "rb") as stream:
        stream.seek(0, os.SEEK_END)
        stream.seek(max(0, stream.tell() - 8192))
        excerpt = stream.read(8192).decode("utf-8", errors="replace")
    record = {
        "schema_version": 1, "command": args.command,
        "exit_code": args.exit_code, "checked_commit": args.checked_commit or None,
        "output": args.output, "excerpt": excerpt,
    }
    if args.patch:
        record["patch"] = args.patch
        record["accepted_commit"] = args.accepted_commit or None
    if args.summary:
        with open(args.summary, "rb") as stream:
            record["attempted_change"] = stream.read(4096).decode("utf-8", errors="replace")
    write_json(args.path, record)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "observation":
        observation_main(sys.argv[2:])
    else:
        outcome_main()
