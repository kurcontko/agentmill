#!/usr/bin/env python3
"""
AgentMill Work-Stealing Queue Server

A lightweight HTTP queue server that gives agents atomic task dequeue
without filesystem races. Python 3.11+ stdlib only.

API
---
  POST /enqueue          body: {"id": "...", "payload": {...}}  -> 201 {"ok": true}
  GET  /dequeue          -> 200 {"task": {...}} | 204 (empty)
  POST /complete         body: {"id": "..."}                   -> 200 {"ok": true}
  POST /fail             body: {"id": "...", "reason": "..."}  -> 200 {"ok": true}
  GET  /status           -> 200 {"pending": N, "in_flight": N, "done": N, "failed": N}
  GET  /tasks            -> 200 {"pending": [...], "in_flight": [...], "done": [...], "failed": [...]}
  DELETE /task/<id>      -> 200 {"ok": true} | 404

State is persisted to STATE_FILE (default: logs/queue_state.json) on every mutation.
On startup, in-flight tasks are re-queued (crash recovery).
"""

import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("QUEUE_PORT", "3002"))
STATE_FILE = os.environ.get("QUEUE_STATE_FILE", "logs/queue_state.json")
LOG_LEVEL = os.environ.get("QUEUE_LOG_LEVEL", "INFO")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [queue-server] %(levelname)s %(message)s",
)
log = logging.getLogger("queue_server")


# ---------------------------------------------------------------------------
# Queue State
# ---------------------------------------------------------------------------

class QueueState:
    """Thread-safe in-memory queue with persistent state."""

    def __init__(self, state_file: str) -> None:
        self._lock = threading.Lock()
        self._state_file = Path(state_file)
        self._pending: list[dict[str, Any]] = []   # ordered FIFO
        self._in_flight: dict[str, dict[str, Any]] = {}  # id -> task
        self._done: list[dict[str, Any]] = []
        self._failed: list[dict[str, Any]] = []

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def load(self) -> None:
        """Load state from disk. Crash-recovery: re-queue in-flight tasks."""
        if not self._state_file.exists():
            return
        try:
            raw = self._state_file.read_text().strip()
            if not raw:
                return
            data = json.loads(raw)
            with self._lock:
                self._pending = data.get("pending", [])
                # Re-queue in-flight tasks (they were interrupted by a crash)
                recovered = data.get("in_flight", {})
                if recovered:
                    log.warning(
                        "Recovering %d in-flight tasks back to pending", len(recovered)
                    )
                    for task in recovered.values():
                        task["recovered"] = True
                        self._pending.insert(0, task)  # high-priority re-queue
                self._done = data.get("done", [])
                self._failed = data.get("failed", [])
            log.info(
                "Loaded state: %d pending, %d done, %d failed",
                len(self._pending),
                len(self._done),
                len(self._failed),
            )
        except Exception as exc:
            log.error("Failed to load state file %s: %s", self._state_file, exc)

    def _save(self) -> None:
        """Persist state to disk. Must be called with lock held."""
        try:
            self._state_file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._state_file.with_suffix(".tmp")
            tmp.write_text(
                json.dumps(
                    {
                        "pending": self._pending,
                        "in_flight": self._in_flight,
                        "done": self._done,
                        "failed": self._failed,
                        "saved_at": time.time(),
                    },
                    indent=2,
                )
            )
            tmp.replace(self._state_file)  # atomic on POSIX
        except Exception as exc:
            log.error("Failed to save state: %s", exc)

    # ------------------------------------------------------------------
    # Mutations
    # ------------------------------------------------------------------

    def enqueue(self, task_id: str, payload: Any) -> bool:
        """Add a task. Returns False if a task with this id already exists."""
        with self._lock:
            existing_ids = (
                {t["id"] for t in self._pending}
                | set(self._in_flight)
                | {t["id"] for t in self._done}
                | {t["id"] for t in self._failed}
            )
            if task_id in existing_ids:
                return False
            task = {
                "id": task_id,
                "payload": payload,
                "enqueued_at": time.time(),
            }
            self._pending.append(task)
            self._save()
            return True

    def dequeue(self) -> dict[str, Any] | None:
        """Atomically pop the next pending task and move it to in-flight."""
        with self._lock:
            if not self._pending:
                return None
            task = self._pending.pop(0)
            task["dequeued_at"] = time.time()
            self._in_flight[task["id"]] = task
            self._save()
            return task

    def complete(self, task_id: str) -> bool:
        """Mark an in-flight task as done."""
        with self._lock:
            task = self._in_flight.pop(task_id, None)
            if task is None:
                return False
            task["completed_at"] = time.time()
            self._done.append(task)
            self._save()
            return True

    def fail(self, task_id: str, reason: str = "") -> bool:
        """Mark an in-flight task as failed (makes it re-claimable)."""
        with self._lock:
            task = self._in_flight.pop(task_id, None)
            if task is None:
                return False
            task["failed_at"] = time.time()
            task["failure_reason"] = reason
            # Re-queue for retry (prepend for priority)
            task.setdefault("retry_count", 0)
            task["retry_count"] += 1
            if task["retry_count"] <= 3:
                self._pending.insert(0, task)
            else:
                log.warning("Task %s exceeded retry limit, moving to failed", task_id)
                self._failed.append(task)
            self._save()
            return True

    def delete(self, task_id: str) -> bool:
        """Remove a task from any state bucket."""
        with self._lock:
            original_pending_len = len(self._pending)
            self._pending = [t for t in self._pending if t["id"] != task_id]
            removed_pending = len(self._pending) < original_pending_len

            removed_flight = self._in_flight.pop(task_id, None) is not None

            original_done_len = len(self._done)
            self._done = [t for t in self._done if t["id"] != task_id]
            removed_done = len(self._done) < original_done_len

            original_failed_len = len(self._failed)
            self._failed = [t for t in self._failed if t["id"] != task_id]
            removed_failed = len(self._failed) < original_failed_len

            removed = removed_pending or removed_flight or removed_done or removed_failed
            if removed:
                self._save()
            return removed

    # ------------------------------------------------------------------
    # Reads
    # ------------------------------------------------------------------

    def status(self) -> dict[str, int]:
        with self._lock:
            return {
                "pending": len(self._pending),
                "in_flight": len(self._in_flight),
                "done": len(self._done),
                "failed": len(self._failed),
            }

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "pending": list(self._pending),
                "in_flight": dict(self._in_flight),
                "done": list(self._done),
                "failed": list(self._failed),
            }


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

class QueueHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the queue API."""

    queue: QueueState  # set on the class by main()

    def log_message(self, fmt: str, *args: Any) -> None:
        log.debug("HTTP %s", fmt % args)

    def _read_json(self) -> Any:
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw)

    def _send(self, code: int, body: Any = None) -> None:
        payload = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/dequeue":
            task = self.queue.dequeue()
            if task is None:
                self._send(204)
            else:
                self._send(200, {"task": task})

        elif path == "/status":
            self._send(200, self.queue.status())

        elif path == "/tasks":
            self._send(200, self.queue.snapshot())

        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        try:
            body = self._read_json()
        except (json.JSONDecodeError, ValueError) as exc:
            self._send(400, {"error": f"invalid JSON: {exc}"})
            return

        if path == "/enqueue":
            task_id = body.get("id")
            if not task_id:
                self._send(400, {"error": "'id' is required"})
                return
            ok = self.queue.enqueue(task_id, body.get("payload", {}))
            if ok:
                self._send(201, {"ok": True, "id": task_id})
            else:
                self._send(409, {"error": "task id already exists"})

        elif path == "/complete":
            task_id = body.get("id")
            if not task_id:
                self._send(400, {"error": "'id' is required"})
                return
            ok = self.queue.complete(task_id)
            self._send(200 if ok else 404, {"ok": ok})

        elif path == "/fail":
            task_id = body.get("id")
            if not task_id:
                self._send(400, {"error": "'id' is required"})
                return
            ok = self.queue.fail(task_id, body.get("reason", ""))
            self._send(200 if ok else 404, {"ok": ok})

        else:
            self._send(404, {"error": "not found"})

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path
        if path.startswith("/task/"):
            task_id = path[len("/task/"):]
            ok = self.queue.delete(task_id)
            self._send(200 if ok else 404, {"ok": ok})
        else:
            self._send(404, {"error": "not found"})


# ---------------------------------------------------------------------------
# Shell client helpers (importable)
# ---------------------------------------------------------------------------

def client_dequeue(host: str = "localhost", port: int = PORT) -> dict[str, Any] | None:
    """Dequeue a task from the server. Returns task dict or None."""
    import urllib.request

    url = f"http://{host}:{port}/dequeue"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            if resp.status == 204:
                return None
            return json.loads(resp.read())["task"]
    except Exception as exc:
        log.error("client_dequeue failed: %s", exc)
        return None


def client_complete(task_id: str, host: str = "localhost", port: int = PORT) -> bool:
    """Mark a task complete."""
    import urllib.request

    data = json.dumps({"id": task_id}).encode()
    req = urllib.request.Request(
        f"http://{host}:{port}/complete",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status == 200
    except Exception as exc:
        log.error("client_complete failed: %s", exc)
        return False


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    state = QueueState(STATE_FILE)
    state.load()

    QueueHandler.queue = state

    server = HTTPServer(("0.0.0.0", PORT), QueueHandler)
    log.info("Queue server listening on port %d (state: %s)", PORT, STATE_FILE)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
