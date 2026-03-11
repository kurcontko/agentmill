#!/usr/bin/env python3
"""
AgentMill Conflict Resolver — Smart Merge Conflict Resolution

Goes beyond simple rebase-retry by analysing git conflict markers and applying
pattern-based resolution strategies.  Unresolvable conflicts are split into
subtasks that other agents can claim.

Python 3.11+ stdlib only.

Concepts
--------
  conflict block   A region between ``<<<<<<<`` … ``>>>>>>>`` markers.
  strategy         How to resolve a conflict block:
                     take_ours        – discard theirs (whitespace-only diff)
                     take_theirs      – discard ours  (ours is empty)
                     merge_imports    – union of import lines, sorted
                     take_higher_version – pick the numerically greater semver
                     append_both      – concatenate ours + theirs (additive)
                     split_task       – unresolvable; create a subtask
  resolution       A record of one attempt to auto-resolve a set of files.
  subtask          A work item written to ``current_tasks/`` for another agent.

API
---
  POST /analyze      body: {"conflict_text": "...", "file_path": "..."}
                     -> 200 {"strategy": "...", "confidence": 0–1,
                             "resolved": bool, "content": "..."}

  POST /resolve      body: {"branch": "...", "base_branch": "main",
                            "repo_path": "/path/to/repo",
                            "files": ["path/to/file", ...]}   ← optional override
                     -> 201 {"ok": true, "resolution_id": "...",
                             "resolved_files": [...],
                             "unresolved_files": [...],
                             "strategies": {...}}

  POST /split        body: {"resolution_id": "...", "file_path": "..."}
                     -> 201 {"ok": true, "subtask_file": "...",
                             "subtask_slug": "..."}

  GET  /status/<id>  -> 200 {resolution record} | 404
  GET  /pending      -> 200 [list of pending resolution records]
  GET  /status       -> 200 {"total": N, "resolved": N, "partial": N,
                             "unresolved": N, "subtasks_created": N}

Environment variables
---------------------
  CONFLICT_RESOLVER_PORT        int   default 3010
  CONFLICT_STATE_FILE           str   default logs/conflict_resolver_state.json
  CONFLICT_LOG_LEVEL            str   default INFO
  CONFLICT_SUBTASK_DIR          str   default current_tasks
"""

from __future__ import annotations

import json
import logging
import os
import re
import socketserver
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("CONFLICT_RESOLVER_PORT", 3010))
STATE_FILE = os.environ.get("CONFLICT_STATE_FILE", "logs/conflict_resolver_state.json")
LOG_LEVEL = os.environ.get("CONFLICT_LOG_LEVEL", "INFO")
SUBTASK_DIR = os.environ.get("CONFLICT_SUBTASK_DIR", "current_tasks")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("conflict_resolver")


# ---------------------------------------------------------------------------
# Conflict marker parsing
# ---------------------------------------------------------------------------

# Matches standard 2-way and 3-way (diff3) conflict blocks.
#   <<<<<<< OURS
#   ours content
#   ||||||| BASE   ← optional (diff3 style)
#   base content
#   =======
#   theirs content
#   >>>>>>> THEIRS
_CONFLICT_RE = re.compile(
    r"<{7} (?P<ours_label>[^\n]+)\n"
    r"(?P<ours>.*?)"
    r"(?:\|{7} [^\n]+\n(?P<base>.*?))?"
    r"={7}\n"
    r"(?P<theirs>.*?)"
    r">{7} (?P<theirs_label>[^\n]+)",
    re.DOTALL,
)

_VERSION_RE = re.compile(
    r"""(?:version\s*[=:]\s*['"]?|['"])([\d]+)\.([\d]+)(?:\.([\d]+))?""",
    re.IGNORECASE,
)

_IMPORT_RE = re.compile(
    r"^(import |from |#\s*include|const \w|require\(|using )",
    re.MULTILINE,
)

_FUNC_RE = re.compile(
    r"^(def |class |function |async def |async function |\w[\w\s]*\()",
    re.MULTILINE,
)


def parse_conflicts(text: str) -> list[dict[str, Any]]:
    """Return a list of conflict block dicts extracted from *text*."""
    blocks: list[dict[str, Any]] = []
    for m in _CONFLICT_RE.finditer(text):
        blocks.append(
            {
                "start": m.start(),
                "end": m.end(),
                "ours_label": m.group("ours_label").strip(),
                "theirs_label": m.group("theirs_label").strip(),
                "ours": m.group("ours"),
                "base": m.group("base") or "",
                "theirs": m.group("theirs"),
                "full": m.group(0),
            }
        )
    return blocks


# ---------------------------------------------------------------------------
# Strategy classification
# ---------------------------------------------------------------------------

def _parse_version(text: str) -> tuple[int, int, int]:
    m = _VERSION_RE.search(text)
    if m:
        major = int(m.group(1))
        minor = int(m.group(2))
        patch = int(m.group(3)) if m.group(3) else 0
        return (major, minor, patch)
    return (0, 0, 0)


def _all_imports(lines: list[str]) -> bool:
    return bool(lines) and all(
        _IMPORT_RE.match(ln.strip()) for ln in lines if ln.strip()
    )


def _lhs_names(text: str) -> set[str]:
    """Extract simple variable names from LHS of assignment statements."""
    return set(re.findall(r"^\s*(\w+)\s*(?:[+\-*/%&|^]?=)", text, re.MULTILINE))


def classify_conflict(c: dict[str, Any]) -> tuple[str, float]:
    """Return ``(strategy_name, confidence 0–1)`` for a conflict block."""
    ours: str = c["ours"]
    theirs: str = c["theirs"]
    base: str = c["base"]

    # 1. Identical content (perhaps different trailing whitespace / newlines)
    if ours.strip() == theirs.strip():
        return ("take_ours", 1.0)

    # 2. One side empty
    if not ours.strip() and theirs.strip():
        return ("take_theirs", 1.0)
    if ours.strip() and not theirs.strip():
        return ("take_ours", 1.0)

    # 3. Same tokens, only whitespace differences
    if ours.strip().split() == theirs.strip().split():
        return ("take_ours", 0.95)

    # 4. Both sides are purely import statements
    ours_lines = [ln for ln in ours.splitlines() if ln.strip()]
    theirs_lines = [ln for ln in theirs.splitlines() if ln.strip()]
    if _all_imports(ours_lines) and _all_imports(theirs_lines):
        return ("merge_imports", 0.90)

    # 5. Version-string conflict
    ours_ver = _parse_version(ours)
    theirs_ver = _parse_version(theirs)
    if ours_ver != (0, 0, 0) and theirs_ver != (0, 0, 0):
        return ("take_higher_version", 0.80)

    # 6. Non-overlapping additions (no base, no shared lines, no shared LHS names)
    if not base.strip():
        ours_set = set(ours.strip().splitlines())
        theirs_set = set(theirs.strip().splitlines())
        ours_lhs = _lhs_names(ours)
        theirs_lhs = _lhs_names(theirs)
        if not (ours_set & theirs_set) and not (ours_lhs & theirs_lhs):
            return ("append_both", 0.75)

    # 7. Both sides add new functions / classes (no overlap in function names)
    if not base.strip() and _FUNC_RE.search(ours) and _FUNC_RE.search(theirs):
        ours_funcs = set(re.findall(r"(?:def |function )(\w+)", ours))
        theirs_funcs = set(re.findall(r"(?:def |function )(\w+)", theirs))
        if not (ours_funcs & theirs_funcs):
            return ("append_both", 0.65)

    # 8. Trailing-comma list / dict append pattern
    if (ours.rstrip().endswith(",") or theirs.rstrip().endswith(",")) and not base.strip():
        ours_lhs = _lhs_names(ours)
        theirs_lhs = _lhs_names(theirs)
        if not (ours_lhs & theirs_lhs):
            return ("append_both", 0.55)

    return ("split_task", 0.0)


# ---------------------------------------------------------------------------
# Strategy application
# ---------------------------------------------------------------------------

def apply_strategy(c: dict[str, Any], strategy: str) -> str | None:
    """
    Apply *strategy* to conflict block *c*.  Returns resolved text, or
    ``None`` if the strategy cannot resolve (i.e. ``split_task``).
    """
    ours: str = c["ours"]
    theirs: str = c["theirs"]

    if strategy == "take_ours":
        return ours

    if strategy == "take_theirs":
        return theirs

    if strategy == "merge_imports":
        ours_lines = [ln for ln in ours.splitlines() if ln.strip()]
        theirs_lines = [ln for ln in theirs.splitlines() if ln.strip()]
        merged = sorted(set(ours_lines + theirs_lines))
        return "\n".join(merged) + "\n"

    if strategy == "take_higher_version":
        ours_ver = _parse_version(ours)
        theirs_ver = _parse_version(theirs)
        return theirs if theirs_ver >= ours_ver else ours

    if strategy == "append_both":
        result = ours
        if result and not result.endswith("\n"):
            result += "\n"
        result += theirs
        return result

    return None  # split_task or unknown


# ---------------------------------------------------------------------------
# File-level resolution
# ---------------------------------------------------------------------------

def resolve_file_content(content: str) -> dict[str, Any]:
    """
    Attempt to auto-resolve every conflict block in *content*.

    Returns::

        {
            "resolved":          bool,   # True if ALL blocks were resolved
            "content":           str,    # text after applying all resolutions
            "strategies":        list,   # per-block {"strategy", "confidence", "resolved"}
            "unresolved_count":  int,
        }
    """
    blocks = parse_conflicts(content)
    if not blocks:
        return {
            "resolved": True,
            "content": content,
            "strategies": [],
            "unresolved_count": 0,
        }

    strategies: list[dict[str, Any]] = []
    result = content
    offset = 0
    unresolved = 0

    for block in blocks:
        strategy, confidence = classify_conflict(block)
        resolved_text = apply_strategy(block, strategy)

        if resolved_text is not None:
            start = block["start"] + offset
            end = block["end"] + offset
            result = result[:start] + resolved_text + result[end:]
            offset += len(resolved_text) - (block["end"] - block["start"])
            strategies.append(
                {"strategy": strategy, "confidence": confidence, "resolved": True}
            )
        else:
            unresolved += 1
            strategies.append(
                {"strategy": strategy, "confidence": 0.0, "resolved": False}
            )

    return {
        "resolved": unresolved == 0,
        "content": result,
        "strategies": strategies,
        "unresolved_count": unresolved,
    }


# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

def _git(*args: str, cwd: str | None = None) -> str:
    result = subprocess.run(
        ["git", *args], capture_output=True, text=True, cwd=cwd
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def conflicted_files(cwd: str | None = None) -> list[str]:
    """Return paths of files that currently have unresolved conflict markers."""
    out = _git("diff", "--name-only", "--diff-filter=U", cwd=cwd)
    return [p for p in out.splitlines() if p.strip()]


def read_conflict_file(path: str, repo_path: str) -> str:
    """Read a conflicted file from the working tree."""
    full = os.path.join(repo_path, path)
    with open(full, "r", errors="replace") as fh:
        return fh.read()


def write_resolved_file(path: str, content: str, repo_path: str) -> None:
    """Write resolved content back and attempt to stage it."""
    full = os.path.join(repo_path, path)
    with open(full, "w") as fh:
        fh.write(content)
    try:
        _git("add", path, cwd=repo_path)
    except RuntimeError as exc:
        log.debug("Skipping git stage for %s: %s", path, exc)


# ---------------------------------------------------------------------------
# Subtask helper
# ---------------------------------------------------------------------------

def create_subtask(
    file_path: str,
    resolution_id: str,
    branch: str,
    base_branch: str,
    strategies: list[dict[str, Any]],
    repo_path: str,
) -> dict[str, Any]:
    """
    Write a ``current_tasks/<slug>.md`` subtask for a file that could not be
    auto-resolved.  Returns metadata about the created subtask.
    """
    slug = re.sub(r"[^a-zA-Z0-9_-]", "-", file_path)
    slug = f"conflict-{slug[:60]}-{resolution_id[:8]}"
    subtask_dir = Path(repo_path) / SUBTASK_DIR
    subtask_dir.mkdir(parents=True, exist_ok=True)
    subtask_file = str(subtask_dir / f"{slug}.md")

    unresolved_patterns = [
        s["strategy"] for s in strategies if not s.get("resolved", True)
    ]

    content = (
        f"# Conflict Resolution Subtask\n\n"
        f"- **File**: `{file_path}`\n"
        f"- **Branch**: `{branch}`\n"
        f"- **Base branch**: `{base_branch}`\n"
        f"- **Resolution ID**: `{resolution_id}`\n"
        f"- **Created**: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n"
        f"- **Unresolved patterns**: {', '.join(unresolved_patterns) or 'unknown'}\n\n"
        f"## Instructions\n\n"
        f"1. Open `{file_path}` in `{repo_path}` (branch `{branch}`).\n"
        f"2. Resolve all remaining conflict markers (`<<<<<<<` / `=======` / `>>>>>>>`).\n"
        f"3. Run tests to verify correctness.\n"
        f"4. Stage the file: `git add {file_path}`\n"
        f"5. Delete this subtask file when done.\n"
    )

    with open(subtask_file, "w") as fh:
        fh.write(content)

    return {"subtask_file": subtask_file, "subtask_slug": slug}


# ---------------------------------------------------------------------------
# State manager
# ---------------------------------------------------------------------------

class ConflictStore:
    """Thread-safe in-memory store with JSON persistence."""

    def __init__(self, state_file: str) -> None:
        self._lock = threading.Lock()
        self._state_file = state_file
        # resolution_id -> record dict
        self._resolutions: dict[str, dict[str, Any]] = {}
        self._subtasks_created = 0
        self._load()

    # ── persistence ──────────────────────────────────────────────────────────

    def _load(self) -> None:
        try:
            with open(self._state_file) as fh:
                data = json.load(fh)
            self._resolutions = data.get("resolutions", {})
            self._subtasks_created = data.get("subtasks_created", 0)
            log.info("Loaded %d resolutions from %s", len(self._resolutions), self._state_file)
        except FileNotFoundError:
            pass
        except Exception as exc:
            log.warning("Could not load state: %s", exc)

    def _save(self) -> None:
        Path(self._state_file).parent.mkdir(parents=True, exist_ok=True)
        tmp = self._state_file + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(
                {
                    "resolutions": self._resolutions,
                    "subtasks_created": self._subtasks_created,
                },
                fh,
                indent=2,
            )
        os.replace(tmp, self._state_file)

    # ── mutations ─────────────────────────────────────────────────────────────

    def add_resolution(self, record: dict[str, Any]) -> None:
        with self._lock:
            self._resolutions[record["resolution_id"]] = record
            self._save()

    def get_resolution(self, resolution_id: str) -> dict[str, Any] | None:
        with self._lock:
            return self._resolutions.get(resolution_id)

    def record_subtask(self, resolution_id: str, file_path: str, meta: dict[str, Any]) -> None:
        with self._lock:
            rec = self._resolutions.get(resolution_id)
            if rec is not None:
                rec.setdefault("subtasks", []).append(
                    {"file": file_path, **meta, "created_at": time.time()}
                )
            self._subtasks_created += 1
            self._save()

    # ── queries ───────────────────────────────────────────────────────────────

    def list_pending(self) -> list[dict[str, Any]]:
        with self._lock:
            return [
                r for r in self._resolutions.values()
                if r.get("state") in ("partial", "unresolved")
            ]

    def aggregate(self) -> dict[str, int]:
        with self._lock:
            counts: dict[str, int] = {"total": 0, "resolved": 0, "partial": 0, "unresolved": 0}
            for r in self._resolutions.values():
                counts["total"] += 1
                state = r.get("state", "unresolved")
                counts[state] = counts.get(state, 0) + 1
            counts["subtasks_created"] = self._subtasks_created
            return counts


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    store: ConflictStore  # injected at server construction

    # ── helpers ───────────────────────────────────────────────────────────────

    def _read_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        return json.loads(raw) if raw else {}

    def _send(self, code: int, body: Any) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args: Any) -> None:  # suppress default access log
        log.debug(fmt, *args)

    # ── routing ───────────────────────────────────────────────────────────────

    def do_POST(self) -> None:
        if self.path == "/analyze":
            self._handle_analyze()
        elif self.path == "/resolve":
            self._handle_resolve()
        elif self.path == "/split":
            self._handle_split()
        else:
            self._send(404, {"error": "not found"})

    def do_GET(self) -> None:
        if self.path == "/status":
            self._send(200, self.store.aggregate())
        elif self.path == "/pending":
            self._send(200, self.store.list_pending())
        elif self.path.startswith("/status/"):
            rid = self.path[len("/status/"):]
            rec = self.store.get_resolution(rid)
            if rec:
                self._send(200, rec)
            else:
                self._send(404, {"error": "not found"})
        else:
            self._send(404, {"error": "not found"})

    # ── POST /analyze ─────────────────────────────────────────────────────────

    def _handle_analyze(self) -> None:
        body = self._read_body()
        conflict_text = body.get("conflict_text", "")
        if not conflict_text:
            self._send(400, {"error": "conflict_text required"})
            return

        result = resolve_file_content(conflict_text)
        # Flatten for single-block callers
        strategy = result["strategies"][0]["strategy"] if result["strategies"] else "none"
        confidence = result["strategies"][0]["confidence"] if result["strategies"] else 1.0
        self._send(
            200,
            {
                "strategy": strategy,
                "confidence": confidence,
                "resolved": result["resolved"],
                "content": result["content"],
                "strategies": result["strategies"],
                "unresolved_count": result["unresolved_count"],
            },
        )

    # ── POST /resolve ─────────────────────────────────────────────────────────

    def _handle_resolve(self) -> None:
        body = self._read_body()
        branch = body.get("branch", "")
        base_branch = body.get("base_branch", "main")
        repo_path = body.get("repo_path", os.getcwd())
        files_override: list[str] | None = body.get("files")

        if not branch:
            self._send(400, {"error": "branch required"})
            return

        # Discover conflicted files
        try:
            files = files_override if files_override is not None else conflicted_files(repo_path)
        except Exception as exc:
            self._send(500, {"error": str(exc)})
            return

        resolution_id = str(uuid.uuid4())
        resolved_files: list[str] = []
        unresolved_files: list[str] = []
        all_strategies: dict[str, list[dict[str, Any]]] = {}

        for fpath in files:
            try:
                content = read_conflict_file(fpath, repo_path)
            except OSError as exc:
                log.warning("Cannot read %s: %s", fpath, exc)
                unresolved_files.append(fpath)
                continue

            result = resolve_file_content(content)
            all_strategies[fpath] = result["strategies"]

            if result["resolved"]:
                try:
                    write_resolved_file(fpath, result["content"], repo_path)
                    resolved_files.append(fpath)
                    log.info("Resolved %s", fpath)
                except OSError as exc:
                    log.warning("Cannot write %s: %s", fpath, exc)
                    unresolved_files.append(fpath)
            else:
                unresolved_files.append(fpath)
                log.info("Could not fully resolve %s (%d blocks remain)",
                         fpath, result["unresolved_count"])

        state = (
            "resolved" if not unresolved_files
            else "partial" if resolved_files
            else "unresolved"
        )

        record: dict[str, Any] = {
            "resolution_id": resolution_id,
            "branch": branch,
            "base_branch": base_branch,
            "repo_path": repo_path,
            "state": state,
            "resolved_files": resolved_files,
            "unresolved_files": unresolved_files,
            "strategies": all_strategies,
            "subtasks": [],
            "created_at": time.time(),
        }
        self.store.add_resolution(record)

        self._send(
            201,
            {
                "ok": True,
                "resolution_id": resolution_id,
                "state": state,
                "resolved_files": resolved_files,
                "unresolved_files": unresolved_files,
                "strategies": all_strategies,
            },
        )

    # ── POST /split ───────────────────────────────────────────────────────────

    def _handle_split(self) -> None:
        body = self._read_body()
        resolution_id = body.get("resolution_id", "")
        file_path = body.get("file_path", "")

        if not resolution_id or not file_path:
            self._send(400, {"error": "resolution_id and file_path required"})
            return

        rec = self.store.get_resolution(resolution_id)
        if rec is None:
            self._send(404, {"error": "resolution not found"})
            return

        strategies = rec.get("strategies", {}).get(file_path, [])

        try:
            meta = create_subtask(
                file_path=file_path,
                resolution_id=resolution_id,
                branch=rec["branch"],
                base_branch=rec["base_branch"],
                strategies=strategies,
                repo_path=rec["repo_path"],
            )
        except OSError as exc:
            self._send(500, {"error": str(exc)})
            return

        self.store.record_subtask(resolution_id, file_path, meta)
        self._send(201, {"ok": True, **meta})


# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------

class _ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    """HTTPServer that handles each request in a separate thread."""
    daemon_threads = True


def make_server(port: int = PORT, state_file: str = STATE_FILE) -> HTTPServer:
    store = ConflictStore(state_file)

    class _Handler(Handler):
        pass

    _Handler.store = store
    server = _ThreadingHTTPServer(("0.0.0.0", port), _Handler)
    return server


def main() -> None:  # pragma: no cover
    server = make_server()
    log.info("Conflict resolver listening on port %d", PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")


if __name__ == "__main__":
    main()
