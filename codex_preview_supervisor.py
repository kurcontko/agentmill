#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import selectors
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_prompt_summary(prompt_file: Path) -> str:
    try:
        for line in prompt_file.read_text(encoding="utf-8").splitlines():
            text = line.strip()
            if text:
                return text[:240]
    except OSError:
        return ""
    return ""


def run_git(repo_dir: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo_dir), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def current_git_snapshot(repo_dir: Path) -> dict:
    status_lines = run_git(repo_dir, "status", "--porcelain").splitlines()
    diff_stat = run_git(repo_dir, "diff", "--stat")
    branch = run_git(repo_dir, "branch", "--show-current")
    commit = run_git(repo_dir, "rev-parse", "--short", "HEAD")
    return {
        "branch": branch,
        "commit": commit,
        "files_changed": len([line for line in status_lines if line.strip()]),
        "diff_stat": diff_stat,
    }


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def append_event(events_path: Path, event: dict) -> None:
    with events_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event) + "\n")


def render_summary(status: dict, recent_events: list[dict], diff_stat: str) -> str:
    lines = [
        "# Codex Agent Preview",
        "",
        f"- State: {status['state']}",
        f"- Iteration: {status['iteration']} / {status['max_iterations_display']}",
        f"- Last event: {status['last_event'] or 'n/a'}",
        f"- Current task: {status['current_task'] or 'n/a'}",
        f"- Last message: {status['last_message'] or 'n/a'}",
        f"- Files changed: {status['files_changed']}",
        f"- Branch: {status['branch'] or 'n/a'}",
        f"- Commit: {status['commit'] or 'n/a'}",
        f"- Completion promise seen: {'yes' if status['completion_promise_seen'] else 'no'}",
        f"- Updated at: {status['updated_at']}",
        "",
        "## Recent Events",
        "",
    ]

    if recent_events:
        for event in recent_events[-8:]:
            lines.append(f"- [{event['at']}] {event['label']}")
    else:
        lines.append("- No recent events yet.")

    lines.extend(["", "## Diff Stat", "", "```text", diff_stat or "No diff.", "```", ""])
    return "\n".join(lines)


def normalize_event(payload: dict) -> dict | None:
    event_type = payload.get("type", "")
    item = payload.get("item") or {}

    if event_type in {"thread.started", "turn.started", "turn.completed", "turn.failed", "error"}:
        return {"type": event_type, "kind": "system", "label": event_type}

    if event_type.startswith("item."):
        item_id = item.get("id", "")
        item_type = item.get("type", "unknown")
        item_status = item.get("status", "")

        if item_type == "agent_message":
            full_text = (item.get("text") or "").strip()
            short = full_text.replace("\n", " ")[:160]
            return {
                "type": event_type,
                "kind": "message",
                "id": item_id,
                "label": f"agent_message: {short}",
                "text": full_text,
            }

        if item_type == "reasoning":
            summary_parts = item.get("summary") or []
            summary_text = ""
            if isinstance(summary_parts, list):
                summary_text = "\n".join(
                    part.get("text", "") for part in summary_parts
                    if isinstance(part, dict) and part.get("text")
                ).strip()
            content_parts = item.get("content") or []
            content_text = ""
            if isinstance(content_parts, list):
                content_text = "\n".join(
                    part.get("text", "") for part in content_parts
                    if isinstance(part, dict) and part.get("text")
                ).strip()
            display_text = summary_text or content_text
            short = display_text.replace("\n", " ")[:160] if display_text else "thinking..."
            return {
                "type": event_type,
                "kind": "reasoning",
                "id": item_id,
                "label": f"reasoning: {short}",
                "text": display_text,
                "status": item_status,
            }

        if item_type == "command_execution":
            command = (item.get("command") or "").strip()
            output = (item.get("aggregated_output") or "").strip()
            exit_code = item.get("exit_code")
            short_cmd = command.replace("\n", " ")[:160]
            return {
                "type": event_type,
                "kind": "command",
                "id": item_id,
                "label": f"command ({item_status}): {short_cmd}",
                "command": command,
                "output": output[:8000] if output else "",
                "exit_code": exit_code,
                "status": item_status,
            }

        return {
            "type": event_type,
            "kind": "tool",
            "id": item_id,
            "label": f"{item_type}: {item_status or 'n/a'}",
            "status": item_status,
        }

    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Codex exec with JSON output and derive preview state.")
    parser.add_argument("--repo-dir", required=True)
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--agent-id", required=True)
    parser.add_argument("--iteration", type=int, required=True)
    parser.add_argument("--max-iterations", type=int, default=0)
    parser.add_argument("--model", default="")
    parser.add_argument("--completion-promise", default="")
    parser.add_argument("--preview-app-url", default="")
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir)
    prompt_file = Path(args.prompt_file)
    state_dir = Path(args.log_dir) / "codex-preview" / f"agent-{args.agent_id}"
    runs_dir = state_dir / "runs"
    state_dir.mkdir(parents=True, exist_ok=True)
    runs_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    raw_jsonl_path = runs_dir / f"{timestamp}_iter{args.iteration}.jsonl"
    stderr_log_path = runs_dir / f"{timestamp}_iter{args.iteration}.stderr.log"
    events_path = state_dir / "events.ndjson"
    recent_events_path = state_dir / "recent-events.json"
    status_path = state_dir / "status.json"
    summary_path = state_dir / "summary.md"
    diff_stat_path = state_dir / "diff-stat.txt"
    last_message_path = state_dir / "last-message.txt"

    prompt_summary = read_prompt_summary(prompt_file)
    git_snapshot = current_git_snapshot(repo_dir)
    recent_events: list[dict] = []

    status = {
        "state": "running",
        "iteration": args.iteration,
        "max_iterations": args.max_iterations,
        "max_iterations_display": args.max_iterations if args.max_iterations > 0 else "infinite",
        "started_at": now_iso(),
        "updated_at": now_iso(),
        "last_event": "",
        "current_task": prompt_summary,
        "last_message": "",
        "last_exit_code": None,
        "files_changed": git_snapshot["files_changed"],
        "branch": git_snapshot["branch"],
        "commit": git_snapshot["commit"],
        "completion_promise_seen": False,
        "preview_app_url": args.preview_app_url,
        "raw_jsonl_path": str(raw_jsonl_path.relative_to(Path(args.log_dir))),
        "stderr_log_path": str(stderr_log_path.relative_to(Path(args.log_dir))),
    }

    write_json(status_path, status)
    diff_stat_path.write_text(git_snapshot["diff_stat"] + ("\n" if git_snapshot["diff_stat"] else ""), encoding="utf-8")
    summary_path.write_text(render_summary(status, list(recent_events), git_snapshot["diff_stat"]), encoding="utf-8")

    command = ["codex", "exec", "--full-auto", "--json", "-C", str(repo_dir)]
    if args.model:
        command.extend(["-m", args.model])
    command.append("-")

    with prompt_file.open("rb") as stdin_handle, raw_jsonl_path.open("w", encoding="utf-8") as stdout_handle, stderr_log_path.open("w", encoding="utf-8") as stderr_handle:
        process = subprocess.Popen(
            command,
            stdin=stdin_handle,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

        assert process.stdout is not None
        assert process.stderr is not None

        stream_selector = selectors.DefaultSelector()
        stream_selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        stream_selector.register(process.stderr, selectors.EVENT_READ, "stderr")

        signal_path = state_dir / "stop.signal"

        while stream_selector.get_map():
            # Check for stop signal
            if signal_path.exists():
                try:
                    signal_path.unlink()
                except OSError:
                    pass
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                status["state"] = "stopped"
                status["updated_at"] = now_iso()
                write_json(status_path, status)
                summary_path.write_text(render_summary(status, list(recent_events), git_snapshot["diff_stat"]), encoding="utf-8")
                return 130  # conventional SIGINT exit code

            for key, _ in stream_selector.select(timeout=0.5):
                line = key.fileobj.readline()
                if line == "":
                    stream_selector.unregister(key.fileobj)
                    continue

                if key.data == "stderr":
                    sys.stderr.write(line)
                    sys.stderr.flush()
                    stderr_handle.write(line)
                    stderr_handle.flush()
                    continue

                stdout_handle.write(line)
                stdout_handle.flush()

                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    continue

                status["updated_at"] = now_iso()
                status["last_event"] = payload.get("type", "")
                normalized = normalize_event(payload)
                if normalized is not None:
                    normalized["at"] = status["updated_at"]
                    recent_events.append(normalized)
                    append_event(events_path, normalized)
                    recent_events_path.write_text(json.dumps(list(recent_events), indent=2) + "\n", encoding="utf-8")

                item = payload.get("item") or {}
                if item.get("type") == "agent_message":
                    message_text = (item.get("text") or "").strip()
                    if message_text:
                        status["last_message"] = message_text
                        last_message_path.write_text(message_text + "\n", encoding="utf-8")
                        if args.completion_promise and args.completion_promise in message_text:
                            status["completion_promise_seen"] = True

                git_snapshot = current_git_snapshot(repo_dir)
                status["files_changed"] = git_snapshot["files_changed"]
                status["branch"] = git_snapshot["branch"]
                status["commit"] = git_snapshot["commit"]
                diff_stat_path.write_text(git_snapshot["diff_stat"] + ("\n" if git_snapshot["diff_stat"] else ""), encoding="utf-8")
                write_json(status_path, status)
                summary_path.write_text(render_summary(status, list(recent_events), git_snapshot["diff_stat"]), encoding="utf-8")

        process.wait()

    git_snapshot = current_git_snapshot(repo_dir)
    status["updated_at"] = now_iso()
    status["last_exit_code"] = process.returncode
    status["state"] = "iteration_complete" if process.returncode == 0 else "iteration_failed"
    status["files_changed"] = git_snapshot["files_changed"]
    status["branch"] = git_snapshot["branch"]
    status["commit"] = git_snapshot["commit"]
    diff_stat_path.write_text(git_snapshot["diff_stat"] + ("\n" if git_snapshot["diff_stat"] else ""), encoding="utf-8")
    write_json(status_path, status)
    summary_path.write_text(render_summary(status, list(recent_events), git_snapshot["diff_stat"]), encoding="utf-8")

    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())
