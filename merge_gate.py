#!/usr/bin/env python3
"""
AgentMill Merge Gate — Consensus-Based Merge Validation

A lightweight HTTP service that blocks branch merges until N-of-M validator
agents have approved. Validators run tests, check quality, and sign off via
the API. The merge gate records approvals and rejects, and exposes a merge-
readiness endpoint that CI or agents poll before merging.

Python 3.11+ stdlib only.

API
---
  POST /submit          body: {"branch": "...", "commit": "...", "author": "..."}
                                                               -> 201 {"ok": true, "merge_id": "..."}
  POST /approve         body: {"merge_id": "...", "validator_id": "...", "notes": "..."}
                                                               -> 200 {"ok": true, "approved": N, "required": M, "ready": bool}
  POST /reject          body: {"merge_id": "...", "validator_id": "...", "reason": "..."}
                                                               -> 200 {"ok": true, "rejected": N}
  GET  /status/<id>     -> 200 {"merge_id": "...", "branch": "...", "state": "pending|approved|rejected", "approvals": N, "rejections": N, "required": M}
  GET  /pending         -> 200 [{"merge_id": "...", "branch": "...", ...}, ...]
  GET  /status          -> 200 {"pending": N, "approved": N, "rejected": N, "quorum": M}
  POST /configure       body: {"quorum": N, "total_validators": M}
                                                               -> 200 {"ok": true}

State persisted to STATE_FILE. Merge requests that exceed TTL without
reaching quorum are auto-expired.
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

PORT = int(os.environ.get("MERGE_GATE_PORT", "3004"))
STATE_FILE = os.environ.get("MERGE_GATE_STATE_FILE", "logs/merge_gate_state.json")
LOG_LEVEL = os.environ.get("MERGE_GATE_LOG_LEVEL", "INFO")

# Quorum: how many approvals needed out of how many validators
QUORUM = int(os.environ.get("MERGE_GATE_QUORUM", "2"))
TOTAL_VALIDATORS = int(os.environ.get("MERGE_GATE_TOTAL_VALIDATORS", "3"))

# How long (seconds) a merge request stays open before expiring
MERGE_TTL = int(os.environ.get("MERGE_GATE_TTL", "3600"))
# How often the expiry reaper runs (seconds)
REAP_INTERVAL = int(os.environ.get("MERGE_GATE_REAP_INTERVAL", "60"))

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [merge-gate] %(levelname)s %(message)s",
)
log = logging.getLogger("merge_gate")


# ---------------------------------------------------------------------------
# Gate State
# ---------------------------------------------------------------------------

class MergeGate:
    """Thread-safe merge gate with quorum consensus."""

    def __init__(self, state_file: str, quorum: int, total_validators: int) -> None:
        self._lock = threading.Lock()
        self._state_file = Path(state_file)
        self._quorum = quorum
        self._total_validators = total_validators
        # merge_id -> merge_request dict
        self._requests: dict[str, dict[str, Any]] = {}
        self._load()

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def _load(self) -> None:
        if self._state_file.exists():
            try:
                data = json.loads(self._state_file.read_text())
                self._requests = data.get("requests", {})
                self._quorum = data.get("quorum", self._quorum)
                self._total_validators = data.get("total_validators", self._total_validators)
                log.info("Loaded %d merge requests from %s", len(self._requests), self._state_file)
            except Exception as exc:
                log.error("Failed to load state: %s — starting fresh", exc)
                self._requests = {}

    def _save(self) -> None:
        """Persist state to disk. Caller must hold self._lock."""
        self._state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps({
            "quorum": self._quorum,
            "total_validators": self._total_validators,
            "requests": self._requests,
        }, indent=2))
        tmp.replace(self._state_file)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def submit(self, branch: str, commit: str, author: str) -> dict[str, Any]:
        """Register a new merge request. Returns the merge_id."""
        merge_id = str(uuid.uuid4())[:8]
        with self._lock:
            self._requests[merge_id] = {
                "merge_id": merge_id,
                "branch": branch,
                "commit": commit,
                "author": author,
                "state": "pending",
                "approvals": {},    # validator_id -> {ts, notes}
                "rejections": {},   # validator_id -> {ts, reason}
                "submitted_at": time.time(),
                "decided_at": None,
            }
            self._save()
        log.info("Submitted merge request %s for branch %s by %s", merge_id, branch, author)
        return {"ok": True, "merge_id": merge_id}

    def approve(self, merge_id: str, validator_id: str, notes: str = "") -> dict[str, Any]:
        """Record an approval vote. Returns updated approval counts and readiness."""
        with self._lock:
            req = self._requests.get(merge_id)
            if req is None:
                return {"error": "not_found"}
            if req["state"] != "pending":
                return {"error": f"already_{req['state']}"}

            req["approvals"][validator_id] = {"ts": time.time(), "notes": notes}

            n_approvals = len(req["approvals"])
            n_rejections = len(req["rejections"])
            ready = n_approvals >= self._quorum

            if ready:
                req["state"] = "approved"
                req["decided_at"] = time.time()
                log.info("Merge request %s APPROVED (%d/%d)", merge_id, n_approvals, self._quorum)
            else:
                log.info("Merge request %s approval %d/%d", merge_id, n_approvals, self._quorum)

            self._save()

        return {
            "ok": True,
            "approved": n_approvals,
            "rejected": n_rejections,
            "required": self._quorum,
            "ready": ready,
        }

    def reject(self, merge_id: str, validator_id: str, reason: str = "") -> dict[str, Any]:
        """Record a rejection vote. A single rejection blocks the merge."""
        with self._lock:
            req = self._requests.get(merge_id)
            if req is None:
                return {"error": "not_found"}
            if req["state"] != "pending":
                return {"error": f"already_{req['state']}"}

            req["rejections"][validator_id] = {"ts": time.time(), "reason": reason}
            n_rejections = len(req["rejections"])

            req["state"] = "rejected"
            req["decided_at"] = time.time()
            log.info("Merge request %s REJECTED by %s: %s", merge_id, validator_id, reason)
            self._save()

        return {"ok": True, "rejected": n_rejections}

    def get_request(self, merge_id: str) -> dict[str, Any] | None:
        with self._lock:
            req = self._requests.get(merge_id)
            if req is None:
                return None
            return {
                "merge_id": req["merge_id"],
                "branch": req["branch"],
                "commit": req["commit"],
                "author": req["author"],
                "state": req["state"],
                "approvals": len(req["approvals"]),
                "rejections": len(req["rejections"]),
                "required": self._quorum,
                "submitted_at": req["submitted_at"],
                "decided_at": req["decided_at"],
                "validators_approved": list(req["approvals"].keys()),
                "validators_rejected": list(req["rejections"].keys()),
            }

    def get_pending(self) -> list[dict[str, Any]]:
        with self._lock:
            return [
                {
                    "merge_id": r["merge_id"],
                    "branch": r["branch"],
                    "commit": r["commit"],
                    "author": r["author"],
                    "approvals": len(r["approvals"]),
                    "rejections": len(r["rejections"]),
                    "required": self._quorum,
                    "submitted_at": r["submitted_at"],
                }
                for r in self._requests.values()
                if r["state"] == "pending"
            ]

    def get_summary(self) -> dict[str, Any]:
        with self._lock:
            states = [r["state"] for r in self._requests.values()]
            return {
                "pending": states.count("pending"),
                "approved": states.count("approved"),
                "rejected": states.count("rejected"),
                "expired": states.count("expired"),
                "quorum": self._quorum,
                "total_validators": self._total_validators,
            }

    def configure(self, quorum: int, total_validators: int) -> dict[str, Any]:
        with self._lock:
            self._quorum = quorum
            self._total_validators = total_validators
            self._save()
        log.info("Configured quorum=%d total_validators=%d", quorum, total_validators)
        return {"ok": True}

    def reap_expired(self) -> int:
        """Expire pending merge requests that have exceeded TTL."""
        now = time.time()
        expired = 0
        with self._lock:
            for req in self._requests.values():
                if req["state"] == "pending" and now - req["submitted_at"] > MERGE_TTL:
                    req["state"] = "expired"
                    req["decided_at"] = now
                    expired += 1
            if expired:
                self._save()
        if expired:
            log.info("Expired %d stale merge requests", expired)
        return expired


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

_gate: MergeGate | None = None


def _json_response(handler: BaseHTTPRequestHandler, code: int, body: Any) -> None:
    data = json.dumps(body).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def _read_json(handler: BaseHTTPRequestHandler) -> dict[str, Any] | None:
    length = int(handler.headers.get("Content-Length", 0))
    if length == 0:
        return {}
    try:
        return json.loads(handler.rfile.read(length))
    except json.JSONDecodeError:
        return None


class MergeGateHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        log.debug(fmt, *args)

    def do_GET(self) -> None:
        assert _gate is not None
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/status":
            _json_response(self, 200, _gate.get_summary())

        elif path == "/pending":
            _json_response(self, 200, _gate.get_pending())

        elif path.startswith("/status/"):
            merge_id = path[len("/status/"):]
            req = _gate.get_request(merge_id)
            if req is None:
                _json_response(self, 404, {"error": "not_found"})
            else:
                _json_response(self, 200, req)

        else:
            _json_response(self, 404, {"error": "not_found"})

    def do_POST(self) -> None:
        assert _gate is not None
        parsed = urlparse(self.path)
        path = parsed.path

        body = _read_json(self)
        if body is None:
            _json_response(self, 400, {"error": "invalid_json"})
            return

        if path == "/submit":
            branch = body.get("branch", "")
            commit = body.get("commit", "")
            author = body.get("author", "")
            if not branch:
                _json_response(self, 400, {"error": "branch required"})
                return
            result = _gate.submit(branch, commit, author)
            _json_response(self, 201, result)

        elif path == "/approve":
            merge_id = body.get("merge_id", "")
            validator_id = body.get("validator_id", "")
            notes = body.get("notes", "")
            if not merge_id or not validator_id:
                _json_response(self, 400, {"error": "merge_id and validator_id required"})
                return
            result = _gate.approve(merge_id, validator_id, notes)
            if "error" in result:
                code = 404 if result["error"] == "not_found" else 409
                _json_response(self, code, result)
            else:
                _json_response(self, 200, result)

        elif path == "/reject":
            merge_id = body.get("merge_id", "")
            validator_id = body.get("validator_id", "")
            reason = body.get("reason", "")
            if not merge_id or not validator_id:
                _json_response(self, 400, {"error": "merge_id and validator_id required"})
                return
            result = _gate.reject(merge_id, validator_id, reason)
            if "error" in result:
                code = 404 if result["error"] == "not_found" else 409
                _json_response(self, code, result)
            else:
                _json_response(self, 200, result)

        elif path == "/configure":
            quorum = body.get("quorum")
            total = body.get("total_validators")
            if quorum is None or total is None:
                _json_response(self, 400, {"error": "quorum and total_validators required"})
                return
            _json_response(self, 200, _gate.configure(int(quorum), int(total)))

        else:
            _json_response(self, 404, {"error": "not_found"})


# ---------------------------------------------------------------------------
# Background Reaper
# ---------------------------------------------------------------------------

def _start_reaper(gate: MergeGate) -> None:
    def loop() -> None:
        while True:
            time.sleep(REAP_INTERVAL)
            try:
                gate.reap_expired()
            except Exception as exc:
                log.error("Reaper error: %s", exc)

    t = threading.Thread(target=loop, daemon=True, name="reaper")
    t.start()


# ---------------------------------------------------------------------------
# Entry Point
# ---------------------------------------------------------------------------

def main() -> None:
    global _gate
    _gate = MergeGate(STATE_FILE, QUORUM, TOTAL_VALIDATORS)
    _start_reaper(_gate)

    server = HTTPServer(("", PORT), MergeGateHandler)
    log.info(
        "Merge gate listening on :%d  quorum=%d/%d  ttl=%ds",
        PORT, QUORUM, TOTAL_VALIDATORS, MERGE_TTL,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")


if __name__ == "__main__":
    main()
