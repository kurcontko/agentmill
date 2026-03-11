"""Tests for queue_server.py — work-stealing queue prototype."""

import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import HTTPServer
from pathlib import Path

# Make sure we can import from repo root
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from queue_server import QueueHandler, QueueState


def _start_server(state_file: str) -> tuple[HTTPServer, int]:
    """Start a QueueHandler server on a free port. Returns (server, port)."""
    state = QueueState(state_file)
    state.load()
    QueueHandler.queue = state
    server = HTTPServer(("127.0.0.1", 0), QueueHandler)
    port = server.server_address[1]
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server, port


def _post(port: int, path: str, body: dict) -> tuple[int, dict]:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def _get(port: int, path: str) -> tuple[int, dict | None]:
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}{path}", timeout=5
        ) as resp:
            if resp.status == 204:
                return 204, None
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


class TestQueueState(unittest.TestCase):
    """Unit tests for QueueState (no HTTP)."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.tmp.close()
        self.state_file = self.tmp.name

    def tearDown(self):
        Path(self.state_file).unlink(missing_ok=True)

    def _state(self):
        return QueueState(self.state_file)

    def test_enqueue_dequeue(self):
        s = self._state()
        self.assertTrue(s.enqueue("t1", {"work": "a"}))
        task = s.dequeue()
        self.assertIsNotNone(task)
        self.assertEqual(task["id"], "t1")
        self.assertEqual(task["payload"], {"work": "a"})
        self.assertIn("dequeued_at", task)

    def test_dequeue_empty(self):
        s = self._state()
        self.assertIsNone(s.dequeue())

    def test_duplicate_id_rejected(self):
        s = self._state()
        self.assertTrue(s.enqueue("t1", {}))
        self.assertFalse(s.enqueue("t1", {}))  # duplicate

    def test_complete_moves_to_done(self):
        s = self._state()
        s.enqueue("t1", {})
        s.dequeue()
        self.assertTrue(s.complete("t1"))
        st = s.status()
        self.assertEqual(st["in_flight"], 0)
        self.assertEqual(st["done"], 1)

    def test_fail_requeues(self):
        s = self._state()
        s.enqueue("t1", {})
        s.dequeue()
        self.assertTrue(s.fail("t1", "oops"))
        st = s.status()
        self.assertEqual(st["in_flight"], 0)
        self.assertEqual(st["pending"], 1)  # back in queue

    def test_fail_exceeds_retry_limit(self):
        s = self._state()
        s.enqueue("t1", {})
        for _ in range(4):
            s.dequeue()
            s.fail("t1", "err")
        st = s.status()
        self.assertEqual(st["pending"], 0)
        self.assertEqual(st["failed"], 1)

    def test_delete(self):
        s = self._state()
        s.enqueue("t1", {})
        self.assertTrue(s.delete("t1"))
        st = s.status()
        self.assertEqual(st["pending"], 0)

    def test_persistence(self):
        s = self._state()
        s.enqueue("t1", {"v": 1})
        s.enqueue("t2", {"v": 2})
        s.dequeue()  # t1 goes in-flight

        # Reload — in-flight tasks should be recovered to pending
        s2 = QueueState(self.state_file)
        s2.load()
        st = s2.status()
        self.assertEqual(st["pending"], 2)  # t1 recovered + t2
        self.assertEqual(st["in_flight"], 0)

    def test_fifo_ordering(self):
        s = self._state()
        for i in range(5):
            s.enqueue(f"t{i}", {"i": i})
        for i in range(5):
            t = s.dequeue()
            self.assertEqual(t["id"], f"t{i}")

    def test_status_counts(self):
        s = self._state()
        s.enqueue("a", {})
        s.enqueue("b", {})
        s.dequeue()  # a in-flight
        st = s.status()
        self.assertEqual(st["pending"], 1)
        self.assertEqual(st["in_flight"], 1)
        self.assertEqual(st["done"], 0)


class TestQueueHTTP(unittest.TestCase):
    """Integration tests via HTTP."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        cls.tmp.close()
        cls.server, cls.port = _start_server(cls.tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        Path(cls.tmp.name).unlink(missing_ok=True)

    def _enqueue(self, task_id: str, payload=None):
        return _post(self.port, "/enqueue", {"id": task_id, "payload": payload or {}})

    def _dequeue(self):
        return _get(self.port, "/dequeue")

    def _complete(self, task_id: str):
        return _post(self.port, "/complete", {"id": task_id})

    def _fail(self, task_id: str, reason=""):
        return _post(self.port, "/fail", {"id": task_id, "reason": reason})

    def _status(self):
        return _get(self.port, "/status")

    def setUp(self):
        # Clear queue between tests by deleting all pending/done tasks
        _, snap = _get(self.port, "/tasks")
        if snap:
            for t in snap.get("pending", []):
                _post(self.port, "/complete", {"id": t["id"]})
            # Drain in-flight
            for t in snap.get("in_flight", {}).values():
                _post(self.port, "/complete", {"id": t["id"]})

    def test_enqueue_returns_201(self):
        code, body = self._enqueue("http-t1")
        self.assertEqual(code, 201)
        self.assertTrue(body["ok"])

    def test_duplicate_returns_409(self):
        self._enqueue("http-dup")
        code, _ = self._enqueue("http-dup")
        self.assertEqual(code, 409)

    def test_dequeue_returns_task(self):
        self._enqueue("http-deq", {"x": 1})
        code, body = self._dequeue()
        self.assertEqual(code, 200)
        self.assertIsNotNone(body)
        self.assertIn("task", body)

    def test_dequeue_empty_returns_204(self):
        # Drain any remaining
        while True:
            code, _ = self._dequeue()
            if code == 204:
                break
        code, body = self._dequeue()
        self.assertEqual(code, 204)
        self.assertIsNone(body)

    def test_complete_workflow(self):
        self._enqueue("http-workflow")
        _, body = self._dequeue()
        task_id = body["task"]["id"]
        code, resp = self._complete(task_id)
        self.assertEqual(code, 200)
        self.assertTrue(resp["ok"])
        _, st = self._status()
        self.assertEqual(st["done"], 1)

    def test_fail_requeues(self):
        self._enqueue("http-fail")
        _, body = self._dequeue()
        task_id = body["task"]["id"]
        code, _ = self._fail(task_id, "test failure")
        self.assertEqual(code, 200)
        _, st = self._status()
        self.assertGreaterEqual(st["pending"], 1)

    def test_status_endpoint(self):
        code, body = self._status()
        self.assertEqual(code, 200)
        for key in ("pending", "in_flight", "done", "failed"):
            self.assertIn(key, body)

    def test_tasks_endpoint(self):
        code, body = _get(self.port, "/tasks")
        self.assertEqual(code, 200)
        for key in ("pending", "in_flight", "done", "failed"):
            self.assertIn(key, body)

    def test_missing_id_returns_400(self):
        code, body = _post(self.port, "/enqueue", {"payload": {}})
        self.assertEqual(code, 400)

    def test_invalid_json_returns_400(self):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/enqueue",
            data=b"not json",
            headers={"Content-Type": "application/json", "Content-Length": "8"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                code = resp.status
        except urllib.error.HTTPError as e:
            code = e.code
        self.assertEqual(code, 400)

    def test_unknown_route_returns_404(self):
        code, _ = _get(self.port, "/nonexistent")
        self.assertEqual(code, 404)


class TestConcurrentDequeue(unittest.TestCase):
    """Verify that concurrent dequeues are atomic (no double-dequeue)."""

    def test_no_double_dequeue(self):
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
            state_file = f.name

        try:
            server, port = _start_server(state_file)

            # Enqueue N tasks
            N = 20
            for i in range(N):
                _post(port, "/enqueue", {"id": f"concurrent-{i}", "payload": {"i": i}})

            # Spawn N threads all trying to dequeue simultaneously
            results = []
            lock = threading.Lock()

            def worker():
                code, body = _get(port, "/dequeue")
                with lock:
                    results.append((code, body))

            threads = [threading.Thread(target=worker) for _ in range(N)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(timeout=10)

            # Every dequeue should get a unique task (no duplicates)
            tasks_received = [
                r[1]["task"]["id"] for r in results if r[0] == 200 and r[1]
            ]
            self.assertEqual(len(tasks_received), N)
            self.assertEqual(len(set(tasks_received)), N, "Duplicate dequeue detected!")

            server.shutdown()
        finally:
            Path(state_file).unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
