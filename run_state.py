"""Deterministic run records. This module never infers success from agent prose."""

import argparse
import json
import os
from pathlib import Path
import tempfile
import sys
import hashlib
import re
import subprocess
import uuid
from datetime import datetime, timezone


CONFIG_KEYS = (
    "AGENT MODEL FALLBACK_MODEL MAX_ITERATIONS MAX_ERRORS MAX_NOOPS ITER_TIMEOUT "
    "LOOP_DELAY ERROR_BACKOFF MAX_BACKOFF SHUTDOWN_GRACE MAX_TURNS MAX_BUDGET_USD "
    "MAX_TOTAL_BUDGET_USD MIN_TURNS DONE_PROMISE SETUP_CMD CHECK_CMD METRIC_CMD "
    "METRIC_DIRECTION DONE_CMD EVALUATOR CLAUDE_BARE"
).split()


def event(directory, kind, **fields):
    record = {"schema_version": 1, "type": kind,
              "at": datetime.now(timezone.utc).isoformat(), **fields}
    with open(Path(directory) / "events.jsonl", "a") as stream:
        stream.write(json.dumps(record) + "\n")


def git_value(repository, *arguments):
    try:
        return subprocess.check_output(
            ["git", "-C", repository, *arguments], stderr=subprocess.DEVNULL,
            timeout=10, text=True).strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def initialize_main(arguments):
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("repository")
    parser.add_argument("mission")
    parser.add_argument("--run-id")
    args = parser.parse_args(arguments)
    run_id = args.run_id or str(uuid.uuid4())
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{7,80}", run_id):
        raise ValueError("invalid run ID")
    root = Path(args.root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    directory = root if args.run_id else root / run_id
    if args.run_id and any(directory.iterdir()):
        raise ValueError("a supplied run directory must be empty; implicit resume is not allowed")
    if not args.run_id:
        directory.mkdir(mode=0o700)
    # Exclusive reservation prevents a supplied ID from reusing a run's budget
    # or evidence. Resume will require an explicit, separately validated path.
    with open(directory / "manifest.json", "x") as stream:
        stream.write("{}\n")
    # The separate reviewer UID must traverse to its explicitly named schema
    # and scratch metadata. Directory listing remains private to the worker.
    directory.chmod(0o711)
    (directory / "artifacts").mkdir()
    config = {key: os.environ.get(key, "") for key in CONFIG_KEYS}
    policy = {key: config[key] for key in ("CHECK_CMD", "DONE_CMD", "EVALUATOR", "METRIC_CMD", "METRIC_DIRECTION")}
    try:
        mission = Path(args.mission).read_bytes()
    except OSError:
        mission = None
    if mission is not None:
        (directory / "artifacts" / "mission-at-start.md").write_bytes(mission)
    write_json(directory / "artifacts" / "acceptance-policy.json", policy)
    manifest = {
        "schema_version": 1, "run_id": run_id,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "repository": str(Path(args.repository).resolve()),
        "original_commit": git_value(args.repository, "rev-parse", "--verify", "HEAD"),
        "mission_sha256": hashlib.sha256(mission).hexdigest() if mission is not None else None,
        "policy_sha256": hashlib.sha256(json.dumps(policy, sort_keys=True).encode()).hexdigest(),
        "configuration": config,
        "runtime": {"image_id": os.environ.get("AGENTMILL_RUNTIME_IMAGE_ID") or None,
                    "provider": config["AGENT"],
                    "cli_version": os.environ.get("AGENTMILL_" + config["AGENT"].upper() + "_VERSION") or None},
    }
    write_json(directory / "manifest.json", manifest)
    event(directory, "run_started", run_id=run_id, original_commit=manifest["original_commit"])
    if not args.run_id:
        pointer = root / (".latest-" + run_id)
        pointer.symlink_to(run_id)
        os.replace(pointer, root / "latest")
    print(directory)


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
    record = {
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
    }
    write_json(args.path, record)
    event(Path(args.path).parent, "run_finished", **record)


def checkpoint_main(arguments):
    directory, commit, iteration, kind, checks, checked_commit = arguments
    event(directory, "checkpoint_accepted", commit=commit,
          iteration=int(iteration), checkpoint_kind=kind,
          verification={"checks": checks, "checked_commit": checked_commit or None})


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
    commands = {"observation": observation_main, "init": initialize_main,
                "checkpoint": checkpoint_main}
    if len(sys.argv) > 1 and sys.argv[1] in commands:
        commands[sys.argv[1]](sys.argv[2:])
    else:
        outcome_main()
