#!/usr/bin/env python3
"""
AgentMill Checkpoint & Rollback Protocol

Periodically snapshots agent state via git tags so that if an agent goes
off-track, it can roll back to the last known-good checkpoint rather than
starting over.

Python 3.11+ stdlib only.

Concepts
--------
  checkpoint   A git tag (``ckpt/<session>/<n>``) created at a chosen commit.
               Stores metadata (score, author, timestamp) in the tag message.
  session      A named run (defaults to the current agent's hostname + pid).
               Checkpoints are namespaced per session so multi-agent setups
               don't collide.
  score        A numeric quality signal attached to each checkpoint.
               Callers supply it (e.g. test-pass-rate, lint score).
               The rollback heuristic looks for the highest-scoring ckpt
               within a recency window.
  evaluation   An optional shell command evaluated after each iteration.
               Exit 0 → keep; non-zero → candidate for rollback.

API
---
  POST /checkpoints             body: {"session":"...", "commit":"HEAD",
                                       "score": 1.0, "label":"..."}
                                -> 201 {"id": "ckpt/session/n", "commit":"..."}
  GET  /checkpoints             ?session=...  (optional filter)
                                -> 200 {"checkpoints": [...]}
  GET  /checkpoints/<id>        -> 200 {checkpoint} | 404
  DELETE /checkpoints/<id>      -> 200 {"ok": true} | 404

  POST /rollback                body: {"session":"...", "strategy":"best"|"prev"|
                                       "specific", "target":"<id>"}
                                -> 200 {"rolled_back_to": "<id>",
                                        "commit": "...", "dry_run": bool}
  GET  /rollback/history        ?session=...
                                -> 200 {"history": [...]}

  POST /evaluate                body: {"session":"...", "commit":"HEAD"}
                                -> 200 {"ok": bool, "score": float,
                                        "recommendation": "keep"|"rollback"}
  GET  /status                  -> 200 {"sessions": N, "checkpoints": N,
                                        "rollbacks": N}

Rollback strategies
-------------------
  best      Roll back to the highest-scoring checkpoint in the session.
  prev      Roll back to the immediately preceding checkpoint.
  specific  Roll back to a named checkpoint id or git ref.

Environment variables
---------------------
  CHECKPOINT_PORT          int    default 3009
  CHECKPOINT_STATE_FILE    str    default logs/checkpoint_state.json
  CHECKPOINT_LOG_LEVEL     str    default INFO
  CHECKPOINT_EVAL_CMD      str    shell cmd to evaluate quality; must write a
                                  float score to stdout; exit 0 = pass,
                                  non-zero = fail.  default "" (disabled)
  CHECKPOINT_DRY_RUN       bool   if "1", rollback logs intent but skips git
                                  reset.  default "0"
  CHECKPOINT_MAX_PER_SESSION int  max checkpoints to keep per session before
                                  pruning oldest.  default 50
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("CHECKPOINT_PORT", 3009))
STATE_FILE = os.environ.get("CHECKPOINT_STATE_FILE", "logs/checkpoint_state.json")
LOG_LEVEL = os.environ.get("CHECKPOINT_LOG_LEVEL", "INFO")
EVAL_CMD = os.environ.get("CHECKPOINT_EVAL_CMD", "")
DRY_RUN = os.environ.get("CHECKPOINT_DRY_RUN", "0") == "1"
MAX_PER_SESSION = int(os.environ.get("CHECKPOINT_MAX_PER_SESSION", 50))

logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.INFO),
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("checkpoint")


# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

def _git(*args: str, cwd: str | None = None) -> str:
    """Run a git command, return stdout, raise on error."""
    result = subprocess.run(
        ["git", *args],
        capture_output=True, text=True, cwd=cwd,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed: {result.stderr.strip()}"
        )
    return result.stdout.strip()


def resolve_commit(ref: str, cwd: str | None = None) -> str:
    """Resolve any git ref to its full SHA."""
    return _git("rev-parse", ref, cwd=cwd)


def create_tag(tag: str, commit: str, message: str, cwd: str | None = None) -> None:
    _git("tag", "-a", tag, commit, "-m", message, cwd=cwd)


def delete_tag(tag: str, cwd: str | None = None) -> None:
    _git("tag", "-d", tag, cwd=cwd)


def tag_exists(tag: str, cwd: str | None = None) -> bool:
    result = subprocess.run(
        ["git", "tag", "-l", tag],
        capture_output=True, text=True, cwd=cwd,
    )
    return bool(result.stdout.strip())


def git_reset_hard(commit: str, dry_run: bool = False,
                   cwd: str | None = None) -> None:
    if dry_run:
        log.info("DRY_RUN: would git reset --hard %s", commit)
        return
    _git("reset", "--hard", commit, cwd=cwd)


# ---------------------------------------------------------------------------
# Evaluation helper
# ---------------------------------------------------------------------------

def evaluate_commit(commit: str, eval_cmd: str,
                    cwd: str | None = None) -> tuple[bool, float]:
    """
    Run EVAL_CMD with GIT_COMMIT env var set to *commit*.
    Returns (passed: bool, score: float).
    Score comes from the command's stdout (first line parsed as float).
    If EVAL_CMD is empty, returns (True, 1.0).
    """
    if not eval_cmd:
        return True, 1.0
    env = os.environ.copy()
    env["GIT_COMMIT"] = commit
    try:
        result = subprocess.run(
            eval_cmd, shell=True, capture_output=True, text=True,
            env=env, cwd=cwd, timeout=120,
        )
        passed = result.returncode == 0
        try:
            score = float(result.stdout.strip().splitlines()[0])
        except (ValueError, IndexError):
            score = 1.0 if passed else 0.0
        return passed, score
    except subprocess.TimeoutExpired:
        log.warning("Evaluation timed out for commit %s", commit)
        return False, 0.0
    except Exception as exc:
        log.error("Evaluation failed: %s", exc)
        return False, 0.0


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

class CheckpointStore:
    """
    Thread-safe in-memory store backed by a JSON file.

    Schema
    ------
    {
      "checkpoints": {
        "<id>": {
          "id":        str,
          "session":   str,
          "commit":    str,
          "score":     float,
          "label":     str,
          "ts":        float,
          "seq":       int       # monotonic within session
        }
      },
      "rollback_history": [
        {
          "id":             str,
          "session":        str,
          "strategy":       str,
          "rolled_back_to": str,
          "commit":         str,
          "dry_run":        bool,
          "ts":             float
        }
      ],
      "session_seq": {"<session>": int}  # last sequence number used
    }
    """

    def __init__(self, state_file: str) -> None:
        self._lock = threading.Lock()
        self._file = state_file
        self._checkpoints: dict[str, dict[str, Any]] = {}
        self._rollback_history: list[dict[str, Any]] = []
        self._session_seq: dict[str, int] = {}
        self._load()

    # --- persistence -------------------------------------------------------

    def _load(self) -> None:
        if not os.path.exists(self._file):
            return
        try:
            with open(self._file) as f:
                data = json.load(f)
            self._checkpoints = data.get("checkpoints", {})
            self._rollback_history = data.get("rollback_history", [])
            self._session_seq = data.get("session_seq", {})
            log.info("Loaded %d checkpoints from %s",
                     len(self._checkpoints), self._file)
        except Exception as exc:
            log.error("Failed to load state: %s", exc)

    def _save(self) -> None:
        os.makedirs(os.path.dirname(self._file) or ".", exist_ok=True)
        tmp = self._file + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump({
                    "checkpoints": self._checkpoints,
                    "rollback_history": self._rollback_history,
                    "session_seq": self._session_seq,
                }, f, indent=2)
            os.replace(tmp, self._file)
        except Exception as exc:
            log.error("Failed to save state: %s", exc)

    # --- checkpoint CRUD ---------------------------------------------------

    def add(self, session: str, commit: str, score: float,
            label: str) -> dict[str, Any]:
        with self._lock:
            seq = self._session_seq.get(session, 0) + 1
            self._session_seq[session] = seq
            ckpt_id = f"ckpt/{session}/{seq}"
            record: dict[str, Any] = {
                "id": ckpt_id,
                "session": session,
                "commit": commit,
                "score": score,
                "label": label,
                "ts": time.time(),
                "seq": seq,
            }
            self._checkpoints[ckpt_id] = record
            self._prune_session(session)
            self._save()
            return dict(record)

    def _prune_session(self, session: str) -> None:
        """Keep only the MAX_PER_SESSION most recent checkpoints per session."""
        session_ckpts = sorted(
            [c for c in self._checkpoints.values() if c["session"] == session],
            key=lambda c: c["seq"],
        )
        while len(session_ckpts) > MAX_PER_SESSION:
            oldest = session_ckpts.pop(0)
            del self._checkpoints[oldest["id"]]
            log.debug("Pruned checkpoint %s", oldest["id"])

    def get(self, ckpt_id: str) -> dict[str, Any] | None:
        with self._lock:
            rec = self._checkpoints.get(ckpt_id)
            return dict(rec) if rec else None

    def delete(self, ckpt_id: str) -> bool:
        with self._lock:
            if ckpt_id not in self._checkpoints:
                return False
            del self._checkpoints[ckpt_id]
            self._save()
            return True

    def list(self, session: str | None = None) -> list[dict[str, Any]]:
        with self._lock:
            ckpts = list(self._checkpoints.values())
        if session:
            ckpts = [c for c in ckpts if c["session"] == session]
        return sorted(ckpts, key=lambda c: (c["session"], c["seq"]))

    # --- rollback ----------------------------------------------------------

    def record_rollback(self, session: str, strategy: str,
                        rolled_back_to: str, commit: str,
                        dry_run: bool) -> dict[str, Any]:
        with self._lock:
            record: dict[str, Any] = {
                "id": str(uuid.uuid4()),
                "session": session,
                "strategy": strategy,
                "rolled_back_to": rolled_back_to,
                "commit": commit,
                "dry_run": dry_run,
                "ts": time.time(),
            }
            self._rollback_history.append(record)
            self._save()
            return dict(record)

    def rollback_history(self, session: str | None = None) -> list[dict[str, Any]]:
        with self._lock:
            history = list(self._rollback_history)
        if session:
            history = [h for h in history if h["session"] == session]
        return sorted(history, key=lambda h: h["ts"])

    # --- stats -------------------------------------------------------------

    def stats(self) -> dict[str, int]:
        with self._lock:
            sessions = len({c["session"] for c in self._checkpoints.values()})
            return {
                "sessions": sessions,
                "checkpoints": len(self._checkpoints),
                "rollbacks": len(self._rollback_history),
            }

    # --- strategy helpers --------------------------------------------------

    def best_checkpoint(self, session: str) -> dict[str, Any] | None:
        ckpts = [c for c in self.list(session=session)]
        if not ckpts:
            return None
        return max(ckpts, key=lambda c: c["score"])

    def prev_checkpoint(self, session: str,
                        current_seq: int | None = None) -> dict[str, Any] | None:
        ckpts = self.list(session=session)
        if not ckpts:
            return None
        if current_seq is None:
            # Return second-to-last if multiple exist
            return ckpts[-2] if len(ckpts) >= 2 else ckpts[-1]
        candidates = [c for c in ckpts if c["seq"] < current_seq]
        return candidates[-1] if candidates else None


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

_store: CheckpointStore | None = None


def _json_response(handler: BaseHTTPRequestHandler, code: int,
                   body: Any) -> None:
    data = json.dumps(body).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def _read_body(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", 0))
    raw = handler.rfile.read(length) if length else b"{}"
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt: str, *args: Any) -> None:  # type: ignore[override]
        log.debug("HTTP %s", fmt % args)

    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        query = self.path[len(path) + 1:] if "?" in self.path else ""
        params: dict[str, str] = {}
        for part in query.split("&"):
            if "=" in part:
                k, v = part.split("=", 1)
                params[k] = v

        assert _store is not None
        if path == "/status":
            _json_response(self, 200, _store.stats())

        elif path == "/checkpoints":
            session = params.get("session")
            _json_response(self, 200, {"checkpoints": _store.list(session=session)})

        elif path.startswith("/checkpoints/"):
            ckpt_id = "/".join(path.split("/")[2:])  # ckpt/session/n
            rec = _store.get(ckpt_id)
            if rec:
                _json_response(self, 200, rec)
            else:
                _json_response(self, 404, {"error": "not found"})

        elif path == "/rollback/history":
            session = params.get("session")
            _json_response(self, 200,
                           {"history": _store.rollback_history(session=session)})

        else:
            _json_response(self, 404, {"error": "not found"})

    def do_POST(self) -> None:
        path = self.path.split("?")[0]
        body = _read_body(self)
        assert _store is not None

        if path == "/checkpoints":
            session = body.get("session", "")
            if not session:
                _json_response(self, 400, {"error": "session required"})
                return
            ref = body.get("commit", "HEAD")
            try:
                commit = resolve_commit(ref)
            except RuntimeError as exc:
                _json_response(self, 400, {"error": str(exc)})
                return
            score = float(body.get("score", 1.0))
            label = str(body.get("label", ""))
            rec = _store.add(session, commit, score, label)
            # Optionally create a git tag
            tag = rec["id"].replace("/", "-")  # git tag can't have '/' in some configs
            try:
                if not tag_exists(tag):
                    create_tag(tag, commit,
                               f"checkpoint session={session} score={score}")
            except RuntimeError as exc:
                log.warning("Could not create git tag %s: %s", tag, exc)
            _json_response(self, 201, rec)

        elif path == "/rollback":
            session = body.get("session", "")
            strategy = body.get("strategy", "best")
            target_id = body.get("target", "")
            dry_run = body.get("dry_run", DRY_RUN)

            if not session:
                _json_response(self, 400, {"error": "session required"})
                return

            ckpt: dict[str, Any] | None = None
            if strategy == "best":
                ckpt = _store.best_checkpoint(session)
            elif strategy == "prev":
                ckpt = _store.prev_checkpoint(session)
            elif strategy == "specific":
                if not target_id:
                    _json_response(self, 400,
                                   {"error": "target required for specific strategy"})
                    return
                ckpt = _store.get(target_id)
                if ckpt is None:
                    # Try resolving as a raw git ref
                    try:
                        commit = resolve_commit(target_id)
                        ckpt = {"id": target_id, "commit": commit,
                                "session": session, "score": 0.0,
                                "label": target_id, "ts": time.time(), "seq": 0}
                    except RuntimeError:
                        _json_response(self, 404, {"error": "target not found"})
                        return
            else:
                _json_response(self, 400, {"error": f"unknown strategy {strategy!r}"})
                return

            if ckpt is None:
                _json_response(self, 404,
                               {"error": f"no checkpoint found for session {session!r}"})
                return

            try:
                git_reset_hard(ckpt["commit"], dry_run=dry_run)
            except RuntimeError as exc:
                _json_response(self, 500, {"error": str(exc)})
                return

            rec = _store.record_rollback(
                session=session, strategy=strategy,
                rolled_back_to=ckpt["id"], commit=ckpt["commit"],
                dry_run=bool(dry_run),
            )
            _json_response(self, 200, {
                "rolled_back_to": ckpt["id"],
                "commit": ckpt["commit"],
                "dry_run": bool(dry_run),
                "rollback_id": rec["id"],
            })

        elif path == "/evaluate":
            session = body.get("session", "")
            ref = body.get("commit", "HEAD")
            try:
                commit = resolve_commit(ref)
            except RuntimeError as exc:
                _json_response(self, 400, {"error": str(exc)})
                return
            passed, score = evaluate_commit(commit, EVAL_CMD)
            recommendation = "keep" if passed else "rollback"
            _json_response(self, 200, {
                "ok": passed,
                "score": score,
                "commit": commit,
                "recommendation": recommendation,
            })

        else:
            _json_response(self, 404, {"error": "not found"})

    def do_DELETE(self) -> None:
        path = self.path.split("?")[0]
        assert _store is not None
        if path.startswith("/checkpoints/"):
            ckpt_id = "/".join(path.split("/")[2:])
            rec = _store.get(ckpt_id)
            if rec is None:
                _json_response(self, 404, {"error": "not found"})
                return
            _store.delete(ckpt_id)
            # Remove git tag if present
            tag = ckpt_id.replace("/", "-")
            try:
                if tag_exists(tag):
                    delete_tag(tag)
            except RuntimeError as exc:
                log.warning("Could not delete git tag %s: %s", tag, exc)
            _json_response(self, 200, {"ok": True})
        else:
            _json_response(self, 404, {"error": "not found"})


# ---------------------------------------------------------------------------
# Server entry point
# ---------------------------------------------------------------------------

def run(port: int = PORT, state_file: str = STATE_FILE) -> None:
    global _store
    _store = CheckpointStore(state_file)
    server = HTTPServer(("0.0.0.0", port), Handler)
    log.info("Checkpoint server listening on port %d (dry_run=%s)", port, DRY_RUN)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")
    finally:
        server.server_close()


if __name__ == "__main__":
    run()
