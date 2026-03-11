#!/usr/bin/env python3
"""
AgentMill Role Manager — Role-Based Agent Specialization

Assigns roles to agents, balances role distribution, and provides per-role
configuration (prompt paths, coordinator filters, permissions).

Python 3.11+ stdlib only.

Roles
-----
  architect   — decomposes tasks, writes subtask specs
  implementer — writes application code
  tester      — writes and runs tests, votes in merge gate
  reviewer    — reviews diffs, casts merge gate votes
  documenter  — writes docs, keeps PROGRESS.md current

API
---
  POST /register          body: {"agent_id": "...", "preferred_role": "..."} (preferred_role optional)
                           -> 200 {"agent_id": ..., "role": ..., "config": {...}}
  GET  /role/<agent_id>   -> 200 {"agent_id": ..., "role": ..., "config": {...}} | 404
  POST /request_role      body: {"agent_id": "...", "role": "..."}
                           -> 200 {"ok": true, "role": ...} | 409 {"error": "role cap reached"}
  POST /release/<agent_id> -> 200 {"ok": true} | 404
  GET  /status            -> 200 {"agents": [...], "distribution": {...}, "optimal_mix": {...}}
  GET  /roles             -> 200 {"roles": [{name, description, prompt_path, max_per_team, ...}]}

State persisted to STATE_FILE.
Role assignment uses a priority queue: fill underrepresented roles first.
AGENT_ROLE env var overrides auto-assignment for an agent.
"""

import json
import logging
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("ROLE_MANAGER_PORT", "3006"))
STATE_FILE = os.environ.get("ROLE_MANAGER_STATE_FILE", "logs/role_manager_state.json")
PROMPTS_DIR = os.environ.get("PROMPTS_DIR", "prompts/roles")
LOG_LEVEL = os.environ.get("ROLE_MANAGER_LOG_LEVEL", "INFO")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [role_manager] %(levelname)s %(message)s",
)
log = logging.getLogger("role_manager")

# ---------------------------------------------------------------------------
# Role Definitions
# ---------------------------------------------------------------------------

ROLE_DEFINITIONS: dict[str, dict[str, Any]] = {
    "architect": {
        "name": "architect",
        "description": "Decomposes tasks into subtask specs. Does not write code.",
        "prompt_file": "architect.md",
        # maximum recommended count in a team of N (applied proportionally)
        "max_per_team": 1,
        # minimum to have at least one if team >= threshold
        "min_team_size": 2,
        "coordinator_role_filter": ["architect"],
        "permissions": {
            "write_code": False,
            "write_tests": False,
            "write_specs": True,
            "write_docs": False,
            "vote_merge_gate": False,
        },
    },
    "implementer": {
        "name": "implementer",
        "description": "Implements application code from subtask specs.",
        "prompt_file": "implementer.md",
        "max_per_team": 3,
        "min_team_size": 1,
        "coordinator_role_filter": ["implementer"],
        "permissions": {
            "write_code": True,
            "write_tests": False,
            "write_specs": False,
            "write_docs": False,
            "vote_merge_gate": False,
        },
    },
    "tester": {
        "name": "tester",
        "description": "Writes and runs tests, votes in merge gate.",
        "prompt_file": "tester.md",
        "max_per_team": 2,
        "min_team_size": 2,
        "coordinator_role_filter": ["tester"],
        "permissions": {
            "write_code": False,
            "write_tests": True,
            "write_specs": False,
            "write_docs": False,
            "vote_merge_gate": True,
        },
    },
    "reviewer": {
        "name": "reviewer",
        "description": "Reviews diffs, casts merge gate votes.",
        "prompt_file": "reviewer.md",
        "max_per_team": 2,
        "min_team_size": 3,
        "coordinator_role_filter": ["reviewer"],
        "permissions": {
            "write_code": False,
            "write_tests": False,
            "write_specs": False,
            "write_docs": True,   # review summaries
            "vote_merge_gate": True,
        },
    },
    "documenter": {
        "name": "documenter",
        "description": "Writes docs and keeps PROGRESS.md current.",
        "prompt_file": "documenter.md",
        "max_per_team": 1,
        "min_team_size": 4,
        "coordinator_role_filter": ["documenter"],
        "permissions": {
            "write_code": False,
            "write_tests": False,
            "write_specs": False,
            "write_docs": True,
            "vote_merge_gate": False,
        },
    },
}

# Priority order for auto-assignment (most needed first for small teams)
ROLE_PRIORITY = ["implementer", "architect", "tester", "reviewer", "documenter"]


def optimal_mix(team_size: int) -> dict[str, int]:
    """Return the ideal role distribution for a given team size."""
    if team_size <= 0:
        return {}
    if team_size == 1:
        return {"implementer": 1}
    if team_size == 2:
        return {"implementer": 1, "architect": 1}
    if team_size == 3:
        return {"implementer": 2, "architect": 1}
    if team_size == 4:
        return {"implementer": 2, "architect": 1, "tester": 1}
    if team_size == 5:
        return {"implementer": 2, "architect": 1, "tester": 1, "reviewer": 1}
    # 6+: add documenter, scale implementers beyond that
    extra = max(0, team_size - 6)
    return {
        "implementer": 2 + extra,
        "architect": 1,
        "tester": 1,
        "reviewer": 1,
        "documenter": 1,
    }


def auto_assign_role(current_distribution: dict[str, int], team_size: int, preferred_role: str | None = None) -> str:
    """
    Choose the best role for a new agent given current distribution.
    Prefers `preferred_role` if it is not over its max_per_team cap.
    Falls back to the most under-represented role in priority order.
    """
    target = optimal_mix(team_size)

    # Honour preference if under cap
    if preferred_role and preferred_role in ROLE_DEFINITIONS:
        cap = ROLE_DEFINITIONS[preferred_role]["max_per_team"]
        current_count = current_distribution.get(preferred_role, 0)
        if current_count < cap:
            return preferred_role

    # Fill the most under-represented role (relative to target)
    best_role = None
    best_deficit = -1
    for role in ROLE_PRIORITY:
        target_count = target.get(role, 0)
        if target_count == 0:
            continue
        current_count = current_distribution.get(role, 0)
        cap = ROLE_DEFINITIONS[role]["max_per_team"]
        if current_count >= cap:
            continue
        deficit = target_count - current_count
        if deficit > best_deficit:
            best_deficit = deficit
            best_role = role

    # Fall back to implementer if everything else is capped
    return best_role or "implementer"


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

class RoleManagerState:
    """Thread-safe state for role assignment tracking."""

    def __init__(self, state_file: str, prompts_dir: str) -> None:
        self.state_file = Path(state_file)
        self.prompts_dir = Path(prompts_dir)
        self.lock = threading.Lock()
        # agent_id -> {role, assigned_at, preferred_role}
        self.agents: dict[str, dict] = {}
        self._load()

    # -- Persistence --------------------------------------------------------

    def _load(self) -> None:
        if self.state_file.exists():
            try:
                data = json.loads(self.state_file.read_text())
                self.agents = data.get("agents", {})
                log.info("Loaded %d agent role assignments from %s", len(self.agents), self.state_file)
            except Exception as exc:
                log.warning("Could not load state: %s — starting fresh", exc)

    def _save(self) -> None:
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps({"agents": self.agents}, indent=2))
        tmp.replace(self.state_file)

    # -- Public API ---------------------------------------------------------

    def distribution(self) -> dict[str, int]:
        """Count agents per role."""
        dist: dict[str, int] = {}
        for info in self.agents.values():
            role = info["role"]
            dist[role] = dist.get(role, 0) + 1
        return dist

    def register(self, agent_id: str, preferred_role: str | None = None) -> dict:
        """Register an agent and assign it a role. Idempotent (returns existing role)."""
        with self.lock:
            if agent_id in self.agents:
                return self._agent_response(agent_id)
            team_size = len(self.agents) + 1
            dist = self.distribution()
            role = auto_assign_role(dist, team_size, preferred_role)
            self.agents[agent_id] = {
                "role": role,
                "assigned_at": time.time(),
                "preferred_role": preferred_role,
            }
            self._save()
            log.info("Registered agent %s as %s", agent_id, role)
            return self._agent_response(agent_id)

    def get_role(self, agent_id: str) -> dict | None:
        with self.lock:
            if agent_id not in self.agents:
                return None
            return self._agent_response(agent_id)

    def request_role(self, agent_id: str, role: str) -> tuple[bool, str]:
        """
        Attempt to switch an agent to a specific role.
        Returns (success, message).
        """
        if role not in ROLE_DEFINITIONS:
            return False, f"unknown role: {role}"
        with self.lock:
            dist = self.distribution()
            # Don't count this agent's current role against the cap check
            if agent_id in self.agents:
                current = self.agents[agent_id]["role"]
                dist[current] = max(0, dist.get(current, 0) - 1)
            cap = ROLE_DEFINITIONS[role]["max_per_team"]
            if dist.get(role, 0) >= cap:
                return False, f"role '{role}' is at capacity ({cap})"
            if agent_id not in self.agents:
                self.agents[agent_id] = {"preferred_role": role, "assigned_at": time.time()}
            self.agents[agent_id]["role"] = role
            self._save()
            log.info("Agent %s switched to role %s", agent_id, role)
            return True, role

    def release(self, agent_id: str) -> bool:
        with self.lock:
            if agent_id not in self.agents:
                return False
            del self.agents[agent_id]
            self._save()
            log.info("Released agent %s", agent_id)
            return True

    def status(self) -> dict:
        with self.lock:
            dist = self.distribution()
            team_size = len(self.agents)
            return {
                "agents": [
                    {
                        "agent_id": aid,
                        "role": info["role"],
                        "assigned_at": info["assigned_at"],
                    }
                    for aid, info in self.agents.items()
                ],
                "distribution": dist,
                "optimal_mix": optimal_mix(team_size),
            }

    def _agent_response(self, agent_id: str) -> dict:
        """Build the full response dict for an agent (caller must hold lock)."""
        info = self.agents[agent_id]
        role = info["role"]
        role_def = ROLE_DEFINITIONS[role]
        prompt_path = str(self.prompts_dir / role_def["prompt_file"])
        return {
            "agent_id": agent_id,
            "role": role,
            "config": {
                "prompt_path": prompt_path,
                "permissions": role_def["permissions"],
                "coordinator_role_filter": role_def["coordinator_role_filter"],
                "description": role_def["description"],
            },
        }

    def all_roles(self) -> list[dict]:
        """Return role definitions enriched with prompt paths."""
        result = []
        for role, defn in ROLE_DEFINITIONS.items():
            prompt_path = str(self.prompts_dir / defn["prompt_file"])
            result.append({
                "name": role,
                "description": defn["description"],
                "prompt_path": prompt_path,
                "max_per_team": defn["max_per_team"],
                "min_team_size": defn["min_team_size"],
                "permissions": defn["permissions"],
            })
        return result


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

class RoleManagerHandler(BaseHTTPRequestHandler):
    """Minimal HTTP handler — no frameworks."""

    state: RoleManagerState  # set on class by server setup

    # silence access log unless DEBUG
    def log_message(self, fmt: str, *args: Any) -> None:
        if log.isEnabledFor(logging.DEBUG):
            log.debug(fmt, *args)

    def _send(self, status: int, body: Any) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if not length:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {}

    # -- GET ----------------------------------------------------------------

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/status":
            self._send(200, self.state.status())

        elif path == "/roles":
            self._send(200, {"roles": self.state.all_roles()})

        elif path.startswith("/role/"):
            agent_id = path[len("/role/"):]
            result = self.state.get_role(agent_id)
            if result is None:
                self._send(404, {"error": "agent not found"})
            else:
                self._send(200, result)

        else:
            self._send(404, {"error": "not found"})

    # -- POST ---------------------------------------------------------------

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        body = self._read_body()

        if path == "/register":
            agent_id = body.get("agent_id", "").strip()
            if not agent_id:
                self._send(400, {"error": "agent_id required"})
                return
            preferred = body.get("preferred_role") or None
            result = self.state.register(agent_id, preferred)
            self._send(200, result)

        elif path == "/request_role":
            agent_id = body.get("agent_id", "").strip()
            role = body.get("role", "").strip()
            if not agent_id or not role:
                self._send(400, {"error": "agent_id and role required"})
                return
            ok, msg = self.state.request_role(agent_id, role)
            if ok:
                self._send(200, {"ok": True, "role": msg})
            else:
                self._send(409, {"error": msg})

        elif path.startswith("/release/"):
            agent_id = path[len("/release/"):]
            if self.state.release(agent_id):
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "agent not found"})

        else:
            self._send(404, {"error": "not found"})


# ---------------------------------------------------------------------------
# Convenience helpers for use without the HTTP server
# ---------------------------------------------------------------------------

def get_role_from_env(agent_id: str | None = None) -> str | None:
    """
    Return a role name if AGENT_ROLE env var is set and valid, else None.
    Useful for entrypoints that want to override auto-assignment.
    """
    role = os.environ.get("AGENT_ROLE", "").strip().lower()
    if role and role in ROLE_DEFINITIONS:
        return role
    if role:
        log.warning("Unknown AGENT_ROLE=%r — ignoring; valid roles: %s", role, list(ROLE_DEFINITIONS))
    return None


def prompt_path_for_role(role: str, prompts_dir: str = PROMPTS_DIR) -> str | None:
    """Return the absolute path to the prompt file for a role, or None if unknown."""
    if role not in ROLE_DEFINITIONS:
        return None
    return str(Path(prompts_dir) / ROLE_DEFINITIONS[role]["prompt_file"])


def resolve_prompt_file(
    agent_id: str | None = None,
    prompts_dir: str = PROMPTS_DIR,
    default_prompt: str | None = None,
) -> str:
    """
    Resolve the prompt file for this agent:
      1. AGENT_ROLE env var (highest priority)
      2. PROMPT_FILE env var (explicit override)
      3. default_prompt (fallback)

    Returns the path string (may not exist — caller should check).
    """
    # Env-var role override
    role = get_role_from_env(agent_id)
    if role:
        path = prompt_path_for_role(role, prompts_dir)
        if path:
            return path

    # Explicit PROMPT_FILE
    explicit = os.environ.get("PROMPT_FILE", "").strip()
    if explicit:
        return explicit

    return default_prompt or str(Path(prompts_dir).parent / "PROMPT.md")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _run_server(port: int, state_file: str, prompts_dir: str) -> None:
    state = RoleManagerState(state_file, prompts_dir)
    RoleManagerHandler.state = state

    server = HTTPServer(("0.0.0.0", port), RoleManagerHandler)
    log.info("Role manager listening on port %d", port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")
    finally:
        server.server_close()


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="AgentMill Role Manager")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--state-file", default=STATE_FILE)
    parser.add_argument("--prompts-dir", default=PROMPTS_DIR)

    # Subcommands for CLI introspection
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("serve", help="Start the HTTP server (default)")
    p_roles = sub.add_parser("roles", help="List role definitions")
    p_roles.add_argument("--prompts-dir", default=PROMPTS_DIR)
    p_resolve = sub.add_parser("resolve-prompt", help="Print the prompt path for AGENT_ROLE / PROMPT_FILE")
    p_resolve.add_argument("--agent-id", default=None)

    args = parser.parse_args()

    if args.cmd == "roles":
        state = RoleManagerState("/dev/null", args.prompts_dir)
        for r in state.all_roles():
            print(f"{r['name']:12s}  {r['description']}")
            print(f"             prompt: {r['prompt_path']}")
            print(f"             max:    {r['max_per_team']}  min_team: {r['min_team_size']}")
        return

    if args.cmd == "resolve-prompt":
        print(resolve_prompt_file(agent_id=getattr(args, "agent_id", None)))
        return

    _run_server(args.port, args.state_file, args.prompts_dir)


if __name__ == "__main__":
    main()
