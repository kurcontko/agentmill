#!/usr/bin/env python3
"""
AgentMill Agent Message Bus

Lightweight HTTP pub/sub message bus for inter-agent communication.
Python 3.11+ stdlib only.

API
---
  POST /publish              body: {"from": "agent-1", "to": "*"|"agent-2", "topic": "status", "body": {...}}
                             -> 201 {"ok": true, "id": "msg-uuid"}
  GET  /subscribe/<agent-id> -> SSE stream of messages addressed to <agent-id> or "*"
  GET  /mailbox/<agent-id>   -> 200 {"messages": [...]}  (buffered, not yet acked)
  POST /ack                  body: {"agent": "agent-1", "id": "msg-uuid"}
                             -> 200 {"ok": true}
  DELETE /mailbox/<agent-id> -> 200 {"ok": true}  (clear all)
  GET  /status               -> 200 {"agents": [...], "total_messages": N, "pending_acks": N}
  GET  /topics               -> 200 {"topics": [...]}
  GET  /messages             -> 200 {"messages": [...]}  (last MAX_HISTORY messages)

Topics (conventional, not enforced)
-------------------------------------
  status      - agent broadcasts its current state
  task-done   - agent signals task completion
  request     - agent asks for help / delegates
  heartbeat   - liveness ping
  merge-ready - agent requests merge gate review (integrates with merge_gate.py)

State is persisted to STATE_FILE (default: logs/bus_state.json) on every mutation.
SSE subscribers receive live messages. Offline agents buffer in mailbox until acked.
"""

import json
import logging
import os
import queue
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

PORT = int(os.environ.get("BUS_PORT", "3003"))
STATE_FILE = os.environ.get("BUS_STATE_FILE", "logs/bus_state.json")
LOG_LEVEL = os.environ.get("BUS_LOG_LEVEL", "INFO")
MAX_HISTORY = int(os.environ.get("BUS_MAX_HISTORY", "500"))
MAILBOX_TTL = int(os.environ.get("BUS_MAILBOX_TTL", "3600"))  # seconds

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [message-bus] %(levelname)s %(message)s",
)
log = logging.getLogger("message_bus")


# ---------------------------------------------------------------------------
# Bus State
# ---------------------------------------------------------------------------


class MessageBus:
    """Thread-safe message bus with SSE delivery and persistent mailboxes."""

    def __init__(self, state_file: str = STATE_FILE) -> None:
        self._lock = threading.Lock()
        self._state_file = Path(state_file)
        # All messages (ring buffer capped at MAX_HISTORY)
        self._messages: list[dict] = []
        # Per-agent mailbox: agent_id -> [msg, ...] (unacked messages)
        self._mailboxes: dict[str, list[dict]] = {}
        # SSE subscribers: agent_id -> [queue.Queue, ...]
        self._subscribers: dict[str, list[queue.Queue]] = {}
        self._load_state()

    # ------------------------------------------------------------------
    # State persistence
    # ------------------------------------------------------------------

    def _load_state(self) -> None:
        if not self._state_file.exists():
            return
        try:
            data = json.loads(self._state_file.read_text())
            self._messages = data.get("messages", [])[-MAX_HISTORY:]
            self._mailboxes = data.get("mailboxes", {})
            log.info(
                "loaded state: %d messages, %d mailboxes",
                len(self._messages),
                len(self._mailboxes),
            )
        except Exception as exc:  # noqa: BLE001
            log.error("failed to load state: %s", exc)

    def _save_state(self) -> None:
        """Must be called with self._lock held."""
        self._state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._state_file.with_suffix(".tmp")
        tmp.write_text(
            json.dumps(
                {
                    "messages": self._messages[-MAX_HISTORY:],
                    "mailboxes": self._mailboxes,
                },
                indent=2,
            )
        )
        tmp.replace(self._state_file)

    # ------------------------------------------------------------------
    # Core operations
    # ------------------------------------------------------------------

    def publish(self, from_agent: str, to: str, topic: str, body: Any) -> str:
        """Publish a message. Returns message id."""
        msg_id = str(uuid.uuid4())
        msg = {
            "id": msg_id,
            "from": from_agent,
            "to": to,
            "topic": topic,
            "body": body,
            "ts": time.time(),
        }
        with self._lock:
            self._messages.append(msg)
            if len(self._messages) > MAX_HISTORY:
                self._messages = self._messages[-MAX_HISTORY:]
            # Deliver to mailboxes (all agents if broadcast, specific agent otherwise)
            recipients = (
                list(self._mailboxes.keys())
                if to == "*"
                else ([to] if to else [])
            )
            # Always ensure sender's mailbox exists
            if from_agent not in self._mailboxes:
                self._mailboxes[from_agent] = []
            for agent_id in recipients:
                if agent_id not in self._mailboxes:
                    self._mailboxes[agent_id] = []
                self._mailboxes[agent_id].append(msg)
            self._save_state()
            # Fan out to SSE subscribers (outside lock for delivery)
            subscribers_snapshot = dict(self._subscribers)

        # SSE delivery (outside lock)
        payload = json.dumps(msg)
        for agent_id, queues in subscribers_snapshot.items():
            if to == "*" or agent_id == to:
                for q in list(queues):
                    try:
                        q.put_nowait(payload)
                    except queue.Full:
                        pass

        log.info("published msg %s from=%s to=%s topic=%s", msg_id, from_agent, to, topic)
        return msg_id

    def subscribe(self, agent_id: str) -> "tuple[queue.Queue, callable]":
        """Register SSE subscriber. Returns (queue, unsubscribe_fn)."""
        q: queue.Queue = queue.Queue(maxsize=256)
        with self._lock:
            if agent_id not in self._subscribers:
                self._subscribers[agent_id] = []
            self._subscribers[agent_id].append(q)
            # Ensure mailbox exists
            if agent_id not in self._mailboxes:
                self._mailboxes[agent_id] = []
                self._save_state()

        def unsubscribe() -> None:
            with self._lock:
                if agent_id in self._subscribers:
                    try:
                        self._subscribers[agent_id].remove(q)
                    except ValueError:
                        pass
                    if not self._subscribers[agent_id]:
                        del self._subscribers[agent_id]

        return q, unsubscribe

    def get_mailbox(self, agent_id: str) -> list[dict]:
        with self._lock:
            return list(self._mailboxes.get(agent_id, []))

    def ack(self, agent_id: str, msg_id: str) -> bool:
        with self._lock:
            mailbox = self._mailboxes.get(agent_id, [])
            before = len(mailbox)
            self._mailboxes[agent_id] = [m for m in mailbox if m["id"] != msg_id]
            changed = len(self._mailboxes[agent_id]) < before
            if changed:
                self._save_state()
            return changed

    def clear_mailbox(self, agent_id: str) -> None:
        with self._lock:
            self._mailboxes[agent_id] = []
            self._save_state()

    def get_history(self, limit: int = MAX_HISTORY) -> list[dict]:
        with self._lock:
            return list(self._messages[-limit:])

    def get_topics(self) -> list[str]:
        with self._lock:
            return sorted({m["topic"] for m in self._messages})

    def status(self) -> dict:
        with self._lock:
            pending_acks = sum(len(v) for v in self._mailboxes.values())
            return {
                "agents": sorted(
                    set(list(self._mailboxes.keys()) + list(self._subscribers.keys()))
                ),
                "total_messages": len(self._messages),
                "pending_acks": pending_acks,
                "live_subscribers": {
                    k: len(v) for k, v in self._subscribers.items() if v
                },
            }


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

BUS = MessageBus()


def _read_json(handler: BaseHTTPRequestHandler) -> dict | None:
    length = int(handler.headers.get("Content-Length", 0))
    if not length:
        return {}
    try:
        return json.loads(handler.rfile.read(length))
    except json.JSONDecodeError:
        return None


def _send_json(handler: BaseHTTPRequestHandler, code: int, data: Any) -> None:
    body = json.dumps(data).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class BusHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:  # suppress default access log
        pass

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/publish":
            data = _read_json(self)
            if data is None:
                return _send_json(self, 400, {"error": "invalid json"})
            from_agent = data.get("from", "unknown")
            to = data.get("to", "*")
            topic = data.get("topic", "")
            body = data.get("body", {})
            if not topic:
                return _send_json(self, 400, {"error": "topic required"})
            msg_id = BUS.publish(from_agent, to, topic, body)
            return _send_json(self, 201, {"ok": True, "id": msg_id})

        if path == "/ack":
            data = _read_json(self)
            if data is None:
                return _send_json(self, 400, {"error": "invalid json"})
            agent = data.get("agent", "")
            msg_id = data.get("id", "")
            if not agent or not msg_id:
                return _send_json(self, 400, {"error": "agent and id required"})
            found = BUS.ack(agent, msg_id)
            return _send_json(self, 200, {"ok": True, "found": found})

        _send_json(self, 404, {"error": "not found"})

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        parts = parsed.path.strip("/").split("/")
        if len(parts) == 2 and parts[0] == "mailbox":
            agent_id = parts[1]
            BUS.clear_mailbox(agent_id)
            return _send_json(self, 200, {"ok": True})
        _send_json(self, 404, {"error": "not found"})

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        parts = parsed.path.strip("/").split("/")

        if parts[0] == "subscribe" and len(parts) == 2:
            agent_id = parts[1]
            self._sse_stream(agent_id)
            return

        if parts[0] == "mailbox" and len(parts) == 2:
            agent_id = parts[1]
            msgs = BUS.get_mailbox(agent_id)
            return _send_json(self, 200, {"messages": msgs})

        if parts[0] == "status" and len(parts) == 1:
            return _send_json(self, 200, BUS.status())

        if parts[0] == "topics" and len(parts) == 1:
            return _send_json(self, 200, {"topics": BUS.get_topics()})

        if parts[0] == "messages" and len(parts) == 1:
            return _send_json(self, 200, {"messages": BUS.get_history()})

        _send_json(self, 404, {"error": "not found"})

    def _sse_stream(self, agent_id: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        q, unsubscribe = BUS.subscribe(agent_id)
        log.info("SSE subscriber connected: %s", agent_id)
        try:
            # Send buffered mailbox first
            for msg in BUS.get_mailbox(agent_id):
                payload = f"data: {json.dumps(msg)}\n\n".encode()
                self.wfile.write(payload)
            self.wfile.flush()
            # Stream live messages
            while True:
                try:
                    data = q.get(timeout=30)
                    self.wfile.write(f"data: {data}\n\n".encode())
                    self.wfile.flush()
                except queue.Empty:
                    # Heartbeat to keep connection alive
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            unsubscribe()
            log.info("SSE subscriber disconnected: %s", agent_id)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run(port: int = PORT) -> None:
    server = HTTPServer(("0.0.0.0", port), BusHandler)
    log.info("message bus listening on port %d", port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        log.info("message bus stopped")


if __name__ == "__main__":
    run()
