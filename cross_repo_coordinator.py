#!/usr/bin/env python3
"""
AgentMill Cross-Repo Coordinator

Coordinates agents working on multiple, interdependent git repositories.
Manages API change events, dependency version bumps, and cross-repo integration
testing through a shared manifest and event queue.

Python 3.11+ stdlib only.

Concepts
--------
  repo         A registered repository with an agent working on it.
  dependency   A directed edge: repo A depends on repo B's API.
  event        A change notification: API breakage, version bump, integration result.
  manifest     Shared state of repo versions, statuses, and dependency graph.

API
---
  POST /repos                   body: {"id":"...", "url":"...", "version":"..."}
                                -> 201 {"ok": true}
  GET  /repos                   -> 200 {"repos": [...]}
  DELETE /repos/<id>            -> 200 {"ok": true} | 404

  POST /deps                    body: {"consumer":"...", "provider":"..."}
                                -> 201 {"ok": true} | 400
  GET  /deps                    -> 200 {"deps": [...]}   # list of {consumer, provider}
  DELETE /deps/<consumer>/<provider>  -> 200 {"ok": true} | 404

  POST /events                  body: {"type":"api_change"|"version_bump"|
                                        "integration_result", "repo_id":"...",
                                        "payload":{...}}
                                -> 201 {"event_id": "..."}
  GET  /events                  -> 200 {"events": [...]}   # unacked events
  POST /events/<id>/ack         body: {"repo_id": "..."}
                                -> 200 {"ok": true} | 404

  GET  /manifest                -> 200 {"repos":{...}, "deps":[...], "pending_events":N}
  POST /version                 body: {"repo_id":"...", "version":"..."}
                                -> 200 {"ok": true} | 404
  GET  /status                  -> 200 {"repos":N, "deps":N, "events":N,
                                        "unacked":N}

Event types
-----------
  api_change          Provider repo changed a public API. All consumers are
                      notified so they can adapt and emit integration_result.
  version_bump        Provider incremented its version. Consumers should update
                      their dependency manifest.
  integration_result  Consumer reports whether it successfully integrated a
                      provider change: {"ok": bool, "details": str}

Environment variables
---------------------
  CROSS_REPO_PORT         int    default 3008
  CROSS_REPO_STATE_FILE   str    default logs/cross_repo_state.json
  CROSS_REPO_LOG_LEVEL    str    default INFO
  CROSS_REPO_EVENT_TTL    int    seconds before unacked events expire, default 3600
"""

import json
import logging
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("CROSS_REPO_PORT", "3008"))
STATE_FILE = os.environ.get("CROSS_REPO_STATE_FILE", "logs/cross_repo_state.json")
LOG_LEVEL = os.environ.get("CROSS_REPO_LOG_LEVEL", "INFO")
EVENT_TTL = int(os.environ.get("CROSS_REPO_EVENT_TTL", "3600"))
REAP_INTERVAL = 60  # seconds between expired-event reap passes

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [cross_repo] %(levelname)s %(message)s",
)
log = logging.getLogger("cross_repo")

VALID_EVENT_TYPES = {"api_change", "version_bump", "integration_result"}


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

class CrossRepoState:
    """Thread-safe state for cross-repo coordination."""

    def __init__(self, state_file: str) -> None:
        self.state_file = Path(state_file)
        self.lock = threading.Lock()

        # repos: id -> {id, url, version, status, registered_at}
        self.repos: dict[str, dict] = {}

        # deps: set of (consumer_id, provider_id) tuples
        self.deps: set[tuple[str, str]] = set()

        # events: id -> {id, type, repo_id, payload, created_at, acks: set[repo_id]}
        # "acks" are repos that have acknowledged this event
        self.events: dict[str, dict] = {}

        self._load()

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def _serialize(self) -> dict:
        return {
            "repos": self.repos,
            "deps": list(self.deps),
            "events": {
                eid: {**e, "acks": list(e["acks"])}
                for eid, e in self.events.items()
            },
        }

    def _deserialize(self, data: dict) -> None:
        self.repos = data.get("repos", {})
        self.deps = {tuple(d) for d in data.get("deps", [])}
        raw_events = data.get("events", {})
        self.events = {
            eid: {**e, "acks": set(e.get("acks", []))}
            for eid, e in raw_events.items()
        }

    def _load(self) -> None:
        if self.state_file.exists():
            try:
                data = json.loads(self.state_file.read_text())
                self._deserialize(data)
                log.info("Loaded state: %d repos, %d deps, %d events",
                         len(self.repos), len(self.deps), len(self.events))
            except Exception as exc:  # noqa: BLE001
                log.warning("Could not load state file: %s", exc)

    def _save(self) -> None:
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.state_file.write_text(json.dumps(self._serialize(), indent=2))

    # ------------------------------------------------------------------
    # Repos
    # ------------------------------------------------------------------

    def register_repo(self, repo_id: str, url: str, version: str) -> bool:
        """Register a new repo. Returns False if already registered."""
        with self.lock:
            if repo_id in self.repos:
                return False
            self.repos[repo_id] = {
                "id": repo_id,
                "url": url,
                "version": version,
                "status": "active",
                "registered_at": time.time(),
            }
            self._save()
            return True

    def list_repos(self) -> list[dict]:
        with self.lock:
            return list(self.repos.values())

    def delete_repo(self, repo_id: str) -> bool:
        with self.lock:
            if repo_id not in self.repos:
                return False
            del self.repos[repo_id]
            # Remove associated deps
            self.deps = {(c, p) for c, p in self.deps
                         if c != repo_id and p != repo_id}
            self._save()
            return True

    def update_version(self, repo_id: str, version: str) -> bool:
        with self.lock:
            if repo_id not in self.repos:
                return False
            self.repos[repo_id]["version"] = version
            self._save()
            return True

    # ------------------------------------------------------------------
    # Dependencies
    # ------------------------------------------------------------------

    def add_dep(self, consumer: str, provider: str) -> tuple[bool, str]:
        """Add a dependency edge. Returns (ok, error_msg)."""
        with self.lock:
            if consumer not in self.repos:
                return False, f"unknown consumer: {consumer}"
            if provider not in self.repos:
                return False, f"unknown provider: {provider}"
            if consumer == provider:
                return False, "self-dependency not allowed"
            if (consumer, provider) in self.deps:
                return False, "dependency already exists"
            # Cycle detection (DFS)
            if self._would_cycle(consumer, provider):
                return False, "adding this dependency would create a cycle"
            self.deps.add((consumer, provider))
            self._save()
            return True, ""

    def _would_cycle(self, consumer: str, provider: str) -> bool:
        """Return True if adding consumer->provider would create a cycle.
        Must be called with self.lock held.

        A cycle forms if `provider` can already reach `consumer` via existing
        dependency edges (consumer->provider direction). If so, the new edge
        consumer->provider would close the loop.
        """
        # depends_on[X] = list of nodes X depends on (X -> dep edges)
        depends_on: dict[str, list[str]] = {}
        for c, p in self.deps:
            depends_on.setdefault(c, []).append(p)

        # DFS: can we get from `provider` to `consumer` following existing edges?
        visited: set[str] = set()
        stack = [provider]
        while stack:
            node = stack.pop()
            if node == consumer:
                return True
            if node in visited:
                continue
            visited.add(node)
            stack.extend(depends_on.get(node, []))
        return False

    def list_deps(self) -> list[dict]:
        with self.lock:
            return [{"consumer": c, "provider": p} for c, p in self.deps]

    def delete_dep(self, consumer: str, provider: str) -> bool:
        with self.lock:
            if (consumer, provider) not in self.deps:
                return False
            self.deps.discard((consumer, provider))
            self._save()
            return True

    def consumers_of(self, provider: str) -> list[str]:
        """Return repo IDs that directly depend on provider. Lock-safe."""
        with self.lock:
            return [c for c, p in self.deps if p == provider]

    # ------------------------------------------------------------------
    # Events
    # ------------------------------------------------------------------

    def publish_event(self, event_type: str, repo_id: str,
                      payload: dict) -> tuple[str, list[str]]:
        """Publish a cross-repo event. Returns (event_id, list_of_notified_repos).
        For api_change / version_bump, auto-notifies all consumers."""
        with self.lock:
            event_id = str(uuid.uuid4())
            # Determine which repos need to ack this event
            if event_type in ("api_change", "version_bump"):
                notified = [c for c, p in self.deps if p == repo_id]
            else:
                notified = []  # integration_result is informational; no ack needed

            self.events[event_id] = {
                "id": event_id,
                "type": event_type,
                "repo_id": repo_id,
                "payload": payload,
                "notified": notified,
                "acks": set(),
                "created_at": time.time(),
            }
            self._save()
            return event_id, notified

    def ack_event(self, event_id: str, repo_id: str) -> tuple[bool, str]:
        """Record that repo_id has acknowledged event_id. Returns (ok, error)."""
        with self.lock:
            if event_id not in self.events:
                return False, "event not found"
            event = self.events[event_id]
            if repo_id not in event["notified"]:
                return False, f"repo {repo_id} is not in notified list"
            event["acks"].add(repo_id)
            self._save()
            return True, ""

    def list_events(self, include_acked: bool = False) -> list[dict]:
        with self.lock:
            result = []
            for e in self.events.values():
                pending_acks = [r for r in e["notified"] if r not in e["acks"]]
                if not include_acked and not pending_acks and e["notified"]:
                    continue
                result.append({
                    **e,
                    "acks": list(e["acks"]),
                    "pending_acks": pending_acks,
                    "fully_acked": len(pending_acks) == 0,
                })
            return sorted(result, key=lambda x: x["created_at"])

    def reap_expired_events(self) -> int:
        """Remove events older than EVENT_TTL. Returns count removed."""
        cutoff = time.time() - EVENT_TTL
        with self.lock:
            expired = [eid for eid, e in self.events.items()
                       if e["created_at"] < cutoff]
            for eid in expired:
                del self.events[eid]
            if expired:
                self._save()
            return len(expired)

    def get_manifest(self) -> dict:
        with self.lock:
            unacked = sum(
                1 for e in self.events.values()
                if any(r not in e["acks"] for r in e["notified"])
            )
            return {
                "repos": {rid: {**r} for rid, r in self.repos.items()},
                "deps": [{"consumer": c, "provider": p} for c, p in self.deps],
                "pending_events": unacked,
            }

    def get_status(self) -> dict:
        with self.lock:
            unacked = sum(
                1 for e in self.events.values()
                if any(r not in e["acks"] for r in e["notified"])
            )
            return {
                "repos": len(self.repos),
                "deps": len(self.deps),
                "events": len(self.events),
                "unacked": unacked,
            }


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

_state: CrossRepoState  # module-level singleton, set in main()


def _json_response(handler: BaseHTTPRequestHandler,
                   code: int, body: Any) -> None:
    data = json.dumps(body).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def _read_json(handler: BaseHTTPRequestHandler) -> dict | None:
    length = int(handler.headers.get("Content-Length", 0))
    if length == 0:
        return {}
    try:
        return json.loads(handler.rfile.read(length))
    except json.JSONDecodeError:
        return None


class CrossRepoHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:  # silence access log
        pass

    def do_GET(self) -> None:
        path = urlparse(self.path).path.rstrip("/")

        if path == "/repos":
            _json_response(self, 200, {"repos": _state.list_repos()})

        elif path == "/deps":
            _json_response(self, 200, {"deps": _state.list_deps()})

        elif path == "/events":
            _json_response(self, 200, {"events": _state.list_events()})

        elif path == "/manifest":
            _json_response(self, 200, _state.get_manifest())

        elif path == "/status":
            _json_response(self, 200, _state.get_status())

        else:
            _json_response(self, 404, {"error": "not found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path.rstrip("/")
        body = _read_json(self)
        if body is None:
            _json_response(self, 400, {"error": "invalid JSON"})
            return

        # --- POST /repos ---
        if path == "/repos":
            repo_id = body.get("id", "").strip()
            url = body.get("url", "").strip()
            version = body.get("version", "0.0.0").strip()
            if not repo_id or not url:
                _json_response(self, 400, {"error": "id and url required"})
                return
            ok = _state.register_repo(repo_id, url, version)
            if not ok:
                _json_response(self, 409, {"error": "repo already registered"})
            else:
                _json_response(self, 201, {"ok": True})

        # --- POST /deps ---
        elif path == "/deps":
            consumer = body.get("consumer", "").strip()
            provider = body.get("provider", "").strip()
            if not consumer or not provider:
                _json_response(self, 400, {"error": "consumer and provider required"})
                return
            ok, err = _state.add_dep(consumer, provider)
            if not ok:
                _json_response(self, 400, {"error": err})
            else:
                _json_response(self, 201, {"ok": True})

        # --- POST /events ---
        elif path == "/events":
            event_type = body.get("type", "").strip()
            repo_id = body.get("repo_id", "").strip()
            payload = body.get("payload", {})
            if event_type not in VALID_EVENT_TYPES:
                _json_response(self, 400, {
                    "error": f"type must be one of {sorted(VALID_EVENT_TYPES)}"})
                return
            if not repo_id:
                _json_response(self, 400, {"error": "repo_id required"})
                return
            if repo_id not in {r["id"] for r in _state.list_repos()}:
                _json_response(self, 404, {"error": "repo not found"})
                return
            event_id, notified = _state.publish_event(event_type, repo_id, payload)
            _json_response(self, 201, {"event_id": event_id, "notified": notified})

        # --- POST /events/<id>/ack ---
        elif path.startswith("/events/") and path.endswith("/ack"):
            parts = path.split("/")
            if len(parts) != 4:
                _json_response(self, 404, {"error": "not found"})
                return
            event_id = parts[2]
            repo_id = body.get("repo_id", "").strip()
            if not repo_id:
                _json_response(self, 400, {"error": "repo_id required"})
                return
            ok, err = _state.ack_event(event_id, repo_id)
            if not ok:
                _json_response(self, 404, {"error": err})
            else:
                _json_response(self, 200, {"ok": True})

        # --- POST /version ---
        elif path == "/version":
            repo_id = body.get("repo_id", "").strip()
            version = body.get("version", "").strip()
            if not repo_id or not version:
                _json_response(self, 400, {"error": "repo_id and version required"})
                return
            ok = _state.update_version(repo_id, version)
            if not ok:
                _json_response(self, 404, {"error": "repo not found"})
            else:
                _json_response(self, 200, {"ok": True})

        else:
            _json_response(self, 404, {"error": "not found"})

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path.rstrip("/")

        # --- DELETE /repos/<id> ---
        if path.startswith("/repos/"):
            repo_id = path[len("/repos/"):]
            ok = _state.delete_repo(repo_id)
            if not ok:
                _json_response(self, 404, {"error": "repo not found"})
            else:
                _json_response(self, 200, {"ok": True})

        # --- DELETE /deps/<consumer>/<provider> ---
        elif path.startswith("/deps/"):
            parts = path[len("/deps/"):].split("/", 1)
            if len(parts) != 2:
                _json_response(self, 400, {"error": "expected /deps/<consumer>/<provider>"})
                return
            consumer, provider = parts
            ok = _state.delete_dep(consumer, provider)
            if not ok:
                _json_response(self, 404, {"error": "dependency not found"})
            else:
                _json_response(self, 200, {"ok": True})

        else:
            _json_response(self, 404, {"error": "not found"})


# ---------------------------------------------------------------------------
# Background reaper
# ---------------------------------------------------------------------------

def _reaper_loop(interval: int) -> None:
    while True:
        time.sleep(interval)
        n = _state.reap_expired_events()
        if n:
            log.info("Reaped %d expired events", n)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    global _state
    _state = CrossRepoState(STATE_FILE)

    reaper = threading.Thread(target=_reaper_loop, args=(REAP_INTERVAL,),
                              daemon=True)
    reaper.start()

    server = HTTPServer(("0.0.0.0", PORT), CrossRepoHandler)
    log.info("Cross-repo coordinator listening on port %d", PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
