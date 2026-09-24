"""The small command-line surface: run, show and diff."""

import argparse
from contextlib import suppress
import json
import os
from pathlib import Path
import re
import shlex
import sys

from .contracts import DEFAULT_IMAGE, RunSpec
from .output import OutputSink
from .records import runs_root
from .runner import run


def duration(value):
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([smh]?)", value)
    if not match:
        raise argparse.ArgumentTypeError("duration must be seconds or use s, m, h (for example 30m)")
    seconds = float(match[1]) * {"": 1, "s": 1, "m": 60, "h": 3600}[match[2]]
    if seconds <= 0:
        raise argparse.ArgumentTypeError("duration must be positive")
    return seconds


def parser():
    root = argparse.ArgumentParser(prog="agentmill", description="A bounded, checked native coding-agent runner.")
    commands = root.add_subparsers(dest="command", required=True)
    launch = commands.add_parser("run", help="run one task in a private checkout")
    launch.add_argument("source", nargs="?")
    launch.add_argument("--spec", type=Path, help="JSON object with RunSpec fields; explicit flags override it")
    launch.add_argument("--revision")
    task = launch.add_mutually_exclusive_group()
    task.add_argument("--task")
    task.add_argument("--task-file", type=Path)
    launch.add_argument("--agent", choices=("codex", "claude"))
    launch.add_argument("--model")
    launch.add_argument("--profile", help="Codex profile name, used with --agent-config")
    launch.add_argument("--agent-config", help="explicit native config file (Codex TOML or Claude settings JSON)")
    launch.add_argument("--auth-file", help="explicit Codex auth.json; never exposed to checks")
    launch.add_argument("--credential-env", action="append", help="native environment variable NAME, never its value")
    launch.add_argument("--setup")
    launch.add_argument("--check", action="append", dest="checks")
    launch.add_argument("--check-dir", help="held-out check files, mounted read-only at /checks "
                        "in check containers only; the worker never receives them")
    launch.add_argument("--max-sessions", "--iterations", type=int, dest="max_sessions")
    launch.add_argument("--max-duration", type=duration)
    for phase in ("setup", "session", "check"):
        launch.add_argument(f"--{phase}-timeout", type=duration)
    launch.add_argument("--image")
    launch.add_argument("--json", action="store_true", help="emit only AgentMill JSONL events on stdout")
    launch.add_argument("--runs-dir", type=Path, help="override the private run storage directory")
    for name in ("show", "diff"):
        inspect = commands.add_parser(name)
        inspect.add_argument("run_id")
        inspect.add_argument("--runs-dir", type=Path)
        if name == "show":
            inspect.add_argument("--json", action="store_true")
    return root


def human_result(value, directory, launcher=("agentmill",)):
    directory = Path(directory).resolve()
    candidate = value.get("latest_candidate_sha")
    check_status = value.get("candidate_check_status", "unknown (see recorded checks)")
    lines = [f"Run: {value['run_id']}", f"Result: {value['status']} ({value['stop_reason']})"]
    reply = value.get("agent_reply") or {}
    for field, label in (("summary", "Agent summary"), ("question", "Question"), ("next_step", "Next step")):
        if reply.get(field):
            lines.append(f"{label}: {reply[field]}")
    lines += [f"Latest captured candidate: {candidate or 'none'}",
              f"Candidate checks: {check_status}",
              f"Last passing candidate: {value.get('last_passing_candidate_sha') or 'none'}",
              f"Outcome: {directory / 'outcome.json'}", f"Run files/logs: {directory}"]
    for label, path in (("Baseline logs", directory / "baseline"),
                        ("Session logs", directory / "sessions" / f"{value.get('sessions', 0):04d}"),
                        ("Execution logs", directory / "operations")):
        if path.is_dir():
            lines.append(f"{label}: {path}")
    artifacts = value.get("artifacts", {})
    if artifacts.get("workspace"):
        lines.append(f"Retained workspace: {artifacts['workspace']}")
    def inspect_command(command):
        return shlex.join([*launcher, command, value["run_id"], "--runs-dir", str(directory.parent)])
    lines.append(f"Show: {inspect_command('show')}")
    if artifacts.get("patch") and Path(artifacts["patch"]).is_file():
        lines += [f"Patch: {artifacts['patch']}", f"Diff: {inspect_command('diff')}"]
    else:
        lines.append("No exported patch; inspect retained work and diagnostics.")
    if artifacts.get("bundle") and Path(artifacts["bundle"]).is_file():
        lines.append(f"Bundle: {artifacts['bundle']}")
        command = shlex.join(["git", "clone", "--branch", "agentmill-candidate", "--",
                              artifacts["bundle"], f"./review-{value['run_id']}"])
        lines.append(f"Clean review checkout: {command}")
    lines.extend(f"Diagnostic: {error}" for error in value.get("errors", []))
    return "\n".join(lines)


def human_event(event, sink=None, launcher=("agentmill",)):
    kind = event["event"]
    if kind == "run.started":
        message = (f"Run:       {event['run_id']}\nSource:    {event['source']} @ {event['revision']}\n"
                   f"Workspace: {event['workspace']}\nAgent:     {event['agent']}\n"
                   f"Limits:    {event['max_sessions']} sessions, {event['max_duration']:g}s total; "
                   f"setup {event['setup_timeout']:g}s, session {event['session_timeout']:g}s, "
                   f"check {event['check_timeout']:g}s\n{event['input_policy']}\n"
                   f"Preparing source and baseline; run files: {Path(event['workspace']).parent}")
    elif kind == "session.started":
        message = f"\nSession {event['session']}/{event['max_sessions']}"
        if event.get("logs"):
            message += f"\n  Session logs: {event['logs']}"
    elif kind == "session.finished" and event.get("agent_status"):
        message = f"  Agent claim: {event['agent_status']}"
    elif kind == "candidate.captured":
        label = "Base revision" if event["session"] == 0 else "  Candidate captured"
        message = f"{label}: {event['candidate_sha']}"
    elif kind == "check.finished":
        label = "Baseline" if not event["session"] else "  Check"
        message = f"{label}: {event['status']} — {event['command']}"
    elif kind == "run.finished":
        message = "\n" + human_result(event, Path(event["outcome"]).parent, launcher)
    else:
        return
    (sink or OutputSink(sys.stderr)).write(message)


def make_spec(args):
    values = {}
    if args.spec:
        values = json.loads(args.spec.read_text(encoding="utf-8"))
        if not isinstance(values, dict):
            raise ValueError("spec must be a JSON object containing RunSpec fields")
    for name in RunSpec.__dataclass_fields__:
        value = getattr(args, name, None)
        if value is not None:
            values[name] = value
    values.setdefault("source", os.environ.get("REPO_PATH", str(Path.cwd())))
    values.setdefault("image", os.environ.get("AGENTMILL_IMAGE", DEFAULT_IMAGE))
    if not isinstance(values["source"], str) or not values["source"].strip():
        raise ValueError("source must be a nonempty string")
    if args.task_file:
        values["task"] = args.task_file.read_text(encoding="utf-8")
    if "task" not in values:
        mission = Path(values["source"]) / "MILL.md"
        if not mission.is_file():
            raise ValueError("provide --task or --task-file (or an optional MILL.md)")
        values["task"] = mission.read_text(encoding="utf-8")
    if "checks" not in values and os.environ.get("CHECK_CMD"):
        values["checks"] = [os.environ["CHECK_CMD"]]
    values.setdefault("checks", [])
    if Path(values["source"]).expanduser().exists():
        values["source"] = str(Path(values["source"]).expanduser().resolve())
    for name in ("agent_config", "auth_file", "check_dir"):
        if values.get(name):
            if not isinstance(values[name], str):
                raise ValueError(f"{name} must be a file path string")
            values[name] = str(Path(values[name]).expanduser().resolve(strict=True))
    try:
        return RunSpec(**values)
    except TypeError as error:
        raise ValueError(str(error)) from error


def inspect_run(args, launcher):
    if not re.fullmatch(r"r_[a-f0-9]{16}", args.run_id):
        raise ValueError("invalid run ID")
    directory = (args.runs_dir or runs_root()) / args.run_id
    if not directory.is_dir():
        raise ValueError("run not found")
    path = directory / "outcome.json"
    if not path.exists():
        if args.command == "diff":
            raise ValueError("run has no final outcome; candidate artifacts may be incomplete")
        value = {"run_id": args.run_id, "status": "unknown", "stop_reason": "no_terminal_outcome"}
    else:
        value = json.loads(path.read_text())
    if args.command == "diff":
        exported = value.get("artifacts", {}).get("patch")
        if not exported or not Path(exported).is_file():
            raise ValueError("run has no exported patch; inspect its outcome and preserved workspace")
        sys.stdout.buffer.write(Path(exported).read_bytes())
    elif args.json:
        print(json.dumps(value))
    else:
        with suppress(OSError):
            OutputSink(sys.stderr).write(human_result(value, directory, launcher))
    return 0


def main(argv=None, *, launcher=None):
    launcher = launcher or (str(Path(sys.argv[0]).absolute()),)
    diagnostics = OutputSink(sys.stderr)
    try:
        args = parser().parse_args(argv)
    except SystemExit as error:
        # Reserve exit 2 for a real run stopped at an execution limit.
        return 0 if error.code == 0 else 1
    try:
        if args.command != "run":
            return inspect_run(args, launcher)
        spec = make_spec(args)
        output = OutputSink(sys.stdout) if args.json else diagnostics
        def emit(event):
            if args.json:
                output.write(json.dumps(event))
            else:
                human_event(event, output, launcher)
        outcome = run(spec, on_event=emit, runs_dir=args.runs_dir)
        for error in outcome.errors if args.json else ():
            with suppress(OSError):
                diagnostics.write(error)
        return outcome.exit_code
    except (OSError, ValueError) as error:
        with suppress(OSError):
            diagnostics.write(f"agentmill: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main(launcher=(sys.executable, "-m", "agentmill.cli")))
