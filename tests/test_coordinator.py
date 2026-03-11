"""
Tests for coordinator.py — AgentMill Hierarchical Coordinator.

Run: python3 -m unittest tests.test_coordinator
"""

import json
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

# Ensure repo root is on path
sys.path.insert(0, str(Path(__file__).parent.parent))

import coordinator
from coordinator import CoordinatorState, parse_task_md

SAMPLE_TASK_MD = """\
# TASK

## P0 — Core

### [R1] Work-Stealing Queue
- **Branch**: `research/work-stealing-queue`
- **Status**: `[x]`
- **Goal**: Already done.

### [R2] Hierarchical Coordination
- **Branch**: `research/hierarchical-coordination`
- **Status**: `[ ]`
- **Goal**: Coordinator agent.

### [R3] Consensus Merge
- **Branch**: `research/consensus-merge`
- **Status**: `[~]`
- **Goal**: Merge gate.

## P1 — Communication

### [R4] Message Bus
- **Branch**: `research/message-bus`
- **Status**: `[ ]`
- **Goal**: Agent messaging.
"""


def make_state() -> CoordinatorState:
    """Return a fresh in-memory (tmpfile) CoordinatorState."""
    tf = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
    tf.close()
    os.unlink(tf.name)  # Remove so state starts empty
    return CoordinatorState(tf.name)


class TestCoordinatorState(unittest.TestCase):

    def test_submit_and_assign(self):
        s = make_state()
        s.submit({"id": "T1", "title": "Task One"})
        task = s.assign("worker-1")
        self.assertIsNotNone(task)
        self.assertEqual(task["id"], "T1")
        self.assertEqual(task["status"], "assigned")

    def test_empty_assign_returns_none(self):
        s = make_state()
        self.assertIsNone(s.assign("worker-1"))

    def test_duplicate_submit_rejected(self):
        s = make_state()
        self.assertTrue(s.submit({"id": "T1", "title": "Task One"}))
        self.assertFalse(s.submit({"id": "T1", "title": "Task One duplicate"}))

    def test_complete_moves_to_done(self):
        s = make_state()
        s.submit({"id": "T1", "title": "Task One"})
        s.assign("worker-1")
        ok = s.complete("worker-1", "T1", branch="research/t1")
        self.assertTrue(ok)
        snap = s.tasks_snapshot()
        self.assertEqual(len(snap["done"]), 1)
        self.assertEqual(snap["done"][0]["branch"], "research/t1")
        self.assertEqual(len(snap["assigned"]), 0)

    def test_fail_requeues_up_to_3_times(self):
        s = make_state()
        s.submit({"id": "T1", "title": "Task One"})

        for attempt in range(1, 3):
            s.assign("worker-1")
            ok = s.fail("worker-1", "T1", reason=f"error {attempt}")
            self.assertTrue(ok)
            snap = s.tasks_snapshot()
            self.assertEqual(len(snap["pending"]), 1, f"should re-queue on attempt {attempt}")

        # 3rd failure → permanent fail
        s.assign("worker-1")
        s.fail("worker-1", "T1", reason="fatal")
        snap = s.tasks_snapshot()
        self.assertEqual(len(snap["pending"]), 0)
        self.assertEqual(len(snap["failed"]), 1)

    def test_checkin_updates_heartbeat(self):
        s = make_state()
        s.submit({"id": "T1", "title": "Task One"})
        s.assign("worker-1")
        before = time.time()
        ok = s.checkin("worker-1", "T1", status="coding")
        self.assertTrue(ok)
        task = s.assigned["T1"]
        self.assertGreaterEqual(task["last_checkin"], before)

    def test_checkin_wrong_worker_rejected(self):
        s = make_state()
        s.submit({"id": "T1", "title": "Task One"})
        s.assign("worker-1")
        ok = s.checkin("worker-2", "T1")
        self.assertFalse(ok)

    def test_delete_pending(self):
        s = make_state()
        s.submit({"id": "T1", "title": "Task One"})
        ok = s.delete("T1")
        self.assertTrue(ok)
        self.assertEqual(len(s.pending), 0)

    def test_delete_assigned(self):
        s = make_state()
        s.submit({"id": "T1", "title": "Task One"})
        s.assign("worker-1")
        ok = s.delete("T1")
        self.assertTrue(ok)
        self.assertNotIn("T1", s.assigned)

    def test_delete_nonexistent_returns_false(self):
        s = make_state()
        self.assertFalse(s.delete("NOPE"))

    def test_priority_ordering(self):
        """Higher priority tasks should be assigned before lower priority ones."""
        s = make_state()
        s.submit({"id": "LOW", "title": "Low priority", "priority": 5})
        s.submit({"id": "HIGH", "title": "High priority", "priority": 30})
        s.submit({"id": "MED", "title": "Med priority", "priority": 20})

        t1 = s.assign("w1")
        t2 = s.assign("w2")
        t3 = s.assign("w3")

        self.assertEqual(t1["id"], "HIGH")
        self.assertEqual(t2["id"], "MED")
        self.assertEqual(t3["id"], "LOW")

    def test_reap_stale_requeues(self):
        """Tasks with expired heartbeats should be re-queued."""
        s = make_state()
        with patch.object(coordinator, "HEARTBEAT_TTL", 1):
            s.submit({"id": "T1", "title": "Task One"})
            s.assign("worker-1")
            # Don't checkin — simulate dead worker
            time.sleep(1.1)
            n = s.reap_stale()
        self.assertEqual(n, 1)
        self.assertEqual(len(s.pending), 1)
        self.assertEqual(len(s.assigned), 0)

    def test_reap_active_not_reaped(self):
        """Tasks with fresh heartbeats must NOT be reaped."""
        s = make_state()
        s.submit({"id": "T1", "title": "Task One"})
        s.assign("worker-1")
        s.checkin("worker-1", "T1")
        n = s.reap_stale()
        self.assertEqual(n, 0)
        self.assertEqual(len(s.assigned), 1)

    def test_crash_recovery(self):
        """In-flight tasks should be re-queued on reload."""
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tf:
            state_path = tf.name

        try:
            s1 = CoordinatorState(state_path)
            s1.submit({"id": "T1", "title": "Task One"})
            s1.assign("worker-1")
            self.assertEqual(len(s1.assigned), 1)

            # Simulate crash — reload from same file
            s2 = CoordinatorState(state_path)
            self.assertEqual(len(s2.assigned), 0)
            self.assertEqual(len(s2.pending), 1)
            self.assertEqual(s2.pending[0]["id"], "T1")
        finally:
            Path(state_path).unlink(missing_ok=True)

    def test_status_snapshot(self):
        s = make_state()
        s.submit({"id": "T1", "title": "Task One"})
        s.submit({"id": "T2", "title": "Task Two"})
        s.assign("worker-1")
        snap = s.status_snapshot()
        self.assertEqual(snap["pending"], 1)
        self.assertEqual(snap["assigned"], 1)
        self.assertEqual(snap["done"], 0)
        self.assertEqual(snap["failed"], 0)

    def test_concurrent_assign_no_double_dequeue(self):
        """20 threads racing to assign should each get a unique task."""
        s = make_state()
        n_tasks = 10
        for i in range(n_tasks):
            s.submit({"id": f"T{i}", "title": f"Task {i}"})

        assigned_ids = []
        lock = threading.Lock()
        errors = []

        def worker(wid: str) -> None:
            try:
                task = s.assign(wid)
                if task:
                    with lock:
                        assigned_ids.append(task["id"])
            except Exception as exc:
                with lock:
                    errors.append(str(exc))

        threads = [threading.Thread(target=worker, args=(f"w{i}",)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(errors, [])
        # No duplicate assignments
        self.assertEqual(len(assigned_ids), len(set(assigned_ids)))
        # Can't assign more tasks than existed
        self.assertLessEqual(len(assigned_ids), n_tasks)


class TestTaskMdParser(unittest.TestCase):

    def test_parses_open_tasks(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as tf:
            tf.write(SAMPLE_TASK_MD)
            path = tf.name
        try:
            tasks = parse_task_md(path)
            ids = [t["id"] for t in tasks]
            # R1 is done [x] — should be excluded
            self.assertNotIn("R1", ids)
            # R2 ([ ]) and R3 ([~]) should be included
            self.assertIn("R2", ids)
            self.assertIn("R3", ids)
            self.assertIn("R4", ids)
        finally:
            Path(path).unlink(missing_ok=True)

    def test_priority_from_section(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as tf:
            tf.write(SAMPLE_TASK_MD)
            path = tf.name
        try:
            tasks = parse_task_md(path)
            by_id = {t["id"]: t for t in tasks}
            # P0 tasks should have higher priority than P1
            self.assertGreater(by_id["R2"]["priority"], by_id["R4"]["priority"])
        finally:
            Path(path).unlink(missing_ok=True)

    def test_branch_extracted(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as tf:
            tf.write(SAMPLE_TASK_MD)
            path = tf.name
        try:
            tasks = parse_task_md(path)
            by_id = {t["id"]: t for t in tasks}
            self.assertEqual(by_id["R2"]["branch"], "research/hierarchical-coordination")
        finally:
            Path(path).unlink(missing_ok=True)

    def test_missing_file_raises(self):
        with self.assertRaises(FileNotFoundError):
            parse_task_md("/nonexistent/path/TASK.md")


class TestHTTPAPI(unittest.TestCase):
    """Integration tests for the HTTP coordinator API."""

    @classmethod
    def setUpClass(cls):
        import http.server
        import socket
        import urllib.request

        cls.state = make_state()
        cls.state.submit({"id": "T1", "title": "HTTP Task One", "priority": 10})
        cls.state.submit({"id": "T2", "title": "HTTP Task Two", "priority": 5})

        coordinator.CoordinatorHandler.state = cls.state

        # Find a free port
        with socket.socket() as sock:
            sock.bind(("", 0))
            cls.port = sock.getsockname()[1]

        cls.server = coordinator.HTTPServer(("", cls.port), coordinator.CoordinatorHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://localhost:{cls.port}"
        cls.urlopen = urllib.request.urlopen

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def _get(self, path: str, body: dict | None = None) -> tuple[int, dict]:
        import urllib.request
        url = self.base + path
        data = json.dumps(body).encode() if body else None
        req = urllib.request.Request(url, data=data,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as resp:
                return resp.status, json.loads(resp.read())
        except Exception as exc:
            code = getattr(exc, "code", 500)
            body = {}
            try:
                body = json.loads(exc.read())
            except Exception:
                pass
            return code, body

    def _post(self, path: str, body: dict) -> tuple[int, dict]:
        import urllib.request
        url = self.base + path
        data = json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as resp:
                return resp.status, json.loads(resp.read())
        except Exception as exc:
            code = getattr(exc, "code", 500)
            body_data = {}
            try:
                body_data = json.loads(exc.read())
            except Exception:
                pass
            return code, body_data

    def test_health(self):
        code, body = self._get("/health")
        self.assertEqual(code, 200)
        self.assertTrue(body["ok"])

    def test_assign_via_http(self):
        code, body = self._post("/assign", {"worker_id": "http-worker-1"})
        self.assertEqual(code, 200)
        self.assertIn("task", body)
        self.assertIsNotNone(body["task"])

    def test_status_via_http(self):
        code, body = self._get("/status")
        self.assertEqual(code, 200)
        self.assertIn("pending", body)
        self.assertIn("assigned", body)

    def test_checkin_via_http(self):
        # Assign first
        _, abody = self._post("/assign", {"worker_id": "http-worker-checkin"})
        if abody.get("task"):
            task_id = abody["task"]["id"]
            code, body = self._post("/checkin", {
                "worker_id": "http-worker-checkin",
                "task_id": task_id,
                "status": "working",
            })
            self.assertEqual(code, 200)
            self.assertTrue(body["ok"])

    def test_submit_task_via_http(self):
        code, body = self._post("/submit_task", {
            "id": "HTTP-NEW",
            "title": "New task via HTTP",
            "priority": 1,
        })
        self.assertEqual(code, 201)
        self.assertTrue(body["ok"])

    def test_duplicate_submit_409(self):
        self._post("/submit_task", {"id": "DUP", "title": "Dup"})
        code, body = self._post("/submit_task", {"id": "DUP", "title": "Dup again"})
        self.assertEqual(code, 409)

    def test_submit_missing_fields_400(self):
        code, body = self._post("/submit_task", {"id": "NOID"})
        self.assertEqual(code, 400)

    def test_404_unknown_route(self):
        code, body = self._get("/nonexistent")
        self.assertEqual(code, 404)


if __name__ == "__main__":
    unittest.main()
