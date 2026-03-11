"""Tests for lock_manager.py"""

import json
import os
import sys
import tempfile
import threading
import time
import unittest
from http.server import HTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from lock_manager import LockStore, make_server


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _post(url: str, body: dict) -> tuple[int, dict]:
    data = json.dumps(body).encode()
    req = Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read())
    except HTTPError as e:
        return e.code, json.loads(e.read())


def _get(url: str) -> tuple[int, dict]:
    try:
        with urlopen(url, timeout=5) as r:
            return r.status, json.loads(r.read())
    except HTTPError as e:
        return e.code, json.loads(e.read())


# ---------------------------------------------------------------------------
# Unit tests — LockStore directly
# ---------------------------------------------------------------------------

class TestLockStoreBasic(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.tmp.close()
        self.store = LockStore(self.tmp.name)

    def tearDown(self):
        os.unlink(self.tmp.name)

    def test_acquire_success(self):
        r = self.store.acquire("agent-1", "src/foo.py", 300)
        self.assertTrue(r["ok"])
        self.assertIn("lock_id", r)
        self.assertGreater(r["expires"], time.time())

    def test_acquire_conflict(self):
        self.store.acquire("agent-1", "src/foo.py", 300)
        r = self.store.acquire("agent-2", "src/foo.py", 300)
        self.assertFalse(r["ok"])
        self.assertEqual(r["held_by"], "agent-1")

    def test_same_agent_re_acquire_conflict(self):
        # Even the same agent blocks itself — avoid duplicate locks
        self.store.acquire("agent-1", "src/foo.py", 300)
        r = self.store.acquire("agent-1", "src/foo.py", 300)
        self.assertFalse(r["ok"])

    def test_acquire_after_expiry(self):
        r0 = self.store.acquire("agent-1", "src/foo.py", 300)
        # Force expiry by backdating the lock
        self.store._locks[r0["lock_id"]]["expires"] = time.time() - 1
        r = self.store.acquire("agent-2", "src/foo.py", 300)
        self.assertTrue(r["ok"])

    def test_release_success(self):
        r1 = self.store.acquire("agent-1", "src/foo.py", 300)
        r2 = self.store.release("agent-1", r1["lock_id"])
        self.assertTrue(r2["ok"])
        # Now another agent can acquire
        r3 = self.store.acquire("agent-2", "src/foo.py", 300)
        self.assertTrue(r3["ok"])

    def test_release_wrong_agent(self):
        r1 = self.store.acquire("agent-1", "src/foo.py", 300)
        r2 = self.store.release("agent-2", r1["lock_id"])
        self.assertFalse(r2["ok"])
        self.assertIn("not your lock", r2["error"])

    def test_release_unknown_lock(self):
        r = self.store.release("agent-1", "nonexistent-id")
        self.assertFalse(r["ok"])
        self.assertIn("not found", r["error"])

    def test_release_all(self):
        self.store.acquire("agent-1", "src/a.py", 300)
        self.store.acquire("agent-1", "src/b.py", 300)
        self.store.acquire("agent-2", "src/c.py", 300)
        n = self.store.release_all("agent-1")
        self.assertEqual(n, 2)
        # agent-2 lock still active
        self.assertIsNotNone(self.store.get_lock_for_file("src/c.py"))

    def test_heartbeat_renews_ttl(self):
        r1 = self.store.acquire("agent-1", "src/foo.py", 10)
        old_expires = r1["expires"]
        time.sleep(0.1)
        r2 = self.store.heartbeat("agent-1", r1["lock_id"], 300)
        self.assertTrue(r2["ok"])
        self.assertGreater(r2["expires"], old_expires)

    def test_heartbeat_wrong_agent(self):
        r1 = self.store.acquire("agent-1", "src/foo.py", 300)
        r2 = self.store.heartbeat("agent-2", r1["lock_id"])
        self.assertFalse(r2["ok"])

    def test_heartbeat_unknown_lock(self):
        r = self.store.heartbeat("agent-1", "bad-id")
        self.assertFalse(r["ok"])

    def test_get_lock_for_file(self):
        self.store.acquire("agent-1", "src/foo.py", 300)
        lock = self.store.get_lock_for_file("src/foo.py")
        self.assertIsNotNone(lock)
        self.assertEqual(lock["agent"], "agent-1")
        self.assertEqual(lock["file"], "src/foo.py")

    def test_get_lock_for_unlocked_file(self):
        self.assertIsNone(self.store.get_lock_for_file("src/not_locked.py"))

    def test_get_locks_for_agent(self):
        self.store.acquire("agent-1", "src/a.py", 300)
        self.store.acquire("agent-1", "src/b.py", 300)
        self.store.acquire("agent-2", "src/c.py", 300)
        locks = self.store.get_locks_for_agent("agent-1")
        self.assertEqual(len(locks), 2)

    def test_list_locks(self):
        self.store.acquire("agent-1", "src/a.py", 300)
        self.store.acquire("agent-2", "src/b.py", 300)
        all_locks = self.store.list_locks()
        self.assertEqual(len(all_locks), 2)

    def test_reap_expired(self):
        r0 = self.store.acquire("agent-1", "src/foo.py", 300)
        self.store._locks[r0["lock_id"]]["expires"] = time.time() - 1  # force expiry
        self.store.acquire("agent-2", "src/bar.py", 300)
        n = self.store.reap_expired()
        self.assertEqual(n, 1)
        self.assertEqual(len(self.store.list_locks()), 1)

    def test_status(self):
        self.store.acquire("agent-1", "src/a.py", 300)
        self.store.acquire("agent-1", "src/b.py", 300)
        self.store.acquire("agent-2", "src/c.py", 300)
        s = self.store.status()
        self.assertEqual(s["total_locks"], 3)
        self.assertEqual(s["files_locked"], 3)
        self.assertIn("agent-1", s["agents"])
        self.assertIn("agent-2", s["agents"])


class TestLockStoreBatch(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.tmp.close()
        self.store = LockStore(self.tmp.name)

    def tearDown(self):
        os.unlink(self.tmp.name)

    def test_batch_all_free(self):
        r = self.store.acquire_batch("agent-1", ["a.py", "b.py", "c.py"], 300)
        self.assertTrue(r["ok"])
        self.assertEqual(len(r["lock_ids"]), 3)
        self.assertEqual(len(r["conflicts"]), 0)

    def test_batch_partial_conflict(self):
        self.store.acquire("agent-2", "b.py", 300)
        r = self.store.acquire_batch("agent-1", ["a.py", "b.py", "c.py"], 300)
        self.assertFalse(r["ok"])
        self.assertIn("b.py", [c["file"] for c in r["conflicts"]])
        self.assertIn("a.py", r["lock_ids"])
        self.assertIn("c.py", r["lock_ids"])

    def test_batch_dedup_files(self):
        r = self.store.acquire_batch("agent-1", ["a.py", "a.py", "b.py"], 300)
        self.assertTrue(r["ok"])
        self.assertEqual(len(r["lock_ids"]), 2)

    def test_batch_sorted_order(self):
        # Acquire in reverse order should still succeed (deadlock prevention)
        r = self.store.acquire_batch("agent-1", ["z.py", "a.py", "m.py"], 300)
        self.assertTrue(r["ok"])
        self.assertEqual(set(r["lock_ids"].keys()), {"a.py", "m.py", "z.py"})


class TestLockStorePersistence(unittest.TestCase):

    def test_survives_restart(self):
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
            fname = f.name
        try:
            store1 = LockStore(fname)
            r = store1.acquire("agent-1", "src/foo.py", 300)
            lock_id = r["lock_id"]

            # "restart" — create new store from same state file
            store2 = LockStore(fname)
            lock = store2.get_lock_for_file("src/foo.py")
            self.assertIsNotNone(lock)
            self.assertEqual(lock["lock_id"], lock_id)
        finally:
            os.unlink(fname)

    def test_expired_locks_not_loaded(self):
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
            fname = f.name
        try:
            store1 = LockStore(fname)
            r = store1.acquire("agent-1", "src/foo.py", 300)
            # Backdate expiry so the lock is already expired
            store1._locks[r["lock_id"]]["expires"] = time.time() - 10
            store1._persist()

            store2 = LockStore(fname)
            self.assertEqual(len(store2.list_locks()), 0)
        finally:
            os.unlink(fname)


class TestLockStoreConcurrency(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.tmp.close()
        self.store = LockStore(self.tmp.name)

    def tearDown(self):
        os.unlink(self.tmp.name)

    def test_concurrent_acquire_only_one_wins(self):
        """20 agents race to lock the same file — exactly one must win."""
        results = []
        lock = threading.Lock()

        def try_acquire(agent_id: int):
            r = self.store.acquire(f"agent-{agent_id}", "shared.py", 300)
            with lock:
                results.append(r)

        threads = [threading.Thread(target=try_acquire, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        winners = [r for r in results if r["ok"]]
        self.assertEqual(len(winners), 1, f"expected 1 winner, got {len(winners)}")

    def test_concurrent_acquire_different_files(self):
        """20 agents each acquire a unique file — all must win."""
        results = []
        lock = threading.Lock()

        def try_acquire(agent_id: int):
            r = self.store.acquire(f"agent-{agent_id}", f"file-{agent_id}.py", 300)
            with lock:
                results.append(r)

        threads = [threading.Thread(target=try_acquire, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        winners = [r for r in results if r["ok"]]
        self.assertEqual(len(winners), 20)

    def test_concurrent_release(self):
        """Only one release attempt must succeed for a given lock."""
        r = self.store.acquire("agent-1", "shared.py", 300)
        lock_id = r["lock_id"]

        results = []
        mu = threading.Lock()

        def try_release():
            res = self.store.release("agent-1", lock_id)
            with mu:
                results.append(res)

        threads = [threading.Thread(target=try_release) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        successes = [r for r in results if r["ok"]]
        self.assertEqual(len(successes), 1, "exactly one release must succeed")


# ---------------------------------------------------------------------------
# Integration tests — HTTP API
# ---------------------------------------------------------------------------

class TestLockManagerHTTP(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        cls.tmp.close()
        cls.server = make_server("127.0.0.1", 0, cls.tmp.name)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        os.unlink(cls.tmp.name)

    def _acquire(self, agent, file, ttl=300):
        return _post(f"{self.base}/acquire", {"agent": agent, "file": file, "ttl": ttl})

    def _release(self, agent, lock_id):
        return _post(f"{self.base}/release", {"agent": agent, "lock_id": lock_id})

    def test_acquire_200(self):
        status, body = self._acquire("agent-1", "http/a.py")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])

    def test_acquire_conflict_409(self):
        self._acquire("agent-1", "http/conflict.py")
        status, body = self._acquire("agent-2", "http/conflict.py")
        self.assertEqual(status, 409)
        self.assertFalse(body["ok"])
        self.assertEqual(body["held_by"], "agent-1")

    def test_release_200(self):
        _, r = self._acquire("agent-1", "http/rel.py")
        status, body = self._release("agent-1", r["lock_id"])
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])

    def test_release_wrong_agent_403(self):
        _, r = self._acquire("agent-1", "http/rel2.py")
        status, body = self._release("agent-2", r["lock_id"])
        self.assertEqual(status, 403)

    def test_release_not_found_404(self):
        status, body = self._release("agent-1", "no-such-id")
        self.assertEqual(status, 404)

    def test_release_all(self):
        self._acquire("agent-ra", "http/ra1.py")
        self._acquire("agent-ra", "http/ra2.py")
        status, body = _post(f"{self.base}/release_all", {"agent": "agent-ra"})
        self.assertEqual(status, 200)
        self.assertEqual(body["released"], 2)

    def test_heartbeat(self):
        _, r = self._acquire("agent-1", "http/hb.py", ttl=10)
        old_expires = r["expires"]
        status, body = _post(f"{self.base}/heartbeat",
                             {"agent": "agent-1", "lock_id": r["lock_id"], "ttl": 300})
        self.assertEqual(status, 200)
        self.assertGreater(body["expires"], old_expires)

    def test_heartbeat_not_found_404(self):
        status, _ = _post(f"{self.base}/heartbeat", {"agent": "a", "lock_id": "bad"})
        self.assertEqual(status, 404)

    def test_acquire_batch(self):
        status, body = _post(f"{self.base}/acquire_batch",
                             {"agent": "agent-b", "files": ["http/ba.py", "http/bb.py"], "ttl": 300})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertIn("http/ba.py", body["lock_ids"])

    def test_get_locks(self):
        self._acquire("agent-list", "http/list1.py")
        status, body = _get(f"{self.base}/locks")
        self.assertEqual(status, 200)
        files = [lk["file"] for lk in body["locks"]]
        self.assertIn("http/list1.py", files)

    def test_get_lock_for_file(self):
        self._acquire("agent-gf", "http/gf.py")
        from urllib.parse import quote
        status, body = _get(f"{self.base}/locks/{quote('http/gf.py', safe='')}")
        self.assertEqual(status, 200)
        self.assertEqual(body["lock"]["agent"], "agent-gf")

    def test_get_lock_for_unlocked_file_404(self):
        from urllib.parse import quote
        status, body = _get(f"{self.base}/locks/{quote('not/locked.py', safe='')}")
        self.assertEqual(status, 404)
        self.assertIsNone(body["lock"])

    def test_get_agent_locks(self):
        self._acquire("agent-al", "http/al1.py")
        self._acquire("agent-al", "http/al2.py")
        status, body = _get(f"{self.base}/agent/agent-al")
        self.assertEqual(status, 200)
        self.assertEqual(len(body["locks"]), 2)

    def test_status(self):
        status, body = _get(f"{self.base}/status")
        self.assertEqual(status, 200)
        self.assertIn("total_locks", body)
        self.assertIn("files_locked", body)
        self.assertIn("agents", body)

    def test_invalid_json_400(self):
        req = Request(f"{self.base}/acquire",
                      data=b"not json",
                      headers={"Content-Type": "application/json"},
                      method="POST")
        try:
            with urlopen(req, timeout=5):
                pass
        except HTTPError as e:
            self.assertEqual(e.code, 400)

    def test_missing_fields_400(self):
        status, _ = _post(f"{self.base}/acquire", {"agent": "a"})
        self.assertEqual(status, 400)

    def test_unknown_path_404(self):
        status, _ = _get(f"{self.base}/unknown")
        self.assertEqual(status, 404)

    def test_ttl_capped_at_max(self):
        # TTL of 1 year should be capped
        status, body = self._acquire("agent-cap", "http/cap.py", ttl=99999999)
        self.assertEqual(status, 200)
        # expires should be at most MAX_TTL seconds from now
        from lock_manager import MAX_TTL
        self.assertLessEqual(body["expires"], time.time() + MAX_TTL + 5)


if __name__ == "__main__":
    unittest.main()
