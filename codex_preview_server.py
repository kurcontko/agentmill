#!/usr/bin/env python3
"""Codex Engine Dashboard — multi-agent preview server with SSE streaming.

Serves the static dashboard UI and broadcasts agent state changes via SSE.
Agent state is read from files written by the supervisor process.
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

STATIC_DIR = Path(__file__).resolve().parent / "static"


# ---------------------------------------------------------------------------
# File watcher — polls agent state directories and broadcasts changes via SSE
# ---------------------------------------------------------------------------

class FileWatcher:
    """Watch agent state files and broadcast changes to SSE subscribers."""

    def __init__(self, root: Path, interval: float = 0.8):
        self.root = root
        self.interval = interval
        self._subscribers: list[queue.Queue] = []
        self._lock = threading.Lock()
        self._mtimes: dict[str, float] = {}
        self._agents_key = ""
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=64)
        with self._lock:
            self._subscribers.append(q)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self._lock:
            try:
                self._subscribers.remove(q)
            except ValueError:
                pass

    def _broadcast(self, event: str, data: str) -> None:
        msg = f"event: {event}\ndata: {data}\n\n"
        with self._lock:
            dead: list[queue.Queue] = []
            for q in self._subscribers:
                try:
                    q.put_nowait(msg)
                except queue.Full:
                    dead.append(q)
            for q in dead:
                self._subscribers.remove(q)

    def _run(self) -> None:
        while True:
            try:
                self._poll()
            except Exception:
                pass
            time.sleep(self.interval)

    def _poll(self) -> None:
        agents = sorted(p.name for p in self.root.glob("agent-*") if p.is_dir())
        key = ",".join(agents)
        if key != self._agents_key:
            self._agents_key = key
            self._broadcast("agents", json.dumps({"agents": agents}))

        for name in agents:
            d = self.root / name
            self._check_json(d / "status.json", f"{name}:status", "status", name)
            self._check_json(d / "recent-events.json", f"{name}:events", "events", name)
            self._check_text(d / "diff-stat.txt", f"{name}:diff", "diff", name)

    def _check_json(self, path: Path, key: str, event: str, agent: str) -> None:
        mtime = _mtime(path)
        if not mtime or mtime == self._mtimes.get(key):
            return
        text = _read_safe(path)
        if not text:
            return
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            return  # torn read
        self._mtimes[key] = mtime
        self._broadcast(event, json.dumps({"agent": agent, "data": parsed}))

    def _check_text(self, path: Path, key: str, event: str, agent: str) -> None:
        mtime = _mtime(path)
        if mtime == self._mtimes.get(key):
            return
        self._mtimes[key] = mtime
        self._broadcast(event, json.dumps({"agent": agent, "data": _read_safe(path)}))


def _mtime(path: Path) -> float:
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


def _read_safe(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

def _select_agent(root: Path, requested: str | None) -> Path | None:
    if requested:
        candidate = root / requested
        return candidate if candidate.is_dir() else None
    agents = sorted(p for p in root.glob("agent-*") if p.is_dir())
    return agents[0] if agents else None


class Handler(BaseHTTPRequestHandler):
    root: Path = Path("/workspace/logs/codex-preview")
    watcher: FileWatcher | None = None
    _html_cache: str | None = None

    def log_message(self, format: str, *args: object) -> None:
        pass

    def _json(self, data: object, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _text(self, body: str, ct: str = "text/plain; charset=utf-8", status: int = HTTPStatus.OK) -> None:
        enc = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(enc)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(enc)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        path = parsed.path

        if path == "/":
            self._serve_index()
        elif path == "/api/stream":
            self._sse()
        elif path == "/api/agents":
            agents = [p.name for p in sorted(self.root.glob("agent-*")) if p.is_dir()]
            self._json({"agents": agents})
        elif path in ("/api/status", "/api/events", "/api/diff-stat"):
            self._serve_agent_file(path, qs)
        else:
            self._json({"error": "Not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        if parsed.path == "/api/stop":
            name = (qs.get("agent") or [None])[0]
            if not name:
                self._json({"error": "agent parameter required"}, HTTPStatus.BAD_REQUEST)
                return
            agent_dir = self.root / name
            if not agent_dir.is_dir():
                self._json({"error": "agent not found"}, HTTPStatus.NOT_FOUND)
                return
            (agent_dir / "stop.signal").write_text("stop\n", encoding="utf-8")
            self._json({"ok": True, "agent": name})
        else:
            self._json({"error": "Not found"}, HTTPStatus.NOT_FOUND)

    def _serve_index(self) -> None:
        cls = type(self)
        if cls._html_cache is None:
            cls._html_cache = (STATIC_DIR / "index.html").read_text(encoding="utf-8")
        self._text(cls._html_cache, "text/html; charset=utf-8")

    def _serve_agent_file(self, path: str, qs: dict) -> None:
        agent_dir = _select_agent(self.root, (qs.get("agent") or [None])[0])
        if agent_dir is None:
            self._json({"error": "No agent preview data found yet."}, HTTPStatus.NOT_FOUND)
            return

        _files = {
            "/api/status": ("status.json", "application/json; charset=utf-8"),
            "/api/events": ("recent-events.json", "application/json; charset=utf-8"),
            "/api/diff-stat": ("diff-stat.txt", "text/plain; charset=utf-8"),
        }
        fname, ct = _files[path]
        fp = agent_dir / fname
        if not fp.exists():
            self._json([] if fname == "recent-events.json" else {"error": f"{fname} not found"}, HTTPStatus.NOT_FOUND)
            return
        self._text(fp.read_text(encoding="utf-8"), ct)

    def _sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        if not self.watcher:
            self.wfile.write(b'event: error\ndata: {"error":"No watcher"}\n\n')
            self.wfile.flush()
            return

        sub = self.watcher.subscribe()
        try:
            while True:
                try:
                    msg = sub.get(timeout=15)
                    self.wfile.write(msg.encode())
                    self.wfile.flush()
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.watcher.unsubscribe(sub)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Codex Engine Dashboard")
    parser.add_argument("--root", default="/workspace/logs/codex-preview")
    parser.add_argument("--port", type=int, default=3001)
    args = parser.parse_args()

    root = Path(args.root)
    root.mkdir(parents=True, exist_ok=True)

    watcher = FileWatcher(root, interval=0.8)
    Handler.root = root
    Handler.watcher = watcher

    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"Codex Engine Dashboard listening on http://0.0.0.0:{args.port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
