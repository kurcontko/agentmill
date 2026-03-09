#!/usr/bin/env python3
"""Codex Engine Dashboard — multi-agent grid preview server with SSE streaming."""
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
# SSE file-watch broadcaster
# ---------------------------------------------------------------------------

class FileWatcher:
    """Watch agent state files and broadcast changes via SSE."""

    def __init__(self, root: Path, interval: float = 0.8):
        self.root = root
        self.interval = interval
        self.subscribers: list[queue.Queue] = []
        self.lock = threading.Lock()
        self._mtimes: dict[str, float] = {}
        self._agents_key: str = ""
        self._running = True
        self._thread = threading.Thread(target=self._poll_loop, daemon=True)
        self._thread.start()

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=64)
        with self.lock:
            self.subscribers.append(q)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self.lock:
            try:
                self.subscribers.remove(q)
            except ValueError:
                pass

    def _broadcast(self, event: str, data: str) -> None:
        msg = f"event: {event}\ndata: {data}\n\n"
        with self.lock:
            dead: list[queue.Queue] = []
            for q in self.subscribers:
                try:
                    q.put_nowait(msg)
                except queue.Full:
                    dead.append(q)
            for q in dead:
                self.subscribers.remove(q)

    def _read_safe(self, path: Path) -> str:
        try:
            return path.read_text(encoding="utf-8")
        except OSError:
            return ""

    def _get_mtime(self, path: Path) -> float:
        try:
            return os.path.getmtime(path)
        except OSError:
            return 0.0

    def _poll_loop(self) -> None:
        while self._running:
            try:
                self._poll_once()
            except Exception:
                pass
            time.sleep(self.interval)

    def _poll_once(self) -> None:
        agents = sorted(p.name for p in self.root.glob("agent-*") if p.is_dir())
        agents_key = json.dumps(agents)
        if self._agents_key != agents_key:
            self._agents_key = agents_key
            self._broadcast("agents", json.dumps({"agents": agents}))

        for agent_name in agents:
            agent_dir = self.root / agent_name

            # status.json
            status_path = agent_dir / "status.json"
            status_mtime_key = f"{agent_name}:status"
            status_mtime = self._get_mtime(status_path)
            if status_mtime and self._mtimes.get(status_mtime_key) != status_mtime:
                status_text = self._read_safe(status_path)
                if status_text:
                    try:
                        parsed = json.loads(status_text)
                        self._mtimes[status_mtime_key] = status_mtime
                        self._broadcast("status", json.dumps({"agent": agent_name, "data": parsed}))
                    except json.JSONDecodeError:
                        pass  # torn read; retry on next poll

            # recent-events.json
            events_path = agent_dir / "recent-events.json"
            events_mtime_key = f"{agent_name}:events"
            events_mtime = self._get_mtime(events_path)
            if events_mtime and self._mtimes.get(events_mtime_key) != events_mtime:
                events_text = self._read_safe(events_path)
                if events_text:
                    try:
                        parsed = json.loads(events_text)
                        self._mtimes[events_mtime_key] = events_mtime
                        self._broadcast("events", json.dumps({"agent": agent_name, "data": parsed}))
                    except json.JSONDecodeError:
                        pass  # torn read; retry on next poll

            # diff-stat.txt
            diff_path = agent_dir / "diff-stat.txt"
            diff_mtime_key = f"{agent_name}:diff"
            diff_mtime = self._get_mtime(diff_path)
            if self._mtimes.get(diff_mtime_key) != diff_mtime:
                self._mtimes[diff_mtime_key] = diff_mtime
                diff_text = self._read_safe(diff_path)
                self._broadcast("diff", json.dumps({"agent": agent_name, "data": diff_text}))


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

def select_agent(root: Path, requested: str | None) -> Path | None:
    if requested:
        candidate = root / requested
        if candidate.is_dir():
            return candidate
        return None

    agents = sorted(path for path in root.glob("agent-*") if path.is_dir())
    if not agents:
        return None
    return agents[0]


class PreviewHandler(BaseHTTPRequestHandler):
    root = Path("/workspace/logs/codex-preview")
    watcher: FileWatcher | None = None
    _html_cache: str | None = None

    def _send_json(self, payload: object, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, body: str, content_type: str = "text/plain; charset=utf-8", status: int = HTTPStatus.OK) -> None:
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(encoded)

    @classmethod
    def _get_html(cls) -> str:
        if cls._html_cache is None:
            cls._html_cache = (STATIC_DIR / "index.html").read_text(encoding="utf-8")
        return cls._html_cache

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        agent_dir = select_agent(self.root, query.get("agent", [None])[0])

        if parsed.path == "/":
            self._send_text(self._get_html(), content_type="text/html; charset=utf-8")
            return

        if parsed.path == "/api/stream":
            self._handle_sse()
            return

        if parsed.path == "/api/agents":
            agents = [path.name for path in sorted(self.root.glob("agent-*")) if path.is_dir()]
            self._send_json({"agents": agents})
            return

        if agent_dir is None:
            self._send_json({"error": "No agent preview data found yet."}, status=HTTPStatus.NOT_FOUND)
            return

        if parsed.path == "/api/status":
            status_path = agent_dir / "status.json"
            if not status_path.exists():
                self._send_json({"error": "status.json not found"}, status=HTTPStatus.NOT_FOUND)
                return
            self._send_text(status_path.read_text(encoding="utf-8"), content_type="application/json; charset=utf-8")
            return

        if parsed.path == "/api/events":
            events_path = agent_dir / "recent-events.json"
            if not events_path.exists():
                self._send_json([])
                return
            self._send_text(events_path.read_text(encoding="utf-8"), content_type="application/json; charset=utf-8")
            return

        if parsed.path == "/api/diff-stat":
            diff_path = agent_dir / "diff-stat.txt"
            self._send_text(diff_path.read_text(encoding="utf-8") if diff_path.exists() else "")
            return

        self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def _handle_sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        if self.watcher is None:
            self.wfile.write(b"event: error\ndata: {\"error\": \"No watcher\"}\n\n")
            self.wfile.flush()
            return

        sub = self.watcher.subscribe()
        try:
            while True:
                try:
                    msg = sub.get(timeout=15)
                    self.wfile.write(msg.encode("utf-8"))
                    self.wfile.flush()
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.watcher.unsubscribe(sub)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        if parsed.path == "/api/stop":
            agent_name = query.get("agent", [None])[0]
            if not agent_name:
                self._send_json({"error": "agent parameter required"}, status=HTTPStatus.BAD_REQUEST)
                return
            agent_dir = self.root / agent_name
            if not agent_dir.is_dir():
                self._send_json({"error": "agent not found"}, status=HTTPStatus.NOT_FOUND)
                return
            signal_path = agent_dir / "stop.signal"
            signal_path.write_text("stop\n", encoding="utf-8")
            self._send_json({"ok": True, "agent": agent_name})
            return

        self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def log_message(self, format: str, *args) -> None:
        return


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Codex Engine Dashboard — multi-agent grid preview.")
    parser.add_argument("--root", default="/workspace/logs/codex-preview")
    parser.add_argument("--port", type=int, default=3001)
    args = parser.parse_args()

    root = Path(args.root)
    root.mkdir(parents=True, exist_ok=True)

    watcher = FileWatcher(root, interval=0.8)
    PreviewHandler.root = root
    PreviewHandler.watcher = watcher

    server = ThreadingHTTPServer(("0.0.0.0", args.port), PreviewHandler)
    print(f"Codex Engine Dashboard listening on http://0.0.0.0:{args.port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
