#!/usr/bin/env python3
"""
AgentMill Coordinator — Hierarchical Supervisor-Worker

A coordinator agent that reads TASK.md, decomposes tasks, assigns them to
worker agents, monitors progress, and gates merges. Workers poll the
coordinator for assignments and report heartbeats + completion.

Python 3.11+ stdlib only.

API
---
  POST /assign              body: {"worker_id": "..."}            -> 200 {"task": {...}} | 204 (none)
  POST /checkin             body: {"worker_id": "...", "task_id": "...", "status": "..."}
                                                                   -> 200 {"ok": true}
  POST /complete            body: {"worker_id": "...", "task_id": "...", "branch": "..."}
                                                                   -> 200 {"ok": true}
  POST /fail                body: {"worker_id": "...", "task_id": "...", "reason": "..."}
                                                                   -> 200 {"ok": true}
  GET  /status              -> 200 {"pending": N, "assigned": N, "done": N, "failed": N, "workers": [...]}
  GET  /tasks               -> 200 {"pending": [...], "assigned": [...], "done": [...], "failed": [...]}
  POST /submit_task         body: {"id": "...", "title": "...", "description": "...", "priority": 0}
                                                                   -> 201 {"ok": true}
  DELETE /task/<id>         -> 200 {"ok": true} | 404

State persisted to STATE_FILE. Stale assignments (no heartbeat > TTL) are
re-queued automatically. Workers that fail 3 times are marked failed and
removed from rotation.

Coordinator mode (run with --coordinator) also parses TASK.md on startup.
"""

import json
import logging
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("COORDINATOR_PORT", "3003"))
STATE_FILE = os.environ.get("COORDINATOR_STATE_FILE", "logs/coordinator_state.json")
TASK_MD_PATH = os.environ.get("TASK_MD_PATH", "TASK.md")
LOG_LEVEL = os.environ.get("COORDINATOR_LOG_LEVEL", "INFO")

# How long (seconds) a worker can go without a checkin before task is reassigned
HEARTBEAT_TTL = int(os.environ.get("HEARTBEAT_TTL", "120"))
# How often the coordinator scans for stale assignments (seconds)
REAP_INTERVAL = int(os.environ.get("REAP_INTERVAL", "30"))

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [coordinator] %(levelname)s %(message)s",
)
log = logging.getLogger("coordinator")


# ---------------------------------------------------------------------------
# Coordinator State
# ---------------------------------------------------------------------------

class CoordinatorState:
    """Thread-safe state for hierarchical task coordination."""

    def __init__(self, state_file: str) -> None:
        self.state_file = Path(state_file)
        self.lock = threading.Lock()

        # Task lists (dicts with id, title, description, priority, status, etc.)
        self.pending: list[dict] = []
        self.assigned: dict[str, dict] = {}   # task_id -> task + assignment info
        self.done: list[dict] = []
        self.failed: list[dict] = []

        # Worker registry: worker_id -> {last_seen, task_id, fail_count}
        self.workers: dict[str, dict] = {}

        self._load()

    # --- Persistence -------------------------------------------------------

    def _load(self) -> None:
        if self.state_file.exists():
            try:
                data = json.loads(self.state_file.read_text())
                self.pending = data.get("pending", [])
                self.assigned = data.get("assigned", {})
                self.done = data.get("done", [])
                self.failed = data.get("failed", [])
                self.workers = data.get("workers", {})
                # Re-queue in-flight tasks from a previous crash
                reassigned = 0
                for task_id, task in list(self.assigned.items()):
                    task["status"] = "pending"
                    task.pop("worker_id", None)
                    task.pop("assigned_at", None)
                    self.pending.insert(0, task)
                    reassigned += 1
                self.assigned.clear()
                if reassigned:
                    log.info("Crash recovery: re-queued %d in-flight tasks", reassigned)
                self._save()
            except Exception as exc:
                log.error("Failed to load state: %s — starting fresh", exc)

    def _save(self) -> None:
        """Must be called under self.lock."""
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps({
            "pending": self.pending,
            "assigned": self.assigned,
            "done": self.done,
            "failed": self.failed,
            "workers": self.workers,
        }, indent=2))
        tmp.replace(self.state_file)

    # --- Task submission ---------------------------------------------------

    def submit(self, task: dict) -> bool:
        """Add a task to the pending queue. Returns False if duplicate id."""
        with self.lock:
            task_id = task.get("id", "")
            all_ids = (
                {t["id"] for t in self.pending}
                | set(self.assigned.keys())
                | {t["id"] for t in self.done}
                | {t["id"] for t in self.failed}
            )
            if task_id in all_ids:
                return False
            task.setdefault("status", "pending")
            task.setdefault("priority", 0)
            task.setdefault("fail_count", 0)
            task.setdefault("created_at", time.time())
            # Higher priority first; stable sort by created_at for equal priority
            self.pending.append(task)
            self.pending.sort(key=lambda t: (-t.get("priority", 0), t.get("created_at", 0)))
            self._save()
            return True

    # --- Worker assignment -------------------------------------------------

    def assign(self, worker_id: str) -> dict | None:
        """Assign the next pending task to a worker. Returns task or None."""
        with self.lock:
            self._register_worker(worker_id)
            if not self.pending:
                return None
            task = self.pending.pop(0)
            task["status"] = "assigned"
            task["worker_id"] = worker_id
            task["assigned_at"] = time.time()
            self.assigned[task["id"]] = task
            self.workers[worker_id]["task_id"] = task["id"]
            self.workers[worker_id]["last_seen"] = time.time()
            self._save()
            log.info("Assigned task %s to worker %s", task["id"], worker_id)
            return task

    def checkin(self, worker_id: str, task_id: str, status: str = "working") -> bool:
        """Update worker heartbeat. Returns False if task not assigned to worker."""
        with self.lock:
            self._register_worker(worker_id)
            task = self.assigned.get(task_id)
            if not task or task.get("worker_id") != worker_id:
                return False
            self.workers[worker_id]["last_seen"] = time.time()
            self.workers[worker_id]["status"] = status
            task["last_checkin"] = time.time()
            task["worker_status"] = status
            self._save()
            return True

    def complete(self, worker_id: str, task_id: str, branch: str = "") -> bool:
        """Mark a task as done. Returns False if task not found."""
        with self.lock:
            task = self.assigned.pop(task_id, None)
            if not task:
                return False
            task["status"] = "done"
            task["completed_at"] = time.time()
            task["branch"] = branch
            task.pop("worker_id", None)
            self.done.append(task)
            if worker_id in self.workers:
                self.workers[worker_id]["task_id"] = None
                self.workers[worker_id]["last_seen"] = time.time()
            self._save()
            log.info("Task %s completed by worker %s (branch: %s)", task_id, worker_id, branch)
            return True

    def fail(self, worker_id: str, task_id: str, reason: str = "") -> bool:
        """Mark a task as failed. Re-queues up to MAX_RETRIES times."""
        max_retries = 3
        with self.lock:
            task = self.assigned.pop(task_id, None)
            if not task:
                return False
            task["fail_count"] = task.get("fail_count", 0) + 1
            task["last_failure"] = reason
            task.pop("worker_id", None)
            task.pop("assigned_at", None)
            if task["fail_count"] < max_retries:
                task["status"] = "pending"
                # Re-insert at front for priority retry
                self.pending.insert(0, task)
                log.warning("Task %s failed (attempt %d/%d), re-queued",
                            task_id, task["fail_count"], max_retries)
            else:
                task["status"] = "failed"
                self.failed.append(task)
                log.error("Task %s failed permanently after %d attempts: %s",
                          task_id, task["fail_count"], reason)
            if worker_id in self.workers:
                self.workers[worker_id]["fail_count"] = (
                    self.workers[worker_id].get("fail_count", 0) + 1
                )
                self.workers[worker_id]["task_id"] = None
            self._save()
            return True

    def delete(self, task_id: str) -> bool:
        """Remove a task from any queue. Returns False if not found."""
        with self.lock:
            for lst in (self.pending, self.done, self.failed):
                for i, t in enumerate(lst):
                    if t["id"] == task_id:
                        lst.pop(i)
                        self._save()
                        return True
            if task_id in self.assigned:
                del self.assigned[task_id]
                self._save()
                return True
            return False

    # --- Stale task reaper ------------------------------------------------

    def reap_stale(self) -> int:
        """Re-queue tasks from workers that stopped sending heartbeats."""
        now = time.time()
        reaped = 0
        with self.lock:
            for task_id, task in list(self.assigned.items()):
                last = task.get("last_checkin") or task.get("assigned_at", now)
                if now - last > HEARTBEAT_TTL:
                    worker_id = task.get("worker_id", "unknown")
                    log.warning("Reaping stale task %s from worker %s (no heartbeat for %.0fs)",
                                task_id, worker_id, now - last)
                    del self.assigned[task_id]
                    task["status"] = "pending"
                    task.pop("worker_id", None)
                    task.pop("assigned_at", None)
                    task.pop("last_checkin", None)
                    self.pending.insert(0, task)
                    reaped += 1
            if reaped:
                self._save()
        return reaped

    # --- Status -----------------------------------------------------------

    def status_snapshot(self) -> dict:
        with self.lock:
            return {
                "pending": len(self.pending),
                "assigned": len(self.assigned),
                "done": len(self.done),
                "failed": len(self.failed),
                "workers": [
                    {**v, "worker_id": k}
                    for k, v in self.workers.items()
                ],
            }

    def tasks_snapshot(self) -> dict:
        with self.lock:
            return {
                "pending": list(self.pending),
                "assigned": list(self.assigned.values()),
                "done": list(self.done),
                "failed": list(self.failed),
            }

    # --- Internal helpers -------------------------------------------------

    def _register_worker(self, worker_id: str) -> None:
        """Must be called under self.lock."""
        if worker_id not in self.workers:
            self.workers[worker_id] = {
                "first_seen": time.time(),
                "last_seen": time.time(),
                "task_id": None,
                "fail_count": 0,
                "status": "idle",
            }


# ---------------------------------------------------------------------------
# TASK.md Parser
# ---------------------------------------------------------------------------

TASK_PATTERN = re.compile(
    r"###\s+\[(?P<id>[A-Z0-9]+)\]\s+(?P<title>[^\n]+)\n"
    r"(?P<body>.*?)(?=\n###|\Z)",
    re.DOTALL,
)
STATUS_PATTERN = re.compile(r"\*\*Status\*\*:\s*`\[(?P<status>[^\]]+)\]`")
PRIORITY_MAP = {"P0": 30, "P1": 20, "P2": 10, "P3": 5}


def parse_task_md(path: str) -> list[dict]:
    """
    Parse TASK.md and return a list of task dicts for tasks not yet done.

    Each dict has: id, title, description, priority, branch, status_raw.
    """
    text = Path(path).read_text(errors="replace")
    tasks = []
    for m in TASK_PATTERN.finditer(text):
        task_id = m.group("id")
        title = m.group("title").strip()
        body = m.group("body")

        status_m = STATUS_PATTERN.search(body)
        status_raw = status_m.group("status") if status_m else " "

        # Skip already-done tasks
        if status_raw in ("x", "!"):
            continue

        # Extract branch if present
        branch_m = re.search(r"\*\*Branch\*\*:\s*`([^`]+)`", body)
        branch = branch_m.group(1) if branch_m else f"research/{task_id.lower()}"

        # Priority from heading context
        priority = 0
        for pkey, pval in PRIORITY_MAP.items():
            if f"## {pkey}" in text[: m.start()]:
                priority = pval

        tasks.append({
            "id": task_id,
            "title": title,
            "description": body.strip(),
            "branch": branch,
            "priority": priority,
            "status_raw": status_raw,
        })

    return tasks


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

class CoordinatorHandler(BaseHTTPRequestHandler):
    state: "CoordinatorState"  # set on class before use

    def log_message(self, fmt: str, *args: Any) -> None:  # silence default logs
        pass

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if not length:
            return {}
        return json.loads(self.rfile.read(length))

    def _send(self, code: int, body: Any) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/status":
            self._send(200, self.state.status_snapshot())

        elif path == "/tasks":
            self._send(200, self.state.tasks_snapshot())

        elif path == "/health":
            self._send(200, {"ok": True, "ts": time.time()})

        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/assign":
            body = self._read_json()
            worker_id = body.get("worker_id") or self.headers.get("X-Worker-Id", "unknown")
            task = self.state.assign(worker_id)
            if task:
                self._send(200, {"task": task})
            else:
                self._send(204, {"task": None})

        elif path == "/checkin":
            body = self._read_json()
            ok = self.state.checkin(
                body.get("worker_id", "unknown"),
                body.get("task_id", ""),
                body.get("status", "working"),
            )
            self._send(200 if ok else 404, {"ok": ok})

        elif path == "/complete":
            body = self._read_json()
            ok = self.state.complete(
                body.get("worker_id", "unknown"),
                body.get("task_id", ""),
                body.get("branch", ""),
            )
            self._send(200 if ok else 404, {"ok": ok})

        elif path == "/fail":
            body = self._read_json()
            ok = self.state.fail(
                body.get("worker_id", "unknown"),
                body.get("task_id", ""),
                body.get("reason", ""),
            )
            self._send(200 if ok else 404, {"ok": ok})

        elif path == "/submit_task":
            body = self._read_json()
            if not body.get("id") or not body.get("title"):
                self._send(400, {"error": "id and title required"})
                return
            ok = self.state.submit(body)
            self._send(201 if ok else 409, {"ok": ok})

        else:
            self._send(404, {"error": "not found"})

    def do_DELETE(self) -> None:
        path = self.path.rstrip("/")
        if path.startswith("/task/"):
            task_id = path[len("/task/"):]
            ok = self.state.delete(task_id)
            self._send(200 if ok else 404, {"ok": ok})
        else:
            self._send(404, {"error": "not found"})


# ---------------------------------------------------------------------------
# Reaper Thread
# ---------------------------------------------------------------------------

def reaper_loop(state: CoordinatorState) -> None:
    """Background thread: re-queue stale assignments."""
    while True:
        time.sleep(REAP_INTERVAL)
        try:
            n = state.reap_stale()
            if n:
                log.info("Reaper: re-queued %d stale tasks", n)
        except Exception as exc:
            log.error("Reaper error: %s", exc)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="AgentMill Coordinator")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--state-file", default=STATE_FILE)
    parser.add_argument("--task-md", default=TASK_MD_PATH,
                        help="Path to TASK.md to seed tasks on startup")
    parser.add_argument("--no-seed", action="store_true",
                        help="Skip seeding from TASK.md")
    args = parser.parse_args()

    state = CoordinatorState(args.state_file)

    # Seed tasks from TASK.md if available
    if not args.no_seed and Path(args.task_md).exists():
        tasks = parse_task_md(args.task_md)
        seeded = 0
        for task in tasks:
            if state.submit(task):
                seeded += 1
        if seeded:
            log.info("Seeded %d tasks from %s", seeded, args.task_md)

    # Start reaper thread
    t = threading.Thread(target=reaper_loop, args=(state,), daemon=True)
    t.start()

    # Start HTTP server
    CoordinatorHandler.state = state
    server = HTTPServer(("", args.port), CoordinatorHandler)
    log.info("Coordinator listening on port %d", args.port)
    log.info("State file: %s", args.state_file)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Coordinator shutting down")


if __name__ == "__main__":
    main()
