#!/usr/bin/env python3
"""
AgentMill Dynamic Agent Scaler

Monitors queue depth (queue_server.py or coordinator.py) and adjusts the
number of running agent containers via Docker Compose or the Docker API.
Python 3.11+ stdlib only.

Scaling algorithm
-----------------
  desired = clamp(ceil(pending / TASKS_PER_AGENT), MIN_AGENTS, MAX_AGENTS)

  Scale up  when desired > current and scale-up cooldown has elapsed.
  Scale down when desired < current and scale-down cooldown has elapsed.
  Hysteresis: only scale down when pending < (current - 1) * TASKS_PER_AGENT
              (avoids thrashing at the boundary).

API (HTTP server for monitoring / control)
------------------------------------------
  GET  /status        -> 200 {"current": N, "desired": N, "pending": N, "policy": {...}}
  POST /policy        body: {"min": N, "max": N, "tasks_per_agent": N,
                             "scale_up_cooldown": N, "scale_down_cooldown": N}
                      -> 200 {"ok": true}
  POST /scale         body: {"count": N}   # manual override
                      -> 200 {"ok": true}
  POST /pause         -> 200 {"ok": true}  # disable auto-scaling
  POST /resume        -> 200 {"ok": true}
  GET  /history       -> 200 {"events": [...]}

Environment variables
---------------------
  SCALER_PORT            int    default 3007
  SCALER_QUEUE_URL       str    default http://localhost:3002  (queue_server)
  SCALER_COORDINATOR_URL str    default ""  (coordinator; takes priority if set)
  SCALER_COMPOSE_SERVICE str    default "agent-1"  (service name to scale)
  SCALER_COMPOSE_FILE    str    default "docker-compose.yml"
  SCALER_MIN_AGENTS      int    default 1
  SCALER_MAX_AGENTS      int    default 8
  SCALER_TASKS_PER_AGENT int    default 3
  SCALER_UP_COOLDOWN     int    seconds, default 30
  SCALER_DOWN_COOLDOWN   int    seconds, default 120
  SCALER_POLL_INTERVAL   int    seconds, default 15
  SCALER_DRY_RUN         bool   default false  (log intent, don't exec docker)
  SCALER_STATE_FILE      str    default logs/scaler_state.json
  SCALER_LOG_LEVEL       str    default INFO
  SCALER_BACKEND         str    "compose" (default) | "docker_api" | "none"
"""

import json
import logging
import math
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("SCALER_PORT", "3007"))
QUEUE_URL = os.environ.get("SCALER_QUEUE_URL", "http://localhost:3002")
COORDINATOR_URL = os.environ.get("SCALER_COORDINATOR_URL", "")
COMPOSE_SERVICE = os.environ.get("SCALER_COMPOSE_SERVICE", "agent-1")
COMPOSE_FILE = os.environ.get("SCALER_COMPOSE_FILE", "docker-compose.yml")
DRY_RUN = os.environ.get("SCALER_DRY_RUN", "false").lower() in ("1", "true", "yes")
STATE_FILE = os.environ.get("SCALER_STATE_FILE", "logs/scaler_state.json")
LOG_LEVEL = os.environ.get("SCALER_LOG_LEVEL", "INFO")
POLL_INTERVAL = int(os.environ.get("SCALER_POLL_INTERVAL", "15"))
BACKEND = os.environ.get("SCALER_BACKEND", "compose")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [scaler] %(levelname)s %(message)s",
)
log = logging.getLogger("scaler")

# ---------------------------------------------------------------------------
# Policy
# ---------------------------------------------------------------------------


class ScalingPolicy:
    def __init__(self) -> None:
        self.min_agents: int = int(os.environ.get("SCALER_MIN_AGENTS", "1"))
        self.max_agents: int = int(os.environ.get("SCALER_MAX_AGENTS", "8"))
        self.tasks_per_agent: int = int(os.environ.get("SCALER_TASKS_PER_AGENT", "3"))
        self.scale_up_cooldown: int = int(os.environ.get("SCALER_UP_COOLDOWN", "30"))
        self.scale_down_cooldown: int = int(os.environ.get("SCALER_DOWN_COOLDOWN", "120"))

    def desired(self, pending: int) -> int:
        """Compute desired agent count from pending task count."""
        raw = math.ceil(pending / max(self.tasks_per_agent, 1))
        return max(self.min_agents, min(self.max_agents, raw))

    def scale_down_threshold(self, current: int) -> int:
        """Pending must be below this to justify a scale-down."""
        return (current - 1) * self.tasks_per_agent

    def to_dict(self) -> dict[str, Any]:
        return {
            "min_agents": self.min_agents,
            "max_agents": self.max_agents,
            "tasks_per_agent": self.tasks_per_agent,
            "scale_up_cooldown": self.scale_up_cooldown,
            "scale_down_cooldown": self.scale_down_cooldown,
        }

    def update(self, data: dict[str, Any]) -> None:
        if "min" in data:
            self.min_agents = int(data["min"])
        if "max" in data:
            self.max_agents = int(data["max"])
        if "tasks_per_agent" in data:
            self.tasks_per_agent = int(data["tasks_per_agent"])
        if "scale_up_cooldown" in data:
            self.scale_up_cooldown = int(data["scale_up_cooldown"])
        if "scale_down_cooldown" in data:
            self.scale_down_cooldown = int(data["scale_down_cooldown"])


# ---------------------------------------------------------------------------
# Docker backends
# ---------------------------------------------------------------------------


class ComposeBackend:
    """Scale via `docker compose up -d --scale <service>=<N>`."""

    def __init__(self, service: str, compose_file: str, dry_run: bool = False) -> None:
        self.service = service
        self.compose_file = compose_file
        self.dry_run = dry_run

    def set_count(self, count: int) -> bool:
        """
        Scale the compose service to `count` replicas.
        Returns True on success.
        """
        cmd = [
            "docker", "compose",
            "-f", self.compose_file,
            "up", "-d",
            "--no-recreate",
            "--scale", f"{self.service}={count}",
        ]
        if self.dry_run:
            log.info("[DRY RUN] would exec: %s", " ".join(cmd))
            return True
        log.info("Scaling %s to %d: %s", self.service, count, " ".join(cmd))
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=60,
            )
            if result.returncode != 0:
                log.error("docker compose failed: %s", result.stderr.strip())
                return False
            return True
        except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
            log.error("docker compose exec error: %s", exc)
            return False

    def current_count(self) -> int:
        """
        Query running replica count via `docker compose ps`.
        Returns -1 if unavailable.
        """
        cmd = [
            "docker", "compose",
            "-f", self.compose_file,
            "ps", "--quiet", self.service,
        ]
        if self.dry_run:
            return -1
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            if result.returncode != 0:
                return -1
            lines = [l for l in result.stdout.splitlines() if l.strip()]
            return len(lines)
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return -1


class DockerAPIBackend:
    """
    Scale via the Docker Engine REST API (unix socket at /var/run/docker.sock).
    Uses service labels to find containers belonging to a compose service.
    """

    DOCKER_SOCK = "http+unix://%2Fvar%2Frun%2Fdocker.sock"

    def __init__(self, service: str, dry_run: bool = False) -> None:
        self.service = service
        self.dry_run = dry_run

    def _api(self, method: str, path: str, body: Any = None) -> Any:
        """Make a call to the Docker Engine API via unix socket."""
        import socket
        import http.client

        class UnixHTTPConnection(http.client.HTTPConnection):
            def __init__(self) -> None:
                super().__init__("localhost")

            def connect(self) -> None:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect("/var/run/docker.sock")

        conn = UnixHTTPConnection()
        headers = {"Content-Type": "application/json"}
        data = json.dumps(body).encode() if body is not None else None
        conn.request(method, f"/v1.43{path}", body=data, headers=headers)
        resp = conn.getresponse()
        raw = resp.read().decode()
        return json.loads(raw) if raw else {}

    def current_count(self) -> int:
        try:
            containers = self._api("GET", f"/containers/json?filters=%7B%22label%22:%5B%22com.docker.compose.service%3D{self.service}%22%5D,%22status%22:%5B%22running%22%5D%7D")
            return len(containers) if isinstance(containers, list) else -1
        except Exception as exc:
            log.warning("Docker API current_count error: %s", exc)
            return -1

    def set_count(self, count: int) -> bool:
        """Docker API doesn't expose scale directly; fall back to compose."""
        log.warning("DockerAPIBackend.set_count not implemented; use ComposeBackend")
        return False


class NoneBackend:
    """No-op backend — useful for unit tests."""

    def __init__(self) -> None:
        self._count = 1

    def current_count(self) -> int:
        return self._count

    def set_count(self, count: int) -> bool:
        log.info("[NONE backend] set_count(%d)", count)
        self._count = count
        return True


def make_backend(name: str) -> ComposeBackend | DockerAPIBackend | NoneBackend:
    if name == "docker_api":
        return DockerAPIBackend(COMPOSE_SERVICE, dry_run=DRY_RUN)
    if name == "none":
        return NoneBackend()
    return ComposeBackend(COMPOSE_SERVICE, COMPOSE_FILE, dry_run=DRY_RUN)


# ---------------------------------------------------------------------------
# Queue source
# ---------------------------------------------------------------------------


def fetch_pending(coordinator_url: str, queue_url: str) -> int:
    """
    Return the number of pending tasks from queue_server or coordinator.
    Coordinator takes priority when SCALER_COORDINATOR_URL is set.
    Returns -1 on error.
    """
    url = (coordinator_url or queue_url).rstrip("/") + "/status"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            data = json.loads(resp.read())
            return int(data.get("pending", -1))
    except urllib.error.URLError as exc:
        log.warning("fetch_pending %s: %s", url, exc.reason)
        return -1
    except Exception as exc:
        log.warning("fetch_pending %s: %s", url, exc)
        return -1


# ---------------------------------------------------------------------------
# Scaler state machine
# ---------------------------------------------------------------------------


class Scaler:
    def __init__(
        self,
        backend: ComposeBackend | DockerAPIBackend | NoneBackend,
        state_file: str | None = None,
    ) -> None:
        self._lock = threading.Lock()
        self.backend = backend
        self.policy = ScalingPolicy()
        self.paused: bool = False
        self._last_scale_up: float = 0.0
        self._last_scale_down: float = 0.0
        self._last_pending: int = 0
        self._current: int = -1  # cached; -1 = unknown
        self._history: list[dict[str, Any]] = []
        self._state_file = Path(state_file if state_file is not None else STATE_FILE)
        self._load_state()

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def _load_state(self) -> None:
        try:
            if self._state_file.exists():
                data = json.loads(self._state_file.read_text())
                pol = data.get("policy", {})
                if pol:
                    self.policy.update({
                        "min": pol.get("min_agents", self.policy.min_agents),
                        "max": pol.get("max_agents", self.policy.max_agents),
                        "tasks_per_agent": pol.get("tasks_per_agent", self.policy.tasks_per_agent),
                        "scale_up_cooldown": pol.get("scale_up_cooldown", self.policy.scale_up_cooldown),
                        "scale_down_cooldown": pol.get("scale_down_cooldown", self.policy.scale_down_cooldown),
                    })
                self.paused = data.get("paused", False)
                self._history = data.get("history", [])[-200:]
                log.info("Loaded state from %s (paused=%s)", self._state_file, self.paused)
        except Exception as exc:
            log.warning("Could not load state: %s", exc)

    def _save_state(self) -> None:
        try:
            self._state_file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._state_file.with_suffix(".tmp")
            tmp.write_text(json.dumps({
                "policy": self.policy.to_dict(),
                "paused": self.paused,
                "current": self._current,
                "history": self._history[-200:],
            }, indent=2))
            tmp.replace(self._state_file)
        except Exception as exc:
            log.warning("Could not save state: %s", exc)

    # ------------------------------------------------------------------
    # Core logic
    # ------------------------------------------------------------------

    def _record(self, event: str, **kwargs: Any) -> None:
        entry = {"ts": time.time(), "event": event, **kwargs}
        self._history.append(entry)
        if len(self._history) > 200:
            self._history = self._history[-200:]

    def tick(self) -> None:
        """One evaluation cycle. Called by background poll loop."""
        pending = fetch_pending(COORDINATOR_URL, QUEUE_URL)
        with self._lock:
            self._last_pending = pending if pending >= 0 else self._last_pending

            if self.paused:
                return

            if pending < 0:
                log.debug("Queue unreachable; skipping scale decision")
                return

            desired = self.policy.desired(pending)
            current = self.backend.current_count()
            if current < 0:
                log.debug("Cannot determine current agent count; skipping")
                return
            self._current = current

            now = time.time()

            if desired > current:
                since = now - self._last_scale_up
                if since < self.policy.scale_up_cooldown:
                    log.debug(
                        "Scale-up suppressed (cooldown %.0fs remaining)",
                        self.policy.scale_up_cooldown - since,
                    )
                    return
                log.info("Scale UP %d -> %d (pending=%d)", current, desired, pending)
                if self.backend.set_count(desired):
                    self._current = desired
                    self._last_scale_up = now
                    self._record("scale_up", from_count=current, to_count=desired, pending=pending)
                    self._save_state()

            elif desired < current:
                if pending >= self.policy.scale_down_threshold(current):
                    log.debug("Scale-down hysteresis: pending=%d >= threshold=%d",
                              pending, self.policy.scale_down_threshold(current))
                    return
                since = now - self._last_scale_down
                if since < self.policy.scale_down_cooldown:
                    log.debug(
                        "Scale-down suppressed (cooldown %.0fs remaining)",
                        self.policy.scale_down_cooldown - since,
                    )
                    return
                log.info("Scale DOWN %d -> %d (pending=%d)", current, desired, pending)
                if self.backend.set_count(desired):
                    self._current = desired
                    self._last_scale_down = now
                    self._record("scale_down", from_count=current, to_count=desired, pending=pending)
                    self._save_state()

    def manual_scale(self, count: int) -> bool:
        with self._lock:
            clamped = max(self.policy.min_agents, min(self.policy.max_agents, count))
            ok = self.backend.set_count(clamped)
            if ok:
                self._current = clamped
                self._record("manual_scale", to_count=clamped)
                self._save_state()
            return ok

    def update_policy(self, data: dict[str, Any]) -> None:
        with self._lock:
            self.policy.update(data)
            self._record("policy_update", **data)
            self._save_state()

    def pause(self) -> None:
        with self._lock:
            self.paused = True
            self._record("pause")
            self._save_state()

    def resume(self) -> None:
        with self._lock:
            self.paused = False
            self._record("resume")
            self._save_state()

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "current": self._current,
                "desired": self.policy.desired(self._last_pending),
                "pending": self._last_pending,
                "paused": self.paused,
                "policy": self.policy.to_dict(),
                "last_scale_up": self._last_scale_up,
                "last_scale_down": self._last_scale_down,
            }

    def history(self) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._history)


# ---------------------------------------------------------------------------
# Poll loop
# ---------------------------------------------------------------------------


def poll_loop(scaler: Scaler, stop_event: threading.Event) -> None:
    log.info("Poll loop started (interval=%ds)", POLL_INTERVAL)
    while not stop_event.is_set():
        try:
            scaler.tick()
        except Exception as exc:
            log.error("tick() error: %s", exc)
        stop_event.wait(timeout=POLL_INTERVAL)
    log.info("Poll loop stopped")


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------


def _make_handler(scaler: Scaler) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args: Any) -> None:  # silence access log
            pass

        def _send(self, code: int, body: Any) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _read_body(self) -> dict[str, Any]:
            length = int(self.headers.get("Content-Length", "0"))
            if length == 0:
                return {}
            return json.loads(self.rfile.read(length))

        def do_GET(self) -> None:
            if self.path == "/status":
                self._send(200, scaler.snapshot())
            elif self.path == "/history":
                self._send(200, {"events": scaler.history()})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self) -> None:
            body = self._read_body()
            if self.path == "/policy":
                scaler.update_policy(body)
                self._send(200, {"ok": True})
            elif self.path == "/scale":
                count = body.get("count")
                if not isinstance(count, int):
                    self._send(400, {"error": "count must be int"})
                    return
                ok = scaler.manual_scale(count)
                self._send(200, {"ok": ok})
            elif self.path == "/pause":
                scaler.pause()
                self._send(200, {"ok": True})
            elif self.path == "/resume":
                scaler.resume()
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "not found"})

    return Handler


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    backend = make_backend(BACKEND)
    scaler = Scaler(backend, state_file=STATE_FILE)

    stop_event = threading.Event()
    poll_thread = threading.Thread(target=poll_loop, args=(scaler, stop_event), daemon=True)
    poll_thread.start()

    server = HTTPServer(("0.0.0.0", PORT), _make_handler(scaler))
    log.info(
        "Scaler HTTP server on :%d  backend=%s  service=%s  dry_run=%s",
        PORT, BACKEND, COMPOSE_SERVICE, DRY_RUN,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        poll_thread.join(timeout=5)
        log.info("Scaler shut down")


if __name__ == "__main__":
    main()
