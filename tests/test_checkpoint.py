"""
Tests for checkpoint.py — Checkpoint & Rollback Protocol.
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import HTTPServer
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
import checkpoint


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_store(tmp: str) -> checkpoint.CheckpointStore:
    return checkpoint.CheckpointStore(os.path.join(tmp, "state.json"))


def start_server(store: checkpoint.CheckpointStore,
                 port: int) -> HTTPServer:
    checkpoint._store = store
    server = HTTPServer(("127.0.0.1", port), checkpoint.Handler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


def http(method: str, port: int, path: str,
         body: dict | None = None) -> tuple[int, dict]:
    import urllib.request
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data:
        req.add_header("Content-Type", "application/json")
        req.add_header("Content-Length", str(len(data)))
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


FAKE_SHA = "abc123def456abc123def456abc123def456abc123"
FAKE_SHA2 = "111222333444555666777888999aaabbbcccdddeee"

_PORT_BASE = 9900


# ---------------------------------------------------------------------------
# CheckpointStore unit tests
# ---------------------------------------------------------------------------

class TestCheckpointStore(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = make_store(self.tmp)

    # --- add / get / list ---------------------------------------------------

    def test_add_returns_record(self):
        rec = self.store.add("sess1", FAKE_SHA, 0.9, "initial")
        self.assertEqual(rec["session"], "sess1")
        self.assertEqual(rec["commit"], FAKE_SHA)
        self.assertAlmostEqual(rec["score"], 0.9)
        self.assertEqual(rec["label"], "initial")
        self.assertEqual(rec["seq"], 1)
        self.assertTrue(rec["id"].startswith("ckpt/sess1/"))

    def test_add_increments_seq(self):
        r1 = self.store.add("s", FAKE_SHA, 1.0, "a")
        r2 = self.store.add("s", FAKE_SHA2, 0.5, "b")
        self.assertEqual(r2["seq"], r1["seq"] + 1)

    def test_get_returns_copy(self):
        rec = self.store.add("s", FAKE_SHA, 1.0, "x")
        got = self.store.get(rec["id"])
        self.assertIsNotNone(got)
        self.assertEqual(got["id"], rec["id"])

    def test_get_missing_returns_none(self):
        self.assertIsNone(self.store.get("ckpt/x/999"))

    def test_list_all(self):
        self.store.add("a", FAKE_SHA, 1.0, "")
        self.store.add("b", FAKE_SHA, 0.5, "")
        self.assertEqual(len(self.store.list()), 2)

    def test_list_filter_session(self):
        self.store.add("a", FAKE_SHA, 1.0, "")
        self.store.add("a", FAKE_SHA2, 0.8, "")
        self.store.add("b", FAKE_SHA, 0.5, "")
        self.assertEqual(len(self.store.list(session="a")), 2)
        self.assertEqual(len(self.store.list(session="b")), 1)

    def test_list_ordered_by_seq(self):
        for i in range(5):
            self.store.add("s", FAKE_SHA, float(i), "")
        ckpts = self.store.list(session="s")
        seqs = [c["seq"] for c in ckpts]
        self.assertEqual(seqs, sorted(seqs))

    # --- delete -------------------------------------------------------------

    def test_delete_existing(self):
        rec = self.store.add("s", FAKE_SHA, 1.0, "")
        self.assertTrue(self.store.delete(rec["id"]))
        self.assertIsNone(self.store.get(rec["id"]))

    def test_delete_missing(self):
        self.assertFalse(self.store.delete("ckpt/nope/0"))

    # --- rollback history ---------------------------------------------------

    def test_record_rollback(self):
        rec = self.store.record_rollback("s", "best", "ckpt/s/1", FAKE_SHA, False)
        self.assertEqual(rec["session"], "s")
        self.assertEqual(rec["strategy"], "best")
        self.assertFalse(rec["dry_run"])

    def test_rollback_history_filter(self):
        self.store.record_rollback("a", "best", "ckpt/a/1", FAKE_SHA, False)
        self.store.record_rollback("b", "prev", "ckpt/b/2", FAKE_SHA2, True)
        self.assertEqual(len(self.store.rollback_history(session="a")), 1)
        self.assertEqual(len(self.store.rollback_history(session="b")), 1)
        self.assertEqual(len(self.store.rollback_history()), 2)

    # --- strategies ---------------------------------------------------------

    def test_best_checkpoint(self):
        self.store.add("s", FAKE_SHA, 0.3, "low")
        self.store.add("s", FAKE_SHA2, 0.9, "high")
        self.store.add("s", FAKE_SHA, 0.5, "mid")
        best = self.store.best_checkpoint("s")
        self.assertIsNotNone(best)
        self.assertAlmostEqual(best["score"], 0.9)

    def test_best_checkpoint_empty(self):
        self.assertIsNone(self.store.best_checkpoint("nonexistent"))

    def test_prev_checkpoint_last(self):
        r1 = self.store.add("s", FAKE_SHA, 1.0, "first")
        r2 = self.store.add("s", FAKE_SHA2, 0.8, "second")
        prev = self.store.prev_checkpoint("s")
        self.assertIsNotNone(prev)
        self.assertEqual(prev["id"], r1["id"])

    def test_prev_checkpoint_by_seq(self):
        self.store.add("s", FAKE_SHA, 1.0, "first")   # seq 1
        self.store.add("s", FAKE_SHA2, 0.8, "second")  # seq 2
        self.store.add("s", FAKE_SHA, 0.6, "third")    # seq 3
        prev = self.store.prev_checkpoint("s", current_seq=3)
        self.assertEqual(prev["seq"], 2)

    def test_prev_checkpoint_single(self):
        r1 = self.store.add("s", FAKE_SHA, 1.0, "only")
        prev = self.store.prev_checkpoint("s")
        self.assertEqual(prev["id"], r1["id"])

    def test_prev_checkpoint_empty(self):
        self.assertIsNone(self.store.prev_checkpoint("none"))

    # --- pruning ------------------------------------------------------------

    def test_prune_exceeds_max(self):
        orig_max = checkpoint.MAX_PER_SESSION
        checkpoint.MAX_PER_SESSION = 3
        try:
            for i in range(5):
                self.store.add("s", FAKE_SHA, float(i), "")
            ckpts = self.store.list(session="s")
            self.assertLessEqual(len(ckpts), 3)
        finally:
            checkpoint.MAX_PER_SESSION = orig_max

    # --- persistence --------------------------------------------------------

    def test_persist_reload(self):
        state_file = os.path.join(self.tmp, "state.json")
        store1 = checkpoint.CheckpointStore(state_file)
        r = store1.add("s", FAKE_SHA, 0.7, "persisted")
        store1.record_rollback("s", "best", r["id"], FAKE_SHA, False)

        store2 = checkpoint.CheckpointStore(state_file)
        self.assertEqual(len(store2.list()), 1)
        self.assertEqual(store2.list()[0]["label"], "persisted")
        self.assertEqual(len(store2.rollback_history()), 1)

    def test_persist_seq_survives_reload(self):
        state_file = os.path.join(self.tmp, "seq_state.json")
        store1 = checkpoint.CheckpointStore(state_file)
        store1.add("s", FAKE_SHA, 1.0, "")
        store1.add("s", FAKE_SHA2, 0.9, "")  # seq 2

        store2 = checkpoint.CheckpointStore(state_file)
        r3 = store2.add("s", FAKE_SHA, 0.8, "")  # should be seq 3
        self.assertEqual(r3["seq"], 3)

    # --- stats --------------------------------------------------------------

    def test_stats(self):
        self.store.add("a", FAKE_SHA, 1.0, "")
        self.store.add("b", FAKE_SHA, 0.5, "")
        self.store.record_rollback("a", "best", "x", FAKE_SHA, False)
        stats = self.store.stats()
        self.assertEqual(stats["sessions"], 2)
        self.assertEqual(stats["checkpoints"], 2)
        self.assertEqual(stats["rollbacks"], 1)


# ---------------------------------------------------------------------------
# Git helpers (mocked)
# ---------------------------------------------------------------------------

class TestGitHelpers(unittest.TestCase):

    @patch("checkpoint.subprocess.run")
    def test_resolve_commit_success(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0, stdout=FAKE_SHA + "\n",
                                          stderr="")
        result = checkpoint.resolve_commit("HEAD")
        self.assertEqual(result, FAKE_SHA)

    @patch("checkpoint.subprocess.run")
    def test_resolve_commit_failure(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1, stdout="",
                                          stderr="bad ref")
        with self.assertRaises(RuntimeError):
            checkpoint.resolve_commit("bad-ref")

    @patch("checkpoint.subprocess.run")
    def test_git_reset_hard_dry_run(self, mock_run):
        checkpoint.git_reset_hard(FAKE_SHA, dry_run=True)
        mock_run.assert_not_called()

    @patch("checkpoint.subprocess.run")
    def test_git_reset_hard_live(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        checkpoint.git_reset_hard(FAKE_SHA, dry_run=False)
        mock_run.assert_called_once()
        args = mock_run.call_args[0][0]
        self.assertIn("reset", args)
        self.assertIn("--hard", args)

    @patch("checkpoint.subprocess.run")
    def test_tag_exists_true(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0,
                                          stdout="ckpt-sess1-1\n", stderr="")
        self.assertTrue(checkpoint.tag_exists("ckpt-sess1-1"))

    @patch("checkpoint.subprocess.run")
    def test_tag_exists_false(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        self.assertFalse(checkpoint.tag_exists("nope"))


# ---------------------------------------------------------------------------
# Evaluation helper
# ---------------------------------------------------------------------------

class TestEvaluateCommit(unittest.TestCase):

    def test_no_eval_cmd(self):
        passed, score = checkpoint.evaluate_commit(FAKE_SHA, "")
        self.assertTrue(passed)
        self.assertAlmostEqual(score, 1.0)

    @patch("checkpoint.subprocess.run")
    def test_passing_with_score(self, mock_run):
        mock_run.return_value = MagicMock(
            returncode=0, stdout="0.85\n", stderr="")
        passed, score = checkpoint.evaluate_commit(FAKE_SHA, "echo 0.85")
        self.assertTrue(passed)
        self.assertAlmostEqual(score, 0.85)

    @patch("checkpoint.subprocess.run")
    def test_failing_zero_score(self, mock_run):
        mock_run.return_value = MagicMock(
            returncode=1, stdout="0.2\n", stderr="fail")
        passed, score = checkpoint.evaluate_commit(FAKE_SHA, "exit 1")
        self.assertFalse(passed)
        self.assertAlmostEqual(score, 0.2)

    @patch("checkpoint.subprocess.run")
    def test_non_numeric_stdout_defaults(self, mock_run):
        mock_run.return_value = MagicMock(
            returncode=0, stdout="not_a_number\n", stderr="")
        passed, score = checkpoint.evaluate_commit(FAKE_SHA, "true")
        self.assertTrue(passed)
        self.assertAlmostEqual(score, 1.0)

    @patch("checkpoint.subprocess.run")
    def test_timeout(self, mock_run):
        mock_run.side_effect = subprocess.TimeoutExpired(cmd="sleep", timeout=120)
        passed, score = checkpoint.evaluate_commit(FAKE_SHA, "sleep 200")
        self.assertFalse(passed)
        self.assertAlmostEqual(score, 0.0)


# ---------------------------------------------------------------------------
# HTTP API tests
# ---------------------------------------------------------------------------

class TestCheckpointHTTP(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.store = make_store(cls.tmp)
        cls.port = _PORT_BASE
        cls.server = start_server(cls.store, cls.port)
        time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def _add_ckpt(self, session: str = "test", score: float = 1.0,
                  commit: str = FAKE_SHA) -> dict:
        with patch("checkpoint.resolve_commit", return_value=commit), \
             patch("checkpoint.tag_exists", return_value=False), \
             patch("checkpoint.create_tag"):
            code, body = http("POST", self.port, "/checkpoints", {
                "session": session, "commit": "HEAD",
                "score": score, "label": "test",
            })
        self.assertEqual(code, 201)
        return body

    # --- POST /checkpoints --------------------------------------------------

    def test_post_checkpoint_success(self):
        rec = self._add_ckpt("http_test", 0.75)
        self.assertEqual(rec["session"], "http_test")
        self.assertAlmostEqual(rec["score"], 0.75)

    def test_post_checkpoint_missing_session(self):
        code, body = http("POST", self.port, "/checkpoints",
                          {"score": 1.0})
        self.assertEqual(code, 400)

    def test_post_checkpoint_bad_commit(self):
        with patch("checkpoint.resolve_commit",
                   side_effect=RuntimeError("bad ref")):
            code, body = http("POST", self.port, "/checkpoints",
                              {"session": "s", "commit": "bad-ref"})
        self.assertEqual(code, 400)

    # --- GET /checkpoints ---------------------------------------------------

    def test_get_all_checkpoints(self):
        self._add_ckpt("list_sess")
        code, body = http("GET", self.port, "/checkpoints")
        self.assertEqual(code, 200)
        self.assertIn("checkpoints", body)

    def test_get_checkpoints_filtered(self):
        self._add_ckpt("filter_sess_a")
        self._add_ckpt("filter_sess_a")
        self._add_ckpt("filter_sess_b")
        code, body = http("GET", self.port,
                          "/checkpoints?session=filter_sess_a")
        self.assertEqual(code, 200)
        self.assertEqual(len(body["checkpoints"]), 2)

    # --- GET /checkpoints/<id> ----------------------------------------------

    def test_get_checkpoint_by_id(self):
        rec = self._add_ckpt("by_id_sess")
        code, body = http("GET", self.port, f"/checkpoints/{rec['id']}")
        self.assertEqual(code, 200)
        self.assertEqual(body["id"], rec["id"])

    def test_get_checkpoint_not_found(self):
        code, body = http("GET", self.port, "/checkpoints/ckpt/nobody/999")
        self.assertEqual(code, 404)

    # --- DELETE /checkpoints/<id> -------------------------------------------

    def test_delete_checkpoint(self):
        rec = self._add_ckpt("del_sess")
        with patch("checkpoint.tag_exists", return_value=False):
            code, body = http("DELETE", self.port,
                              f"/checkpoints/{rec['id']}")
        self.assertEqual(code, 200)
        self.assertTrue(body["ok"])
        code2, _ = http("GET", self.port, f"/checkpoints/{rec['id']}")
        self.assertEqual(code2, 404)

    def test_delete_missing(self):
        with patch("checkpoint.tag_exists", return_value=False):
            code, body = http("DELETE", self.port,
                              "/checkpoints/ckpt/nope/0")
        self.assertEqual(code, 404)

    # --- POST /rollback ------------------------------------------------------

    def _rollback(self, session: str, strategy: str,
                  target: str = "") -> tuple[int, dict]:
        body: dict = {"session": session, "strategy": strategy,
                      "dry_run": True}
        if target:
            body["target"] = target
        with patch("checkpoint.git_reset_hard"):
            return http("POST", self.port, "/rollback", body)

    def test_rollback_best(self):
        sess = "rb_best"
        self._add_ckpt(sess, score=0.3)
        self._add_ckpt(sess, score=0.9)
        code, body = self._rollback(sess, "best")
        self.assertEqual(code, 200)
        self.assertIn("rolled_back_to", body)

    def test_rollback_prev(self):
        sess = "rb_prev"
        r1 = self._add_ckpt(sess, score=1.0)
        self._add_ckpt(sess, score=0.5)
        code, body = self._rollback(sess, "prev")
        self.assertEqual(code, 200)
        # Should land on first (previous) checkpoint
        self.assertEqual(body["rolled_back_to"], r1["id"])

    def test_rollback_specific(self):
        sess = "rb_specific"
        r1 = self._add_ckpt(sess, score=1.0)
        self._add_ckpt(sess, score=0.5)
        code, body = self._rollback(sess, "specific", target=r1["id"])
        self.assertEqual(code, 200)
        self.assertEqual(body["rolled_back_to"], r1["id"])

    def test_rollback_no_session(self):
        code, body = http("POST", self.port, "/rollback",
                          {"strategy": "best"})
        self.assertEqual(code, 400)

    def test_rollback_unknown_strategy(self):
        code, body = http("POST", self.port, "/rollback",
                          {"session": "s", "strategy": "cosmic"})
        self.assertEqual(code, 400)

    def test_rollback_no_checkpoints(self):
        code, body = self._rollback("empty_session_xyz", "best")
        self.assertEqual(code, 404)

    def test_rollback_specific_missing_target(self):
        code, body = http("POST", self.port, "/rollback",
                          {"session": "s", "strategy": "specific",
                           "dry_run": True})
        self.assertEqual(code, 400)

    def test_rollback_specific_not_found(self):
        with patch("checkpoint.resolve_commit",
                   side_effect=RuntimeError("bad ref")):
            code, body = http("POST", self.port, "/rollback",
                              {"session": "s", "strategy": "specific",
                               "target": "bad-ref", "dry_run": True})
        self.assertEqual(code, 404)

    # --- GET /rollback/history -----------------------------------------------

    def test_rollback_history(self):
        sess = "hist_sess"
        self._add_ckpt(sess, score=1.0)
        self._rollback(sess, "best")
        code, body = http("GET", self.port,
                          f"/rollback/history?session={sess}")
        self.assertEqual(code, 200)
        self.assertGreaterEqual(len(body["history"]), 1)

    # --- POST /evaluate ------------------------------------------------------

    def test_evaluate_no_cmd(self):
        orig = checkpoint.EVAL_CMD
        checkpoint.EVAL_CMD = ""
        try:
            with patch("checkpoint.resolve_commit", return_value=FAKE_SHA):
                code, body = http("POST", self.port, "/evaluate",
                                  {"session": "s", "commit": "HEAD"})
        finally:
            checkpoint.EVAL_CMD = orig
        self.assertEqual(code, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(body["recommendation"], "keep")

    def test_evaluate_passing(self):
        orig = checkpoint.EVAL_CMD
        checkpoint.EVAL_CMD = "true"
        try:
            with patch("checkpoint.resolve_commit", return_value=FAKE_SHA), \
                 patch("checkpoint.evaluate_commit", return_value=(True, 0.9)):
                code, body = http("POST", self.port, "/evaluate",
                                  {"session": "s", "commit": "HEAD"})
        finally:
            checkpoint.EVAL_CMD = orig
        self.assertEqual(code, 200)
        self.assertEqual(body["recommendation"], "keep")

    def test_evaluate_failing(self):
        with patch("checkpoint.resolve_commit", return_value=FAKE_SHA), \
             patch("checkpoint.evaluate_commit", return_value=(False, 0.1)):
            code, body = http("POST", self.port, "/evaluate",
                              {"session": "s", "commit": "HEAD"})
        self.assertEqual(code, 200)
        self.assertEqual(body["recommendation"], "rollback")

    def test_evaluate_bad_commit(self):
        with patch("checkpoint.resolve_commit",
                   side_effect=RuntimeError("bad")):
            code, body = http("POST", self.port, "/evaluate",
                              {"session": "s", "commit": "bad"})
        self.assertEqual(code, 400)

    # --- GET /status --------------------------------------------------------

    def test_status(self):
        code, body = http("GET", self.port, "/status")
        self.assertEqual(code, 200)
        for key in ("sessions", "checkpoints", "rollbacks"):
            self.assertIn(key, body)

    # --- 404 ----------------------------------------------------------------

    def test_unknown_get(self):
        code, _ = http("GET", self.port, "/nonexistent")
        self.assertEqual(code, 404)

    def test_unknown_post(self):
        code, _ = http("POST", self.port, "/nonexistent", {})
        self.assertEqual(code, 404)

    def test_unknown_delete(self):
        code, _ = http("DELETE", self.port, "/nonexistent")
        self.assertEqual(code, 404)


# ---------------------------------------------------------------------------
# Concurrency tests
# ---------------------------------------------------------------------------

class TestCheckpointConcurrency(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = make_store(self.tmp)

    def test_concurrent_add_no_duplicate_seq(self):
        """20 concurrent adds must produce 20 unique seq numbers."""
        results = []
        errors = []

        def add_one():
            try:
                r = self.store.add("concur", FAKE_SHA, 1.0, "")
                results.append(r["seq"])
            except Exception as exc:
                errors.append(exc)

        threads = [threading.Thread(target=add_one) for _ in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertFalse(errors, errors)
        self.assertEqual(len(set(results)), 20, "duplicate seq numbers found")

    def test_concurrent_add_persistence_consistent(self):
        """After 20 concurrent adds, reload shows exactly 20 records."""
        state_file = os.path.join(self.tmp, "conc_state.json")
        store = checkpoint.CheckpointStore(state_file)

        def add_one():
            store.add("s", FAKE_SHA, 1.0, "")

        threads = [threading.Thread(target=add_one) for _ in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        store2 = checkpoint.CheckpointStore(state_file)
        self.assertEqual(len(store2.list()), 20)


# ---------------------------------------------------------------------------
# Syntax / import smoke test
# ---------------------------------------------------------------------------

class TestCheckpointImport(unittest.TestCase):
    def test_import_ok(self):
        import importlib
        m = importlib.import_module("checkpoint")
        self.assertTrue(hasattr(m, "CheckpointStore"))
        self.assertTrue(hasattr(m, "run"))


if __name__ == "__main__":
    unittest.main()
