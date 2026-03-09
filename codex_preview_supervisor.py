#!/usr/bin/env python3
"""Codex supervisor — runs codex exec and writes normalized state files for the dashboard."""
from __future__ import annotations

import argparse
import json
import selectors
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_prompt_summary(path: Path) -> str:
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            text = line.strip()
            if text:
                return text[:240]
    except OSError:
        pass
    return ""


def run_git(repo: Path, *args: str) -> str:
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)
    return r.stdout.strip() if r.returncode == 0 else ""


def git_snapshot(repo: Path) -> dict:
    status = run_git(repo, "status", "--porcelain").splitlines()
    return {
        "branch": run_git(repo, "branch", "--show-current"),
        "commit": run_git(repo, "rev-parse", "--short", "HEAD"),
        "files_changed": len([l for l in status if l.strip()]),
        "diff_stat": run_git(repo, "diff", "--stat"),
    }


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Event normalization — Codex JSON events → canonical dashboard schema
# ---------------------------------------------------------------------------

_SYSTEM_EVENTS = frozenset({
    "thread.started", "turn.started", "turn.completed", "turn.failed", "error",
})

_ITEM_NORMALIZERS: dict[str, callable] = {}


def _normalizer(name: str):
    def decorator(fn):
        _ITEM_NORMALIZERS[name] = fn
        return fn
    return decorator


@_normalizer("agent_message")
def _norm_message(etype: str, iid: str, status: str, item: dict) -> dict:
    text = (item.get("text") or "").strip()
    return {"type": etype, "kind": "message", "id": iid, "label": f"agent_message: {text[:160]}", "text": text}


@_normalizer("reasoning")
def _norm_reasoning(etype: str, iid: str, status: str, item: dict) -> dict:
    def _extract(parts):
        if isinstance(parts, list):
            return "\n".join(p.get("text", "") for p in parts if isinstance(p, dict) and p.get("text")).strip()
        return ""

    text = _extract(item.get("summary")) or _extract(item.get("content"))
    short = text.replace("\n", " ")[:160] if text else "thinking..."
    return {"type": etype, "kind": "reasoning", "id": iid, "label": f"reasoning: {short}", "text": text, "status": status}


@_normalizer("command_execution")
def _norm_command(etype: str, iid: str, status: str, item: dict) -> dict:
    cmd = (item.get("command") or "").strip()
    output = (item.get("aggregated_output") or "").strip()
    return {
        "type": etype, "kind": "command", "id": iid,
        "label": f"command ({status}): {cmd[:160]}",
        "command": cmd, "output": output[:8000], "exit_code": item.get("exit_code"), "status": status,
    }


def normalize_event(payload: dict) -> dict | None:
    etype = payload.get("type", "")

    if etype in _SYSTEM_EVENTS:
        return {"type": etype, "kind": "system", "label": etype}

    if etype.startswith("item."):
        item = payload.get("item") or {}
        iid = item.get("id", "")
        itype = item.get("type", "unknown")
        istatus = item.get("status", "")

        normalizer = _ITEM_NORMALIZERS.get(itype)
        if normalizer:
            return normalizer(etype, iid, istatus, item)
        return {"type": etype, "kind": "tool", "id": iid, "label": f"{itype}: {istatus or 'n/a'}", "status": istatus}

    return None


# ---------------------------------------------------------------------------
# Main — spawn codex, stream events, write state files
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Run Codex with preview supervision")
    parser.add_argument("--repo-dir", required=True)
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--agent-id", required=True)
    parser.add_argument("--iteration", type=int, required=True)
    parser.add_argument("--max-iterations", type=int, default=0)
    parser.add_argument("--model", default="")
    parser.add_argument("--preview-app-url", default="")
    args = parser.parse_args()

    repo = Path(args.repo_dir)
    prompt = Path(args.prompt_file)
    state_dir = Path(args.log_dir) / "codex-preview" / f"agent-{args.agent_id}"
    runs_dir = state_dir / "runs"
    state_dir.mkdir(parents=True, exist_ok=True)
    runs_dir.mkdir(parents=True, exist_ok=True)

    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    raw_path = runs_dir / f"{ts}_iter{args.iteration}.jsonl"
    stderr_path = runs_dir / f"{ts}_iter{args.iteration}.stderr.log"
    events_ndjson = state_dir / "events.ndjson"
    recent_path = state_dir / "recent-events.json"
    status_path = state_dir / "status.json"
    diff_path = state_dir / "diff-stat.txt"
    msg_path = state_dir / "last-message.txt"

    snap = git_snapshot(repo)

    # Preserve events across iterations for dashboard continuity
    recent: list[dict] = []
    if recent_path.exists():
        try:
            recent = json.loads(recent_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass

    status = {
        "state": "running",
        "iteration": args.iteration,
        "max_iterations": args.max_iterations,
        "max_iterations_display": args.max_iterations if args.max_iterations > 0 else "infinite",
        "started_at": now_iso(),
        "updated_at": now_iso(),
        "last_event": "",
        "current_task": read_prompt_summary(prompt),
        "last_message": "",
        "last_exit_code": None,
        "files_changed": snap["files_changed"],
        "branch": snap["branch"],
        "commit": snap["commit"],
        "preview_app_url": args.preview_app_url,
        "raw_jsonl_path": str(raw_path.relative_to(Path(args.log_dir))),
        "stderr_log_path": str(stderr_path.relative_to(Path(args.log_dir))),
    }
    write_json(status_path, status)
    diff_path.write_text(snap["diff_stat"] + ("\n" if snap["diff_stat"] else ""), encoding="utf-8")

    # Build codex command
    cmd = ["codex", "exec", "--full-auto", "--json", "-C", str(repo)]
    if args.model:
        cmd.extend(["-m", args.model])
    cmd.append("-")

    with prompt.open("rb") as stdin_f, raw_path.open("w", encoding="utf-8") as raw_f, stderr_path.open("w", encoding="utf-8") as err_f:
        proc = subprocess.Popen(cmd, stdin=stdin_f, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        assert proc.stdout is not None and proc.stderr is not None

        sel = selectors.DefaultSelector()
        sel.register(proc.stdout, selectors.EVENT_READ, "stdout")
        sel.register(proc.stderr, selectors.EVENT_READ, "stderr")

        stop_path = state_dir / "stop.signal"
        last_git = 0.0

        while sel.get_map():
            # Stop signal check
            if stop_path.exists():
                try:
                    stop_path.unlink()
                except OSError:
                    pass
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                status["state"] = "stopped"
                status["updated_at"] = now_iso()
                write_json(status_path, status)
                return 130

            for key, _ in sel.select(timeout=0.5):
                line = key.fileobj.readline()
                if line == "":
                    sel.unregister(key.fileobj)
                    continue

                if key.data == "stderr":
                    sys.stderr.write(line)
                    sys.stderr.flush()
                    err_f.write(line)
                    err_f.flush()
                    continue

                raw_f.write(line)
                raw_f.flush()

                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    continue

                status["updated_at"] = now_iso()
                status["last_event"] = payload.get("type", "")

                normalized = normalize_event(payload)
                if normalized:
                    normalized["at"] = status["updated_at"]
                    recent.append(normalized)
                    if len(recent) > 200:
                        recent = recent[-200:]
                    with events_ndjson.open("a", encoding="utf-8") as f:
                        f.write(json.dumps(normalized) + "\n")
                    recent_path.write_text(json.dumps(recent) + "\n", encoding="utf-8")

                item = payload.get("item") or {}
                if item.get("type") == "agent_message":
                    text = (item.get("text") or "").strip()
                    if text:
                        status["last_message"] = text
                        msg_path.write_text(text + "\n", encoding="utf-8")

                # Throttle git checks to avoid spawning too many processes
                now = time.monotonic()
                if now - last_git >= 2.0:
                    last_git = now
                    snap = git_snapshot(repo)
                    status["files_changed"] = snap["files_changed"]
                    status["branch"] = snap["branch"]
                    status["commit"] = snap["commit"]
                    diff_path.write_text(snap["diff_stat"] + ("\n" if snap["diff_stat"] else ""), encoding="utf-8")

                write_json(status_path, status)

        proc.wait()

    # Final status update
    snap = git_snapshot(repo)
    status["updated_at"] = now_iso()
    status["last_exit_code"] = proc.returncode
    status["state"] = "iteration_complete" if proc.returncode == 0 else "iteration_failed"
    status["files_changed"] = snap["files_changed"]
    status["branch"] = snap["branch"]
    status["commit"] = snap["commit"]
    diff_path.write_text(snap["diff_stat"] + ("\n" if snap["diff_stat"] else ""), encoding="utf-8")
    write_json(status_path, status)

    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
