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
import math
from decimal import Decimal, InvalidOperation
from datetime import datetime, timezone


CONFIG_KEYS = (
    "AGENT MODEL FALLBACK_MODEL MAX_ITERATIONS MAX_ERRORS MAX_NOOPS ITER_TIMEOUT "
    "LOOP_DELAY ERROR_BACKOFF MAX_BACKOFF SHUTDOWN_GRACE MAX_TURNS MAX_BUDGET_USD "
    "MAX_TOTAL_BUDGET_USD MIN_TURNS DONE_PROMISE SETUP_CMD CHECK_CMD METRIC_CMD "
    "METRIC_DIRECTION DONE_CMD EVALUATOR CLAUDE_BARE SETUP_TIMEOUT AGENT_TIMEOUT "
    "CHECK_TIMEOUT MAX_DURATION REVIEW_RESERVE_USD"
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
        "accounting": accounting(Path(args.path).parent),
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


def decimal_cost(value):
    try:
        result = Decimal(value)
        return result if result.is_finite() and result >= 0 and math.isfinite(float(result)) else None
    except (InvalidOperation, ValueError, TypeError):
        return None


def sessions(directory):
    path = Path(directory) / "sessions.jsonl"
    if not path.exists():
        return []
    return [json.loads(line, parse_float=Decimal) for line in path.read_text().splitlines()]


def accounting(directory):
    rows = sessions(directory)
    roles = {}
    for role in ("worker", "reviewer"):
        selected = [row for row in rows if row["role"] == role]
        known = sum((Decimal(str(row["cost_usd"])) for row in selected if row["cost_state"] == "provider_reported"), Decimal(0))
        estimated = sum((Decimal(str(row["cost_usd"])) for row in selected if row["cost_state"] == "estimated"), Decimal(0))
        unknown = sum(row["cost_state"] == "unknown" for row in selected)
        roles[role] = {"reported_cost_usd": float(known), "unknown_sessions": unknown,
                       "estimated_cost_usd": float(estimated),
                       "estimated_sessions": sum(row["cost_state"] == "estimated" for row in selected),
                       "sessions": len(selected), "duration_s": sum(row["duration_s"] for row in selected)}
    unknown = sum(role["unknown_sessions"] for role in roles.values())
    total = sum(role["reported_cost_usd"] for role in roles.values())
    estimated = sum(role["estimated_sessions"] for role in roles.values())
    return {"roles": roles, "reported_cost_usd": total,
            "estimated_cost_usd": sum(role["estimated_cost_usd"] for role in roles.values()),
            "total_cost_usd": None if unknown or estimated else total,
            "cost_state": "unknown" if unknown else "estimated" if estimated else "provider_reported",
            "unknown_sessions": unknown}


def session_main(arguments):
    directory, iteration, role, provider, metrics, duration, exit_code = arguments[:7]
    source = arguments[7] if len(arguments) > 7 else "provider_reported"
    if source not in ("provider_reported", "estimated"):
        raise ValueError("invalid monetary telemetry source")
    fields = Path(metrics).read_text().splitlines()
    fields = (fields[0].split("\t") if fields else []) + [""] * 7
    cost = decimal_cost(fields[2])
    def integer(value):
        return int(value) if value.isdigit() else None
    record = {"schema_version": 1, "session_id": f"{iteration}:{role}",
              "iteration": int(iteration), "role": role, "provider": provider,
              "cost_usd": float(cost) if cost is not None else None,
              "cost_state": source if cost is not None else "unknown",
              "tokens_in": integer(fields[5]), "tokens_out": integer(fields[6]),
              "turns": integer(fields[3]), "duration_s": int(duration), "exit_code": int(exit_code)}
    with open(Path(directory) / "sessions.jsonl", "a") as stream:
        stream.write(json.dumps(record) + "\n")
    write_json(Path(directory) / "accounting.json", accounting(directory))


def allowance_main(arguments):
    directory, total_limit, session_limit, reserve, role, provider = arguments
    limit = decimal_cost(total_limit) if total_limit else None
    cap = decimal_cost(session_limit) if session_limit else None
    reserve_value = decimal_cost(reserve)
    if (total_limit and limit is None) or (session_limit and cap is None) or reserve_value is None:
        raise ValueError("monetary limits must be finite, non-negative numbers")
    if limit is not None:
        if provider != "claude":
            print("cost_unsupported")
            return
        rows = sessions(directory)
        if any(row["cost_state"] != "provider_reported" for row in rows):
            print("cost_unknown")
            return
        remaining = limit - sum((Decimal(str(row["cost_usd"])) for row in rows), Decimal(0))
        if role == "worker":
            remaining -= reserve_value
        cap = remaining if cap is None else min(cap, remaining)
    if cap is not None and cap <= 0:
        print("budget_limit")
    else:
        print("allowed:" + (format(cap, "f") if cap is not None else ""))


if __name__ == "__main__":
    commands = {"observation": observation_main, "init": initialize_main,
                "checkpoint": checkpoint_main, "session": session_main,
                "allowance": allowance_main}
    if len(sys.argv) > 1 and sys.argv[1] in commands:
        commands[sys.argv[1]](sys.argv[2:])
    else:
        outcome_main()
