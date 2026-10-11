"""The small command-line surface: run, verify, list, show and diff."""

import argparse
from contextlib import suppress
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tomllib

from .contracts import DEFAULT_IMAGE, RunSpec
from .output import OutputSink
from .records import runs_root
from .runner import run, verify


def duration(value):
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([smh]?)", value)
    if not match:
        raise argparse.ArgumentTypeError("duration must be seconds or use s, m, h (for example 30m)")
    seconds = float(match[1]) * {"": 1, "s": 1, "m": 60, "h": 3600}[match[2]]
    if seconds <= 0:
        raise argparse.ArgumentTypeError("duration must be positive")
    return seconds


VERIFY_EXAMPLES = """examples:
  agentmill verify . --revision my-branch --check "uv run pytest -q"
  agentmill verify . --spec job.toml --check-dir ./acceptance
  agentmill verify RUN_DIR/artifacts/result.bundle --revision agentmill-best --spec job.toml

exit codes: 0 every check passed, 1 failure, 2 a check failed, 130/143 cancelled"""


RUN_EXAMPLES = """examples:
  agentmill run . --agent claude --task "Fix the flaky retry test" --check "uv run pytest -q"
  agentmill run ../api --agent codex --task-file task.md --setup "npm ci" --check "npm test"
  agentmill run . --agent claude --task-file task.md --check "pytest -q /checks" --check-dir ./acceptance
  agentmill run . --spec job.toml --max-sessions 40 --max-duration 8h --stall-sessions 3

exit codes: 0 checked complete, 1 failure, 2 incomplete at a limit, 3 blocked, 130/143 cancelled"""


def parser():
    root = argparse.ArgumentParser(
        prog="agentmill", description="Run codex exec or claude -p on one task in a private checkout, "
        "check the result in a clean container, and return an explicit verdict.")
    commands = root.add_subparsers(dest="command", required=True)
    launch = commands.add_parser("run", help="run one task in a private checkout",
                                 description="Run one task from a committed revision. Your checkout is never "
                                 "modified; results are exported as a patch and a Git bundle.",
                                 epilog=RUN_EXAMPLES, formatter_class=argparse.RawDescriptionHelpFormatter)
    launch.add_argument("source", nargs="?", help="Git checkout root, Git URL or bundle "
                        "(default: $REPO_PATH, then the current directory)")
    launch.add_argument("--spec", type=Path, help="job file with RunSpec fields (.toml or JSON), including "
                        "named checks; explicit flags override it")
    launch.add_argument("--revision", help="committed revision to start from (default: HEAD)")
    task = launch.add_mutually_exclusive_group()
    task.add_argument("--task", help="task text (default: MILL.md in the source, if present)")
    task.add_argument("--task-file", type=Path, help="read the task text from a file")
    launch.add_argument("--agent", choices=("codex", "claude"), help="native CLI to run (default: codex)")
    launch.add_argument("--model", help="model name or alias passed to the native CLI")
    launch.add_argument("--profile", help="Codex profile name, used with --agent-config")
    launch.add_argument("--agent-config", help="explicit native config file (Codex TOML or Claude settings JSON)")
    launch.add_argument("--auth-file", help="explicit Codex auth.json; never exposed to checks")
    launch.add_argument("--credential-env", action="append", metavar="NAME",
                        help="forward this environment variable to the worker instead of the defaults "
                        "(CODEX_API_KEY; ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN); repeatable")
    launch.add_argument("--setup", help="shell command run in every fresh container before work or checks "
                        "(default: true)")
    launch.add_argument("--check", action="append", dest="checks", metavar="CMD",
                        help="check command that must pass on the captured result; repeatable, at least one "
                        "(default: $CHECK_CMD)")
    launch.add_argument("--check-dir", help="held-out check files, mounted read-only at /checks "
                        "in check containers only; the worker never receives them")
    launch.add_argument("--max-sessions", "--iterations", type=int, dest="max_sessions",
                        help="native CLI invocations to allow (default: 3)")
    launch.add_argument("--stall-sessions", type=int, metavar="N",
                        help="stop after N consecutive sessions in which no new check passes (default: off)")
    launch.add_argument("--max-duration", type=duration, metavar="DURATION",
                        help="total run budget, e.g. 45m (default: 30m)")
    for phase, default in (("setup", "5m"), ("session", "15m"), ("check", "5m")):
        launch.add_argument(f"--{phase}-timeout", type=duration, metavar="DURATION",
                            help=f"limit for each {phase} (default: {default})")
    launch.add_argument("--image", help=f"runtime image (default: $AGENTMILL_IMAGE, then {DEFAULT_IMAGE})")
    launch.add_argument("--json", action="store_true", help="emit only AgentMill JSONL events on stdout")
    launch.add_argument("--runs-dir", type=Path, help="run storage directory "
                        "(default: $XDG_STATE_HOME/agentmill/runs or ~/.local/state/agentmill/runs)")
    check = commands.add_parser("verify", help="check one committed revision without running an agent",
                                description="Run the checks on one committed revision in fresh containers "
                                "with no supplied agent credentials and report each check's result.",
                                epilog=VERIFY_EXAMPLES, formatter_class=argparse.RawDescriptionHelpFormatter)
    check.add_argument("source", nargs="?", help="Git checkout root, Git URL or bundle "
                       "(default: $REPO_PATH, then the current directory)")
    check.add_argument("--spec", type=Path, help="job file (.toml or JSON); only check fields are used")
    check.add_argument("--revision", help="committed revision to check (default: HEAD)")
    check.add_argument("--check", action="append", dest="checks", metavar="CMD",
                       help="check command; repeatable, at least one (default: $CHECK_CMD)")
    check.add_argument("--check-dir", help="held-out check files, mounted read-only at /checks")
    check.add_argument("--setup", help="shell command run in each fresh check container (default: true)")
    check.add_argument("--max-duration", type=duration, metavar="DURATION", help="total budget (default: 30m)")
    for phase in ("setup", "check"):
        check.add_argument(f"--{phase}-timeout", type=duration, metavar="DURATION",
                           help=f"limit for each {phase} (default: 5m)")
    check.add_argument("--image", help=f"runtime image (default: $AGENTMILL_IMAGE, then {DEFAULT_IMAGE})")
    check.add_argument("--json", action="store_true", help="emit only AgentMill JSONL events on stdout")
    check.add_argument("--runs-dir", type=Path, help="run storage directory")
    listing = commands.add_parser("list", help="list retained runs, newest first")
    listing.add_argument("--runs-dir", type=Path, help="run storage directory")
    listing.add_argument("--limit", type=int, default=20, help="number of runs to show (default: 20)")
    listing.add_argument("--json", action="store_true", help="one JSON object per run")
    for name, text in (("show", "summarize a run's outcome"), ("diff", "print a run's exported patch")):
        inspect = commands.add_parser(name, help=text)
        inspect.add_argument("run_id", help="run ID, or `latest`")
        inspect.add_argument("--runs-dir", type=Path, help="run storage directory")
        if name == "show":
            inspect.add_argument("--json", action="store_true", help="print outcome.json")
        else:
            inspect.add_argument("--best", action="store_true",
                                 help="print the best candidate's patch when it differs from the latest")
    return root


def short(sha):
    return sha[:12] if sha else "none"


def human_result(value, directory, launcher=("agentmill",)):
    directory = Path(directory).resolve()
    check_status = value.get("candidate_check_status", "unknown (see recorded checks)")
    lines = [f"Run: {value['run_id']}", f"Result: {value['status']} ({value['stop_reason']})"]
    reply = value.get("agent_reply") or {}
    for field, label in (("summary", "Agent summary"), ("question", "Question"), ("next_step", "Next step")):
        if reply.get(field):
            lines.append(f"{label}: {reply[field]}")
    ledger = value.get("ledger") or {}
    if value.get("mode") == "verify":
        lines.append(f"Revision: {short(value.get('base_revision'))} (checks {check_status})")
    else:
        lines.append(f"Candidate: {short(value.get('latest_candidate_sha'))} (checks {check_status}); "
                     f"last passing: {short(value.get('last_passing_candidate_sha'))}")
    if ledger.get("total"):
        failing = [name for name, status in ledger.get("latest", {}).items() if status != "passed"]
        line = f"Checks: {len(ledger['latest']) - len(failing)}/{ledger['total']} pass"
        if value.get("mode") != "verify":
            line += " on the last checked candidate"
        if failing:
            line += " (not passing: " + ", ".join(failing) + ")"
        if value.get("mode") != "verify" and ledger.get("best_candidate_sha") != value.get("latest_candidate_sha"):
            line += (f"; best candidate {short(ledger.get('best_candidate_sha'))} passes "
                     f"{len(ledger.get('best_passed', []))}/{ledger['total']}")
        if ledger.get("regressed"):
            line += "; regressed: " + ", ".join(ledger["regressed"])
        lines.append(line)
    lines.append(f"Run files: {directory} (outcome.json, ledger.json, sessions/, operations/)")
    if value.get("mode") == "verify":
        lines.append(f"Show: {shlex.join([*launcher, 'show', value['run_id'], '--runs-dir', str(directory.parent)])}")
        lines.extend(f"Diagnostic: {error}" for error in value.get("errors", []))
        return "\n".join(lines)
    artifacts = value.get("artifacts", {})
    if artifacts.get("workspace"):
        lines.append(f"Retained workspace: {artifacts['workspace']}")
    def inspect_command(command):
        return shlex.join([*launcher, command, value["run_id"], "--runs-dir", str(directory.parent)])
    lines.append(f"Show: {inspect_command('show')}")
    patch = Path(artifacts["patch"]) if artifacts.get("patch") else None
    if patch and patch.is_file() and patch.stat().st_size:
        lines += [f"Patch: {patch}", f"Diff: {inspect_command('diff')}"]
        if artifacts.get("bundle") and Path(artifacts["bundle"]).is_file():
            command = shlex.join(["git", "clone", "--branch", "agentmill-candidate", "--",
                                  artifacts["bundle"], f"./review-{value['run_id']}"])
            lines.append(f"Clean review checkout: {command}")
    elif patch and patch.is_file():
        lines.append("No changes from the base revision.")
    else:
        lines.append("No exported patch; inspect retained work and diagnostics.")
    if artifacts.get("best_patch"):
        lines.append(f"Best patch (latest candidate lost a check): {artifacts['best_patch']} "
                     f"({inspect_command('diff')} --best)")
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
    elif kind == "verify.started":
        message = (f"Verify:    {event['run_id']}\nSource:    {event['source']} @ {event['revision']}\n"
                   f"Checks:    {', '.join(event['checks'])}\n{event['input_policy']}")
    elif kind == "session.started":
        message = f"\nSession {event['session']}/{event['max_sessions']}"
        if event.get("logs"):
            message += f"\n  Session logs: {event['logs']}"
    elif kind == "session.progress":
        minutes, seconds = divmod(int(event["elapsed_seconds"]), 60)
        message = f"  … {minutes}m{seconds:02d}s elapsed, {event['native_events']} native events"
    elif kind == "session.finished" and event.get("agent_status"):
        message = f"  Agent claim: {event['agent_status']}"
    elif kind == "session.finished" and event.get("stop_reason"):
        message = f"  Session ended: {event['stop_reason']}"
    elif kind == "candidate.captured":
        label = "Base revision" if event["session"] == 0 else "  Candidate captured"
        message = f"{label}: {event['candidate_sha']}"
    elif kind == "check.finished":
        label = "Baseline" if not event["session"] else "  Check"
        name = f"{event['check_id']}: " if event.get("check_id") and not event["check_id"].startswith("check-") else ""
        message = f"{label}: {event['status']} — {name}{event['command']}"
    elif kind == "run.finished":
        message = "\n" + human_result(event, Path(event["outcome"]).parent, launcher)
    else:
        return
    (sink or OutputSink(sys.stderr)).write(message)


def make_spec(args):
    values = {}
    if args.spec:
        text = args.spec.read_text(encoding="utf-8")
        try:
            values = tomllib.loads(text) if args.spec.suffix == ".toml" else json.loads(text)
        except tomllib.TOMLDecodeError as error:
            raise ValueError(f"{args.spec}: {error}") from error
        if not isinstance(values, dict):
            raise ValueError("spec must be a JSON object containing RunSpec fields")
        for name in ("max_duration", "setup_timeout", "session_timeout", "check_timeout"):
            if isinstance(values.get(name), str):
                try:
                    values[name] = duration(values[name])
                except argparse.ArgumentTypeError as error:
                    raise ValueError(f"{name}: {error}") from error
        if args.command == "verify":
            # Verification uses the job's check fields; agent and session fields do not apply.
            values = {k: v for k, v in values.items() if k in VERIFY_FIELDS}
    for name in RunSpec.__dataclass_fields__:
        value = getattr(args, name, None)
        if value is not None:
            values[name] = value
    values.setdefault("source", os.environ.get("REPO_PATH", str(Path.cwd())))
    values.setdefault("image", os.environ.get("AGENTMILL_IMAGE", DEFAULT_IMAGE))
    if not isinstance(values["source"], str) or not values["source"].strip():
        raise ValueError("source must be a nonempty string")
    if args.command == "verify":
        values["task"] = "Verify checks; no agent runs."
    if getattr(args, "task_file", None):
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


VERIFY_FIELDS = {"source", "revision", "checks", "check_dir", "setup", "image",
                 "max_duration", "setup_timeout", "check_timeout"}


def retained_runs(root):
    """Runs newest first, ordered by their recorded start rather than directory times."""
    runs = []
    for directory in Path(root).glob("r_*"):
        if not re.fullmatch(r"r_[a-f0-9]{16}", directory.name) or not directory.is_dir():
            continue
        started = ""
        with suppress(OSError, ValueError, KeyError):
            with (directory / "events.jsonl").open(encoding="utf-8") as stream:
                started = json.loads(stream.readline())["timestamp"]
        runs.append((started, directory))
    return [directory for _, directory in sorted(runs, reverse=True)]


def list_runs(args):
    for directory in retained_runs(args.runs_dir or runs_root())[:max(args.limit, 0)]:
        value = {"run_id": directory.name, "status": "unknown", "stop_reason": "no_terminal_outcome"}
        with suppress(OSError, ValueError):
            value = json.loads((directory / "outcome.json").read_text())
        started = source = ""
        with suppress(OSError, ValueError, KeyError):
            with (directory / "events.jsonl").open(encoding="utf-8") as stream:
                first = json.loads(stream.readline())
            started, source = first["timestamp"], first.get("source", "")
        if args.json:
            print(json.dumps({"run_id": directory.name, "started": started, "source": source,
                              "status": value["status"], "stop_reason": value["stop_reason"],
                              "sessions": value.get("sessions")}))
        else:
            print(f"{directory.name}  {started[:19]}  {value['status']:<16} {value['stop_reason']:<26} {source}")
    return 0


def inspect_run(args, launcher):
    root = args.runs_dir or runs_root()
    if args.run_id == "latest":
        runs = retained_runs(root)
        if not runs:
            raise ValueError(f"no runs in {root}")
        args.run_id = runs[0].name
    if not re.fullmatch(r"r_[a-f0-9]{16}", args.run_id):
        raise ValueError("invalid run ID")
    directory = root / args.run_id
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
        exported = value.get("artifacts", {}).get("best_patch" if args.best else "patch")
        if args.best and not exported:
            raise ValueError("run has no separate best patch; the latest candidate is the best one")
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
        if args.command == "list":
            return list_runs(args)
        if args.command not in ("run", "verify"):
            return inspect_run(args, launcher)
        spec = make_spec(args)
        output = OutputSink(sys.stdout) if args.json else diagnostics
        def emit(event):
            if args.json:
                output.write(json.dumps(event))
            else:
                human_event(event, output, launcher)
        outcome = (verify if args.command == "verify" else run)(spec, on_event=emit, runs_dir=args.runs_dir)
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
