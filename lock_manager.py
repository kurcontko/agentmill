#!/usr/bin/env python3
"""
AgentMill Shared Workspace Lock Manager

Advisory file-level lock manager for inter-agent conflict prevention.
Agents check before editing files and release locks when done.
Python 3.11+ stdlib only.

API
---
  POST /acquire              body: {"agent": "agent-1", "file": "src/foo.py", "ttl": 300}
                             -> 200 {"ok": true, "lock_id": "uuid", "expires": timestamp}
                             -> 409 {"ok": false, "held_by": "agent-2", "lock_id": "uuid", "expires": timestamp}
  POST /acquire_batch        body: {"agent": "agent-1", "files": ["a.py", "b.py"], "ttl": 300}
                             -> 200 {"ok": true, "lock_ids": {"a.py": "uuid", ...}, "conflicts": [...]}
  POST /release              body: {"agent": "agent-1", "lock_id": "uuid"}
                             -> 200 {"ok": true}
                             -> 404 {"ok": false, "error": "lock not found"}
                             -> 403 {"ok": false, "error": "not your lock"}
  POST /release_all          body: {"agent": "agent-1"}
                             -> 200 {"ok": true, "released": N}
  POST /heartbeat            body: {"agent": "agent-1", "lock_id": "uuid"}
                             -> 200 {"ok": true, "expires": timestamp}
                             -> 404 {"ok": false, "error": "lock not found"}
  GET  /locks                -> 200 {"locks": [...]}  (all active locks)
  GET  /locks/<encoded-file> -> 200 {"lock": {...}} or 404 {"lock": null}
  GET  /agent/<agent-id>     -> 200 {"locks": [...]}  (locks held by agent)
  GET  /status               -> 200 {"agents": [...], "total_locks": N, "files_locked": N}

Locks are advisory — agents cooperate but the OS does not enforce them.
Deadlock prevention: batch acquire sorts files before locking.
State is persisted to STATE_FILE (default: logs/lock_state.json) on every mutation.
Expired locks are reaped by a background thread every REAP_INTERVAL seconds.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HOST = os.environ.get("LOCK_HOST", "0.0.0.0")
PORT = int(os.environ.get("LOCK_PORT", "3004"))
STATE_FILE = os.environ.get("LOCK_STATE_FILE", "logs/lock_state.json")
DEFAULT_TTL = int(os.environ.get("LOCK_DEFAULT_TTL", "300"))   # seconds
MAX_TTL = int(os.environ.get("LOCK_MAX_TTL", "3600"))          # 1 hour cap
REAP_INTERVAL = int(os.environ.get("LOCK_REAP_INTERVAL", "15"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s lock_manager %(levelname)s %(message)s")
log = logging.getLogger("lock_manager")

# ---------------------------------------------------------------------------
# Lock Store
# ---------------------------------------------------------------------------

class LockStore:
    """Thread-safe advisory file-lock store with TTL expiry and persistence."""

    def __init__(self, state_file: str = STATE_FILE) -> None:
        self._mu = threading.Lock()
        self._state_file = state_file
        # lock_id -> {lock_id, agent, file, acquired, expires}
        self._locks: dict[str, dict[str, Any]] = {}
        # file -> lock_id  (fast lookup)
        self._file_index: dict[str, str] = {}
        self._load()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def acquire(self, agent: str, file: str, ttl: int) -> dict[str, Any]:
        """Acquire a lock on *file* for *agent*.

        Returns {"ok": True, "lock_id": ..., "expires": ...} on success.
        Returns {"ok": False, "held_by": ..., "lock_id": ..., "expires": ...} on conflict.
        """
        ttl = min(max(1, ttl), MAX_TTL)
        with self._mu:
            existing_id = self._file_index.get(file)
            if existing_id:
                lock = self._locks[existing_id]
                if lock["expires"] > time.time():
                    return {
                        "ok": False,
                        "held_by": lock["agent"],
                        "lock_id": existing_id,
                        "expires": lock["expires"],
                    }
                # expired — remove it
                self._remove_lock(existing_id)

            lock_id = str(uuid.uuid4())
            now = time.time()
            lock = {
                "lock_id": lock_id,
                "agent": agent,
                "file": file,
                "acquired": now,
                "expires": now + ttl,
            }
            self._locks[lock_id] = lock
            self._file_index[file] = lock_id
            self._persist()
            return {"ok": True, "lock_id": lock_id, "expires": lock["expires"]}

    def acquire_batch(self, agent: str, files: list[str], ttl: int) -> dict[str, Any]:
        """Acquire locks on multiple files atomically (sorted to prevent deadlock).

        Returns all acquired locks and any conflicts.
        On conflict, already-acquired locks in this batch are NOT released — caller
        must decide whether to proceed with partial locks or release them all.
        """
        ttl = min(max(1, ttl), MAX_TTL)
        # Sort to impose consistent acquisition order (deadlock prevention)
        sorted_files = sorted(set(files))
        acquired: dict[str, str] = {}  # file -> lock_id
        conflicts: list[dict[str, Any]] = []

        with self._mu:
            for file in sorted_files:
                existing_id = self._file_index.get(file)
                if existing_id:
                    lock = self._locks[existing_id]
                    if lock["expires"] > time.time():
                        conflicts.append({
                            "file": file,
                            "held_by": lock["agent"],
                            "lock_id": existing_id,
                            "expires": lock["expires"],
                        })
                        continue
                    self._remove_lock(existing_id)

                lock_id = str(uuid.uuid4())
                now = time.time()
                lock = {
                    "lock_id": lock_id,
                    "agent": agent,
                    "file": file,
                    "acquired": now,
                    "expires": now + ttl,
                }
                self._locks[lock_id] = lock
                self._file_index[file] = lock_id
                acquired[file] = lock_id

            if acquired:
                self._persist()

        return {
            "ok": len(conflicts) == 0,
            "lock_ids": acquired,
            "conflicts": conflicts,
        }

    def release(self, agent: str, lock_id: str) -> dict[str, Any]:
        """Release a specific lock. Only the owning agent may release it."""
        with self._mu:
            lock = self._locks.get(lock_id)
            if lock is None:
                return {"ok": False, "error": "lock not found"}
            if lock["agent"] != agent:
                return {"ok": False, "error": "not your lock"}
            self._remove_lock(lock_id)
            self._persist()
            return {"ok": True}

    def release_all(self, agent: str) -> int:
        """Release all locks held by *agent*. Returns count released."""
        with self._mu:
            ids = [lid for lid, lk in self._locks.items() if lk["agent"] == agent]
            for lid in ids:
                self._remove_lock(lid)
            if ids:
                self._persist()
            return len(ids)

    def heartbeat(self, agent: str, lock_id: str, ttl: int | None = None) -> dict[str, Any]:
        """Renew TTL of a lock."""
        with self._mu:
            lock = self._locks.get(lock_id)
            if lock is None:
                return {"ok": False, "error": "lock not found"}
            if lock["agent"] != agent:
                return {"ok": False, "error": "not your lock"}
            delta = ttl if ttl else (lock["expires"] - lock["acquired"])
            delta = min(max(1, delta), MAX_TTL)
            lock["expires"] = time.time() + delta
            self._persist()
            return {"ok": True, "expires": lock["expires"]}

    def get_lock_for_file(self, file: str) -> dict[str, Any] | None:
        """Return the active lock on *file*, or None if unlocked/expired."""
        with self._mu:
            lock_id = self._file_index.get(file)
            if not lock_id:
                return None
            lock = self._locks.get(lock_id)
            if lock is None or lock["expires"] <= time.time():
                return None
            return dict(lock)

    def get_locks_for_agent(self, agent: str) -> list[dict[str, Any]]:
        """Return all active locks held by *agent*."""
        now = time.time()
        with self._mu:
            return [dict(lk) for lk in self._locks.values()
                    if lk["agent"] == agent and lk["expires"] > now]

    def list_locks(self) -> list[dict[str, Any]]:
        """Return all active (non-expired) locks."""
        now = time.time()
        with self._mu:
            return [dict(lk) for lk in self._locks.values() if lk["expires"] > now]

    def reap_expired(self) -> int:
        """Remove expired locks. Returns count removed."""
        now = time.time()
        with self._mu:
            expired = [lid for lid, lk in self._locks.items() if lk["expires"] <= now]
            for lid in expired:
                self._remove_lock(lid)
            if expired:
                self._persist()
            return len(expired)

    def status(self) -> dict[str, Any]:
        now = time.time()
        with self._mu:
            active = [lk for lk in self._locks.values() if lk["expires"] > now]
            agents = list({lk["agent"] for lk in active})
            return {
                "agents": agents,
                "total_locks": len(active),
                "files_locked": len({lk["file"] for lk in active}),
            }

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _remove_lock(self, lock_id: str) -> None:
        """Caller must hold self._mu."""
        lock = self._locks.pop(lock_id, None)
        if lock:
            self._file_index.pop(lock["file"], None)

    def _persist(self) -> None:
        """Caller must hold self._mu."""
        path = Path(self._state_file)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = str(path) + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"locks": list(self._locks.values())}, f)
        os.replace(tmp, str(path))

    def _load(self) -> None:
        path = Path(self._state_file)
        if not path.exists():
            return
        try:
            with open(path) as f:
                data = json.load(f)
            now = time.time()
            for lk in data.get("locks", []):
                if lk.get("expires", 0) > now:
                    self._locks[lk["lock_id"]] = lk
                    self._file_index[lk["file"]] = lk["lock_id"]
            log.info("loaded %d active locks from %s", len(self._locks), path)
        except Exception as exc:
            log.warning("could not load state from %s: %s", path, exc)


# ---------------------------------------------------------------------------
# Reaper
# ---------------------------------------------------------------------------

def _reaper(store: LockStore) -> None:
    while True:
        time.sleep(REAP_INTERVAL)
        n = store.reap_expired()
        if n:
            log.info("reaped %d expired locks", n)


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

def _json_body(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", 0))
    raw = handler.rfile.read(length)
    return json.loads(raw) if raw else {}


def _send(handler: BaseHTTPRequestHandler, status: int, body: dict[str, Any]) -> None:
    data = json.dumps(body).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


class LockHandler(BaseHTTPRequestHandler):
    store: LockStore  # set on class before serving

    def log_message(self, fmt: str, *args: Any) -> None:  # silence access log
        pass

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            body = _json_body(self)
        except Exception:
            _send(self, 400, {"ok": False, "error": "invalid JSON"})
            return

        if path == "/acquire":
            agent = body.get("agent", "")
            file = body.get("file", "")
            ttl = int(body.get("ttl", DEFAULT_TTL))
            if not agent or not file:
                _send(self, 400, {"ok": False, "error": "agent and file required"})
                return
            result = self.store.acquire(agent, file, ttl)
            _send(self, 200 if result["ok"] else 409, result)

        elif path == "/acquire_batch":
            agent = body.get("agent", "")
            files = body.get("files", [])
            ttl = int(body.get("ttl", DEFAULT_TTL))
            if not agent or not isinstance(files, list) or not files:
                _send(self, 400, {"ok": False, "error": "agent and files[] required"})
                return
            result = self.store.acquire_batch(agent, files, ttl)
            _send(self, 200, result)

        elif path == "/release":
            agent = body.get("agent", "")
            lock_id = body.get("lock_id", "")
            if not agent or not lock_id:
                _send(self, 400, {"ok": False, "error": "agent and lock_id required"})
                return
            result = self.store.release(agent, lock_id)
            if result["ok"]:
                _send(self, 200, result)
            elif result["error"] == "not your lock":
                _send(self, 403, result)
            else:
                _send(self, 404, result)

        elif path == "/release_all":
            agent = body.get("agent", "")
            if not agent:
                _send(self, 400, {"ok": False, "error": "agent required"})
                return
            n = self.store.release_all(agent)
            _send(self, 200, {"ok": True, "released": n})

        elif path == "/heartbeat":
            agent = body.get("agent", "")
            lock_id = body.get("lock_id", "")
            ttl = body.get("ttl")
            if not agent or not lock_id:
                _send(self, 400, {"ok": False, "error": "agent and lock_id required"})
                return
            result = self.store.heartbeat(agent, lock_id, int(ttl) if ttl else None)
            _send(self, 200 if result["ok"] else 404, result)

        else:
            _send(self, 404, {"ok": False, "error": "not found"})

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/locks":
            _send(self, 200, {"locks": self.store.list_locks()})

        elif path.startswith("/locks/"):
            file = unquote(path[len("/locks/"):])
            lock = self.store.get_lock_for_file(file)
            _send(self, 200 if lock else 404, {"lock": lock})

        elif path.startswith("/agent/"):
            agent = unquote(path[len("/agent/"):])
            _send(self, 200, {"locks": self.store.get_locks_for_agent(agent)})

        elif path == "/status":
            _send(self, 200, self.store.status())

        else:
            _send(self, 404, {"ok": False, "error": "not found"})


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def make_server(host: str = HOST, port: int = PORT,
                state_file: str = STATE_FILE) -> HTTPServer:
    store = LockStore(state_file)
    LockHandler.store = store
    threading.Thread(target=_reaper, args=(store,), daemon=True).start()
    server = HTTPServer((host, port), LockHandler)
    return server


if __name__ == "__main__":
    server = make_server()
    log.info("lock_manager listening on %s:%d", HOST, PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")
        server.server_close()
        sys.exit(0)
