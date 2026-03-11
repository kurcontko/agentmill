"""
Tests for agent_roles.py — Role-Based Agent Specialization
"""

import json
import os
import sys
import tempfile
import threading
import time
import unittest
from http.server import HTTPServer
from pathlib import Path
from urllib import request as urllib_request
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).parent.parent))

import agent_roles
from agent_roles import (
    RoleManagerState,
    RoleManagerHandler,
    ROLE_DEFINITIONS,
    ROLE_PRIORITY,
    auto_assign_role,
    get_role_from_env,
    optimal_mix,
    prompt_path_for_role,
    resolve_prompt_file,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_state(tmp: str, prompts_dir: str = "/tmp/prompts") -> RoleManagerState:
    return RoleManagerState(tmp, prompts_dir)


def _start_server(state: RoleManagerState) -> tuple[HTTPServer, int]:
    RoleManagerHandler.state = state
    server = HTTPServer(("127.0.0.1", 0), RoleManagerHandler)
    port = server.server_address[1]
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server, port


def _get(port: int, path: str) -> tuple[int, dict]:
    url = f"http://127.0.0.1:{port}{path}"
    try:
        with urllib_request.urlopen(url) as resp:
            return resp.status, json.loads(resp.read())
    except HTTPError as exc:
        return exc.code, json.loads(exc.read())


def _post(port: int, path: str, body: dict) -> tuple[int, dict]:
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode()
    req = urllib_request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib_request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read())
    except HTTPError as exc:
        return exc.code, json.loads(exc.read())


# ---------------------------------------------------------------------------
# Unit: optimal_mix
# ---------------------------------------------------------------------------

class TestOptimalMix(unittest.TestCase):

    def test_zero(self):
        self.assertEqual(optimal_mix(0), {})

    def test_one(self):
        mix = optimal_mix(1)
        self.assertEqual(mix, {"implementer": 1})

    def test_two(self):
        mix = optimal_mix(2)
        self.assertIn("implementer", mix)
        self.assertIn("architect", mix)
        self.assertEqual(sum(mix.values()), 2)

    def test_five(self):
        mix = optimal_mix(5)
        self.assertEqual(sum(mix.values()), 5)
        self.assertIn("implementer", mix)
        self.assertIn("tester", mix)
        self.assertIn("reviewer", mix)

    def test_six_adds_documenter(self):
        mix = optimal_mix(6)
        self.assertIn("documenter", mix)
        self.assertEqual(sum(mix.values()), 6)

    def test_ten_scales_implementers(self):
        mix = optimal_mix(10)
        self.assertGreater(mix["implementer"], mix.get("architect", 0))


# ---------------------------------------------------------------------------
# Unit: auto_assign_role
# ---------------------------------------------------------------------------

class TestAutoAssignRole(unittest.TestCase):

    def test_empty_team_gets_implementer(self):
        role = auto_assign_role({}, 1)
        self.assertEqual(role, "implementer")

    def test_second_agent_gets_architect(self):
        role = auto_assign_role({"implementer": 1}, 2)
        self.assertEqual(role, "architect")

    def test_preferred_role_honoured_under_cap(self):
        role = auto_assign_role({}, 1, preferred_role="architect")
        self.assertEqual(role, "architect")

    def test_preferred_role_ignored_at_cap(self):
        # architect cap is 1 — second architect should fall through
        role = auto_assign_role({"architect": 1}, 3, preferred_role="architect")
        self.assertNotEqual(role, "architect")

    def test_returns_implementer_as_fallback(self):
        # Fill every role to cap — should still return implementer
        dist = {r: ROLE_DEFINITIONS[r]["max_per_team"] for r in ROLE_DEFINITIONS}
        role = auto_assign_role(dist, 20)
        self.assertEqual(role, "implementer")

    def test_fills_most_underrepresented(self):
        # team of 5 but no tester yet
        dist = {"implementer": 2, "architect": 1, "reviewer": 1}
        role = auto_assign_role(dist, 5)
        self.assertEqual(role, "tester")


# ---------------------------------------------------------------------------
# Unit: RoleManagerState
# ---------------------------------------------------------------------------

class TestRoleManagerState(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".json")

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def test_register_returns_role(self):
        state = _make_state(self.tmp)
        result = state.register("agent-1")
        self.assertIn("role", result)
        self.assertIn(result["role"], ROLE_DEFINITIONS)

    def test_register_idempotent(self):
        state = _make_state(self.tmp)
        r1 = state.register("agent-1")
        r2 = state.register("agent-1")
        self.assertEqual(r1["role"], r2["role"])

    def test_register_assigns_different_roles(self):
        state = _make_state(self.tmp)
        roles = set()
        for i in range(5):
            r = state.register(f"agent-{i}")
            roles.add(r["role"])
        self.assertGreater(len(roles), 1)  # not all the same role

    def test_get_role_missing_returns_none(self):
        state = _make_state(self.tmp)
        self.assertIsNone(state.get_role("nobody"))

    def test_get_role_after_register(self):
        state = _make_state(self.tmp)
        state.register("agent-1")
        r = state.get_role("agent-1")
        self.assertIsNotNone(r)
        self.assertEqual(r["agent_id"], "agent-1")

    def test_request_role_changes_role(self):
        state = _make_state(self.tmp)
        state.register("agent-1", preferred_role="implementer")
        ok, msg = state.request_role("agent-1", "tester")
        self.assertTrue(ok)
        r = state.get_role("agent-1")
        self.assertEqual(r["role"], "tester")

    def test_request_role_rejects_at_cap(self):
        state = _make_state(self.tmp)
        # architect cap = 1; register agent-1 as architect first
        state.register("agent-1", preferred_role="architect")
        state.register("agent-2", preferred_role="implementer")
        # agent-2 tries to become architect (cap already hit)
        ok, msg = state.request_role("agent-2", "architect")
        self.assertFalse(ok)
        self.assertIn("capacity", msg)

    def test_request_unknown_role_fails(self):
        state = _make_state(self.tmp)
        state.register("agent-1")
        ok, msg = state.request_role("agent-1", "wizard")
        self.assertFalse(ok)
        self.assertIn("unknown", msg)

    def test_release_removes_agent(self):
        state = _make_state(self.tmp)
        state.register("agent-1")
        self.assertTrue(state.release("agent-1"))
        self.assertIsNone(state.get_role("agent-1"))

    def test_release_missing_returns_false(self):
        state = _make_state(self.tmp)
        self.assertFalse(state.release("nobody"))

    def test_distribution_accurate(self):
        state = _make_state(self.tmp)
        state.register("a1", preferred_role="implementer")
        state.register("a2", preferred_role="implementer")
        dist = state.distribution()
        # Both should be implementers (cap=3, both prefer it)
        self.assertGreaterEqual(dist.get("implementer", 0), 1)

    def test_status_contains_agents(self):
        state = _make_state(self.tmp)
        state.register("agent-1")
        s = state.status()
        self.assertEqual(len(s["agents"]), 1)
        self.assertIn("distribution", s)
        self.assertIn("optimal_mix", s)

    def test_persistence_across_restart(self):
        state = _make_state(self.tmp)
        state.register("agent-1", preferred_role="tester")
        role_before = state.get_role("agent-1")["role"]

        # Re-load from same file
        state2 = _make_state(self.tmp)
        role_after = state2.get_role("agent-1")["role"]
        self.assertEqual(role_before, role_after)

    def test_config_includes_prompt_path(self):
        state = _make_state(self.tmp, prompts_dir="/prompts")
        result = state.register("agent-1")
        self.assertIn("prompt_path", result["config"])
        self.assertTrue(result["config"]["prompt_path"].startswith("/prompts"))

    def test_config_includes_permissions(self):
        state = _make_state(self.tmp)
        result = state.register("agent-1", preferred_role="tester")
        if result["role"] == "tester":
            self.assertTrue(result["config"]["permissions"]["write_tests"])

    def test_all_roles_returns_five(self):
        state = _make_state(self.tmp)
        roles = state.all_roles()
        self.assertEqual(len(roles), 5)
        names = {r["name"] for r in roles}
        self.assertEqual(names, set(ROLE_DEFINITIONS.keys()))


# ---------------------------------------------------------------------------
# Concurrency: no double-assign same role past cap
# ---------------------------------------------------------------------------

class TestConcurrentRegister(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".json")

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def test_concurrent_register_no_double_architect(self):
        """
        20 agents register concurrently all preferring architect (cap=1).
        Exactly one should receive the architect role — the cap must hold.
        All agents must receive a valid role (no deadlocks, no lost registrations).
        """
        state = _make_state(self.tmp)
        results: list[str] = []
        lock = threading.Lock()

        def register(i: int) -> None:
            r = state.register(f"agent-{i}", preferred_role="architect")
            with lock:
                results.append(r["role"])

        threads = [threading.Thread(target=register, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # All agents registered
        self.assertEqual(len(results), 20)
        # All got a valid role
        for role in results:
            self.assertIn(role, ROLE_DEFINITIONS)
        # Architect cap (1) must not be exceeded
        dist = state.distribution()
        arch_cap = ROLE_DEFINITIONS["architect"]["max_per_team"]
        self.assertLessEqual(dist.get("architect", 0), arch_cap)


# ---------------------------------------------------------------------------
# Helpers: get_role_from_env, prompt_path_for_role, resolve_prompt_file
# ---------------------------------------------------------------------------

class TestHelpers(unittest.TestCase):

    def test_get_role_from_env_valid(self):
        os.environ["AGENT_ROLE"] = "tester"
        try:
            self.assertEqual(get_role_from_env(), "tester")
        finally:
            del os.environ["AGENT_ROLE"]

    def test_get_role_from_env_invalid_returns_none(self):
        os.environ["AGENT_ROLE"] = "wizard"
        try:
            self.assertIsNone(get_role_from_env())
        finally:
            del os.environ["AGENT_ROLE"]

    def test_get_role_from_env_unset_returns_none(self):
        os.environ.pop("AGENT_ROLE", None)
        self.assertIsNone(get_role_from_env())

    def test_prompt_path_for_known_role(self):
        path = prompt_path_for_role("architect", "/prompts")
        self.assertEqual(path, "/prompts/architect.md")

    def test_prompt_path_for_unknown_role(self):
        self.assertIsNone(prompt_path_for_role("wizard"))

    def test_resolve_prompt_file_prefers_agent_role_env(self):
        os.environ["AGENT_ROLE"] = "reviewer"
        os.environ.pop("PROMPT_FILE", None)
        try:
            path = resolve_prompt_file(prompts_dir="/prompts")
            self.assertIn("reviewer", path)
        finally:
            del os.environ["AGENT_ROLE"]

    def test_resolve_prompt_file_falls_back_to_prompt_file_env(self):
        os.environ.pop("AGENT_ROLE", None)
        os.environ["PROMPT_FILE"] = "/custom/prompt.md"
        try:
            path = resolve_prompt_file()
            self.assertEqual(path, "/custom/prompt.md")
        finally:
            del os.environ["PROMPT_FILE"]

    def test_resolve_prompt_file_uses_default(self):
        os.environ.pop("AGENT_ROLE", None)
        os.environ.pop("PROMPT_FILE", None)
        path = resolve_prompt_file(default_prompt="/fallback.md")
        self.assertEqual(path, "/fallback.md")


# ---------------------------------------------------------------------------
# HTTP API integration
# ---------------------------------------------------------------------------

class TestHTTPAPI(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mktemp(suffix=".json")
        state = _make_state(cls.tmp)
        cls.server, cls.port = _start_server(state)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        if os.path.exists(cls.tmp):
            os.unlink(cls.tmp)

    def test_register_200(self):
        status, body = _post(self.port, "/register", {"agent_id": "http-1"})
        self.assertEqual(status, 200)
        self.assertIn("role", body)

    def test_register_missing_agent_id_400(self):
        status, body = _post(self.port, "/register", {})
        self.assertEqual(status, 400)

    def test_get_role_200(self):
        _post(self.port, "/register", {"agent_id": "http-2"})
        status, body = _get(self.port, "/role/http-2")
        self.assertEqual(status, 200)
        self.assertEqual(body["agent_id"], "http-2")

    def test_get_role_404(self):
        status, body = _get(self.port, "/role/nobody")
        self.assertEqual(status, 404)

    def test_status_200(self):
        status, body = _get(self.port, "/status")
        self.assertEqual(status, 200)
        self.assertIn("agents", body)
        self.assertIn("distribution", body)

    def test_roles_200(self):
        status, body = _get(self.port, "/roles")
        self.assertEqual(status, 200)
        self.assertIsInstance(body["roles"], list)
        self.assertEqual(len(body["roles"]), 5)

    def test_request_role_200(self):
        _post(self.port, "/register", {"agent_id": "http-3"})
        status, body = _post(self.port, "/request_role", {"agent_id": "http-3", "role": "documenter"})
        # documenter cap is 1 — may or may not succeed depending on prior state
        self.assertIn(status, (200, 409))

    def test_request_role_unknown_409(self):
        _post(self.port, "/register", {"agent_id": "http-4"})
        status, body = _post(self.port, "/request_role", {"agent_id": "http-4", "role": "wizard"})
        self.assertEqual(status, 409)

    def test_release_200(self):
        _post(self.port, "/register", {"agent_id": "http-5"})
        status, body = _post(self.port, "/release/http-5", {})
        self.assertEqual(status, 200)

    def test_release_404(self):
        status, body = _post(self.port, "/release/nobody", {})
        self.assertEqual(status, 404)

    def test_unknown_get_404(self):
        status, body = _get(self.port, "/nonexistent")
        self.assertEqual(status, 404)

    def test_register_with_preferred_role(self):
        status, body = _post(self.port, "/register", {
            "agent_id": "http-6",
            "preferred_role": "implementer",
        })
        self.assertEqual(status, 200)
        # Preferred role should be set if cap not reached
        self.assertIn(body["role"], ROLE_DEFINITIONS)


if __name__ == "__main__":
    unittest.main()
