#!/usr/bin/env python3
"""Tests for scaler.py — dynamic agent scaling."""

import json
import os
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch, MagicMock

# Ensure repo root is on path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import scaler as sc


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def make_scaler(tmp_state: str, backend_name: str = "none") -> sc.Scaler:
    """Return a Scaler with NoneBackend and a temp state file."""
    backend = sc.NoneBackend()
    return sc.Scaler(backend, state_file=tmp_state)


# ---------------------------------------------------------------------------
# ScalingPolicy
# ---------------------------------------------------------------------------


class TestScalingPolicy(unittest.TestCase):
    def setUp(self):
        self.pol = sc.ScalingPolicy()
        self.pol.min_agents = 1
        self.pol.max_agents = 8
        self.pol.tasks_per_agent = 3

    def test_desired_zero_pending(self):
        self.assertEqual(self.pol.desired(0), 1)  # clamp to min

    def test_desired_exactly_one_agent(self):
        self.assertEqual(self.pol.desired(3), 1)

    def test_desired_two_agents(self):
        self.assertEqual(self.pol.desired(4), 2)

    def test_desired_max_clamped(self):
        self.assertEqual(self.pol.desired(100), 8)

    def test_desired_fractional_rounds_up(self):
        self.assertEqual(self.pol.desired(7), 3)  # ceil(7/3) = 3

    def test_min_clamped(self):
        self.pol.min_agents = 2
        self.assertEqual(self.pol.desired(0), 2)

    def test_scale_down_threshold(self):
        # With current=3, tasks_per_agent=3 → threshold = (3-1)*3 = 6
        self.assertEqual(self.pol.scale_down_threshold(3), 6)

    def test_update_partial(self):
        self.pol.update({"min": 2, "max": 10})
        self.assertEqual(self.pol.min_agents, 2)
        self.assertEqual(self.pol.max_agents, 10)
        self.assertEqual(self.pol.tasks_per_agent, 3)  # unchanged

    def test_to_dict(self):
        d = self.pol.to_dict()
        self.assertIn("min_agents", d)
        self.assertIn("max_agents", d)
        self.assertIn("tasks_per_agent", d)
        self.assertIn("scale_up_cooldown", d)
        self.assertIn("scale_down_cooldown", d)

    def test_desired_tasks_per_agent_one(self):
        self.pol.tasks_per_agent = 1
        self.assertEqual(self.pol.desired(5), 5)
        self.assertEqual(self.pol.desired(9), 8)  # max clamp


# ---------------------------------------------------------------------------
# NoneBackend
# ---------------------------------------------------------------------------


class TestNoneBackend(unittest.TestCase):
    def test_initial_count(self):
        b = sc.NoneBackend()
        self.assertEqual(b.current_count(), 1)

    def test_set_count(self):
        b = sc.NoneBackend()
        self.assertTrue(b.set_count(4))
        self.assertEqual(b.current_count(), 4)


# ---------------------------------------------------------------------------
# ComposeBackend (subprocess mocked)
# ---------------------------------------------------------------------------


class TestComposeBackend(unittest.TestCase):
    def _backend(self) -> sc.ComposeBackend:
        return sc.ComposeBackend("agent-1", "docker-compose.yml", dry_run=False)

    def test_set_count_success(self):
        b = self._backend()
        mock_result = MagicMock()
        mock_result.returncode = 0
        with patch("subprocess.run", return_value=mock_result) as mock_run:
            self.assertTrue(b.set_count(3))
            args = mock_run.call_args[0][0]
            self.assertIn("--scale", args)
            self.assertIn("agent-1=3", args)

    def test_set_count_failure(self):
        b = self._backend()
        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stderr = "error"
        with patch("subprocess.run", return_value=mock_result):
            self.assertFalse(b.set_count(3))

    def test_set_count_timeout(self):
        import subprocess
        b = self._backend()
        with patch("subprocess.run", side_effect=subprocess.TimeoutExpired("docker", 60)):
            self.assertFalse(b.set_count(3))

    def test_set_count_file_not_found(self):
        b = self._backend()
        with patch("subprocess.run", side_effect=FileNotFoundError):
            self.assertFalse(b.set_count(3))

    def test_dry_run_returns_true_without_exec(self):
        b = sc.ComposeBackend("agent-1", "docker-compose.yml", dry_run=True)
        with patch("subprocess.run") as mock_run:
            self.assertTrue(b.set_count(3))
            mock_run.assert_not_called()

    def test_current_count_parses_output(self):
        b = self._backend()
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "abc123\ndef456\n"
        with patch("subprocess.run", return_value=mock_result):
            self.assertEqual(b.current_count(), 2)

    def test_current_count_failure(self):
        b = self._backend()
        mock_result = MagicMock()
        mock_result.returncode = 1
        with patch("subprocess.run", return_value=mock_result):
            self.assertEqual(b.current_count(), -1)

    def test_dry_run_current_count_is_minus_one(self):
        b = sc.ComposeBackend("agent-1", "docker-compose.yml", dry_run=True)
        self.assertEqual(b.current_count(), -1)


# ---------------------------------------------------------------------------
# fetch_pending
# ---------------------------------------------------------------------------


class TestFetchPending(unittest.TestCase):
    def _mock_response(self, body: dict) -> MagicMock:
        m = MagicMock()
        m.read.return_value = json.dumps(body).encode()
        m.__enter__.return_value = m
        m.__exit__.return_value = False
        return m

    def test_reads_from_coordinator_when_set(self):
        with patch("urllib.request.urlopen", return_value=self._mock_response({"pending": 7})) as mock_open:
            result = sc.fetch_pending("http://coordinator:3003", "http://queue:3002")
            self.assertEqual(result, 7)
            self.assertIn("coordinator:3003", mock_open.call_args[0][0])

    def test_falls_back_to_queue_when_coordinator_empty(self):
        with patch("urllib.request.urlopen", return_value=self._mock_response({"pending": 3})) as mock_open:
            result = sc.fetch_pending("", "http://queue:3002")
            self.assertEqual(result, 3)
            self.assertIn("queue:3002", mock_open.call_args[0][0])

    def test_returns_minus_one_on_error(self):
        import urllib.error
        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("refused")):
            result = sc.fetch_pending("", "http://queue:3002")
            self.assertEqual(result, -1)

    def test_returns_minus_one_on_missing_key(self):
        with patch("urllib.request.urlopen", return_value=self._mock_response({})):
            # "pending" key missing → -1
            result = sc.fetch_pending("", "http://queue:3002")
            self.assertEqual(result, -1)


# ---------------------------------------------------------------------------
# Scaler state machine
# ---------------------------------------------------------------------------


class TestScalerTick(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".json")
        self.scaler = make_scaler(self.tmp)
        self.scaler.policy.min_agents = 1
        self.scaler.policy.max_agents = 8
        self.scaler.policy.tasks_per_agent = 3
        self.scaler.policy.scale_up_cooldown = 0
        self.scaler.policy.scale_down_cooldown = 0
        # NoneBackend starts at count=1
        self.scaler.backend._count = 1

    def _tick(self, pending: int) -> None:
        with patch("scaler.fetch_pending", return_value=pending):
            self.scaler.tick()

    def test_scale_up_when_queue_grows(self):
        self._tick(10)  # desired=4
        self.assertEqual(self.scaler.backend.current_count(), 4)

    def test_no_scale_when_balanced(self):
        self.scaler.backend._count = 2
        self._tick(4)  # desired=2 (ceil(4/3)=2)
        self.assertEqual(self.scaler.backend.current_count(), 2)

    def test_scale_down_when_queue_empties(self):
        self.scaler.backend._count = 4
        self._tick(0)  # desired=1, threshold=(4-1)*3=9, pending<9 → scale down
        self.assertEqual(self.scaler.backend.current_count(), 1)

    def test_hysteresis_prevents_premature_scale_down(self):
        self.scaler.backend._count = 3
        # threshold = (3-1)*3 = 6; pending=6 → no scale-down
        self._tick(6)
        self.assertEqual(self.scaler.backend.current_count(), 3)

    def test_hysteresis_allows_scale_down_below_threshold(self):
        self.scaler.backend._count = 3
        # threshold = (3-1)*3 = 6; pending=5 < 6 → scale down
        self._tick(5)
        self.assertEqual(self.scaler.backend.current_count(), 2)

    def test_scale_up_cooldown_suppresses(self):
        self.scaler.policy.scale_up_cooldown = 9999
        self.scaler._last_scale_up = time.time()
        self._tick(20)  # desired=7 but cooldown active
        self.assertEqual(self.scaler.backend.current_count(), 1)  # unchanged

    def test_scale_down_cooldown_suppresses(self):
        self.scaler.policy.scale_down_cooldown = 9999
        self.scaler._last_scale_down = time.time()
        self.scaler.backend._count = 5
        self._tick(0)
        self.assertEqual(self.scaler.backend.current_count(), 5)  # unchanged

    def test_paused_prevents_scaling(self):
        self.scaler.pause()
        self._tick(20)
        self.assertEqual(self.scaler.backend.current_count(), 1)

    def test_resume_re_enables_scaling(self):
        self.scaler.pause()
        self.scaler.resume()
        self._tick(20)
        self.assertEqual(self.scaler.backend.current_count(), 7)  # ceil(20/3)=7

    def test_unreachable_queue_skips_tick(self):
        initial = self.scaler.backend.current_count()
        with patch("scaler.fetch_pending", return_value=-1):
            self.scaler.tick()
        self.assertEqual(self.scaler.backend.current_count(), initial)

    def test_history_records_scale_up(self):
        self._tick(10)
        events = [e["event"] for e in self.scaler.history()]
        self.assertIn("scale_up", events)

    def test_history_records_scale_down(self):
        self.scaler.backend._count = 5
        self._tick(0)
        events = [e["event"] for e in self.scaler.history()]
        self.assertIn("scale_down", events)

    def test_max_agents_clamp(self):
        self._tick(999)  # desired would be 333 without clamp
        self.assertEqual(self.scaler.backend.current_count(), 8)

    def test_min_agents_clamp(self):
        self.scaler.policy.min_agents = 3
        self._tick(0)  # desired=3 (min)
        self.assertEqual(self.scaler.backend.current_count(), 3)


# ---------------------------------------------------------------------------
# Manual scale
# ---------------------------------------------------------------------------


class TestManualScale(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".json")
        self.scaler = make_scaler(self.tmp)
        self.scaler.policy.min_agents = 1
        self.scaler.policy.max_agents = 8

    def test_manual_scale_sets_count(self):
        self.assertTrue(self.scaler.manual_scale(5))
        self.assertEqual(self.scaler.backend.current_count(), 5)

    def test_manual_scale_clamps_to_max(self):
        self.scaler.manual_scale(100)
        self.assertEqual(self.scaler.backend.current_count(), 8)

    def test_manual_scale_clamps_to_min(self):
        self.scaler.manual_scale(0)
        self.assertEqual(self.scaler.backend.current_count(), 1)

    def test_manual_scale_recorded_in_history(self):
        self.scaler.manual_scale(3)
        events = [e["event"] for e in self.scaler.history()]
        self.assertIn("manual_scale", events)


# ---------------------------------------------------------------------------
# Policy update
# ---------------------------------------------------------------------------


class TestPolicyUpdate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".json")
        self.scaler = make_scaler(self.tmp)

    def test_update_min_max(self):
        self.scaler.update_policy({"min": 2, "max": 12})
        snap = self.scaler.snapshot()
        self.assertEqual(snap["policy"]["min_agents"], 2)
        self.assertEqual(snap["policy"]["max_agents"], 12)

    def test_update_tasks_per_agent(self):
        self.scaler.update_policy({"tasks_per_agent": 5})
        self.assertEqual(self.scaler.policy.tasks_per_agent, 5)


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------


class TestPersistence(unittest.TestCase):
    def test_state_saved_and_loaded(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = os.path.join(tmpdir, "scaler_state.json")
            os.environ["SCALER_STATE_FILE"] = state_path

            s = make_scaler(state_path)
            s.policy.min_agents = 3
            s.policy.max_agents = 12
            s.pause()

            # Load a new instance from same file
            s2 = make_scaler(state_path)
            self.assertEqual(s2.policy.min_agents, 3)
            self.assertEqual(s2.policy.max_agents, 12)
            self.assertTrue(s2.paused)

    def test_history_persists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = os.path.join(tmpdir, "scaler_state.json")
            s = make_scaler(state_path)
            s.policy.scale_up_cooldown = 0
            s.policy.scale_down_cooldown = 0
            with patch("scaler.fetch_pending", return_value=10):
                s.tick()
            s2 = make_scaler(state_path)
            self.assertTrue(len(s2.history()) > 0)


# ---------------------------------------------------------------------------
# HTTP API
# ---------------------------------------------------------------------------


class TestHTTPAPI(unittest.TestCase):
    """Spin up a real HTTPServer on a random port and test end-to-end."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mktemp(suffix=".json")
        cls.scaler = make_scaler(cls.tmp)
        cls.scaler.policy.scale_up_cooldown = 0
        cls.scaler.policy.scale_down_cooldown = 0

        handler = sc._make_handler(cls.scaler)
        cls.server = sc.HTTPServer(("127.0.0.1", 0), handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def _get(self, path: str) -> dict:
        import urllib.request
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}") as r:
            return json.loads(r.read())

    def _post(self, path: str, body: dict = None) -> dict:
        import urllib.request
        data = json.dumps(body or {}).encode()
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())

    def test_get_status(self):
        data = self._get("/status")
        self.assertIn("current", data)
        self.assertIn("desired", data)
        self.assertIn("pending", data)
        self.assertIn("policy", data)

    def test_get_history(self):
        data = self._get("/history")
        self.assertIn("events", data)

    def test_post_policy(self):
        resp = self._post("/policy", {"min": 2, "max": 10, "tasks_per_agent": 4})
        self.assertTrue(resp["ok"])
        snap = self._get("/status")
        self.assertEqual(snap["policy"]["min_agents"], 2)
        self.assertEqual(snap["policy"]["tasks_per_agent"], 4)

    def test_post_scale(self):
        # Reset policy for predictable count
        self._post("/policy", {"min": 1, "max": 8})
        resp = self._post("/scale", {"count": 3})
        self.assertTrue(resp["ok"])
        snap = self._get("/status")
        self.assertEqual(snap["current"], 3)

    def test_post_scale_bad_body(self):
        import urllib.error
        req = sc.urllib.request.Request(
            f"http://127.0.0.1:{self.port}/scale",
            data=b'{"count": "bad"}',
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as cm:
            sc.urllib.request.urlopen(req)
        self.assertEqual(cm.exception.code, 400)

    def test_post_pause_and_resume(self):
        self._post("/pause")
        self.assertTrue(self._get("/status")["paused"])
        self._post("/resume")
        self.assertFalse(self._get("/status")["paused"])

    def test_get_unknown_path_404(self):
        import urllib.error
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._get("/does-not-exist")
        self.assertEqual(cm.exception.code, 404)

    def test_post_unknown_path_404(self):
        import urllib.error
        req = sc.urllib.request.Request(
            f"http://127.0.0.1:{self.port}/does-not-exist",
            data=b"{}",
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as cm:
            sc.urllib.request.urlopen(req)
        self.assertEqual(cm.exception.code, 404)


# ---------------------------------------------------------------------------
# Concurrency: no double scale-up under concurrent ticks
# ---------------------------------------------------------------------------


class TestConcurrentTicks(unittest.TestCase):
    def test_concurrent_ticks_do_not_exceed_max(self):
        tmp = tempfile.mktemp(suffix=".json")
        s = make_scaler(tmp)
        s.policy.min_agents = 1
        s.policy.max_agents = 5
        s.policy.tasks_per_agent = 1
        s.policy.scale_up_cooldown = 0
        s.policy.scale_down_cooldown = 0
        s.backend._count = 1

        def tick_thread():
            s.tick()

        with patch("scaler.fetch_pending", return_value=5):
            threads = [threading.Thread(target=tick_thread) for _ in range(20)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()

        final = s.backend.current_count()
        self.assertLessEqual(final, 5)
        self.assertGreaterEqual(final, 1)


# ---------------------------------------------------------------------------
# Poll loop integration
# ---------------------------------------------------------------------------


class TestPollLoop(unittest.TestCase):
    def test_poll_loop_calls_tick(self):
        tmp = tempfile.mktemp(suffix=".json")
        s = make_scaler(tmp)
        s.policy.scale_up_cooldown = 0

        tick_count = [0]
        orig_tick = s.tick

        def counting_tick():
            tick_count[0] += 1
            orig_tick()

        s.tick = counting_tick
        stop = threading.Event()

        with patch("scaler.POLL_INTERVAL", 0):
            t = threading.Thread(target=sc.poll_loop, args=(s, stop), daemon=True)
            t.start()
            time.sleep(0.1)
            stop.set()
            t.join(timeout=2)

        self.assertGreater(tick_count[0], 0)


# ---------------------------------------------------------------------------
# make_backend factory
# ---------------------------------------------------------------------------


class TestMakeBackend(unittest.TestCase):
    def test_none_backend(self):
        b = sc.make_backend("none")
        self.assertIsInstance(b, sc.NoneBackend)

    def test_compose_backend(self):
        b = sc.make_backend("compose")
        self.assertIsInstance(b, sc.ComposeBackend)

    def test_docker_api_backend(self):
        b = sc.make_backend("docker_api")
        self.assertIsInstance(b, sc.DockerAPIBackend)

    def test_default_is_compose(self):
        b = sc.make_backend("unknown")
        self.assertIsInstance(b, sc.ComposeBackend)


if __name__ == "__main__":
    unittest.main()
