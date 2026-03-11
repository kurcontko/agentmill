"""
Tests for merge_gate.py — AgentMill Consensus-Based Merge Gate.

Run: python3 -m unittest tests.test_merge_gate
"""

import json
import os
import sys
import tempfile
import threading
import time
import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent.parent))

import merge_gate
from merge_gate import MergeGate


def make_gate(quorum: int = 2, total: int = 3) -> MergeGate:
    """Return a fresh in-memory MergeGate backed by a temp file."""
    tf = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
    tf.close()
    os.unlink(tf.name)
    return MergeGate(tf.name, quorum, total)


class TestMergeGateSubmit(unittest.TestCase):
    def test_submit_returns_merge_id(self):
        gate = make_gate()
        result = gate.submit("feature/foo", "abc123", "agent-1")
        self.assertIn("merge_id", result)
        self.assertTrue(result["ok"])

    def test_submit_creates_pending_request(self):
        gate = make_gate()
        r = gate.submit("feature/foo", "abc123", "agent-1")
        req = gate.get_request(r["merge_id"])
        self.assertIsNotNone(req)
        self.assertEqual(req["state"], "pending")
        self.assertEqual(req["branch"], "feature/foo")
        self.assertEqual(req["commit"], "abc123")
        self.assertEqual(req["author"], "agent-1")

    def test_submit_multiple_independent(self):
        gate = make_gate()
        id1 = gate.submit("branch-a", "aaa", "agent-1")["merge_id"]
        id2 = gate.submit("branch-b", "bbb", "agent-2")["merge_id"]
        self.assertNotEqual(id1, id2)
        self.assertEqual(gate.get_summary()["pending"], 2)


class TestMergeGateApprove(unittest.TestCase):
    def test_single_approval_not_ready(self):
        gate = make_gate(quorum=2)
        mid = gate.submit("feat", "abc", "a1")["merge_id"]
        result = gate.approve(mid, "validator-1")
        self.assertTrue(result["ok"])
        self.assertEqual(result["approved"], 1)
        self.assertEqual(result["required"], 2)
        self.assertFalse(result["ready"])
        self.assertEqual(gate.get_request(mid)["state"], "pending")

    def test_quorum_approvals_mark_approved(self):
        gate = make_gate(quorum=2)
        mid = gate.submit("feat", "abc", "a1")["merge_id"]
        gate.approve(mid, "validator-1")
        result = gate.approve(mid, "validator-2")
        self.assertTrue(result["ready"])
        self.assertEqual(gate.get_request(mid)["state"], "approved")

    def test_approval_after_approved_is_noop(self):
        gate = make_gate(quorum=1)
        mid = gate.submit("feat", "abc", "a1")["merge_id"]
        gate.approve(mid, "v1")
        result = gate.approve(mid, "v2")
        self.assertIn("error", result)
        self.assertEqual(result["error"], "already_approved")

    def test_approve_nonexistent_merge_id(self):
        gate = make_gate()
        result = gate.approve("no-such-id", "v1")
        self.assertEqual(result["error"], "not_found")

    def test_same_validator_double_approve(self):
        gate = make_gate(quorum=2)
        mid = gate.submit("feat", "abc", "a1")["merge_id"]
        gate.approve(mid, "validator-1")
        result = gate.approve(mid, "validator-1")
        # Second vote from same validator overwrites but count stays 1
        self.assertEqual(result["approved"], 1)
        self.assertFalse(result["ready"])

    def test_validators_approved_list(self):
        gate = make_gate(quorum=2)
        mid = gate.submit("feat", "abc", "a1")["merge_id"]
        gate.approve(mid, "v1", notes="looks good")
        gate.approve(mid, "v2")
        req = gate.get_request(mid)
        self.assertIn("v1", req["validators_approved"])
        self.assertIn("v2", req["validators_approved"])


class TestMergeGateReject(unittest.TestCase):
    def test_single_rejection_blocks(self):
        gate = make_gate(quorum=2)
        mid = gate.submit("feat", "abc", "a1")["merge_id"]
        result = gate.reject(mid, "validator-1", reason="tests fail")
        self.assertTrue(result["ok"])
        self.assertEqual(gate.get_request(mid)["state"], "rejected")

    def test_reject_after_approved_is_noop(self):
        gate = make_gate(quorum=1)
        mid = gate.submit("feat", "abc", "a1")["merge_id"]
        gate.approve(mid, "v1")
        result = gate.reject(mid, "v2", reason="too late")
        self.assertIn("error", result)

    def test_reject_nonexistent(self):
        gate = make_gate()
        result = gate.reject("no-such", "v1")
        self.assertEqual(result["error"], "not_found")

    def test_validators_rejected_list(self):
        gate = make_gate()
        mid = gate.submit("feat", "abc", "a1")["merge_id"]
        gate.reject(mid, "v1", reason="broken")
        req = gate.get_request(mid)
        self.assertIn("v1", req["validators_rejected"])


class TestMergeGateSummary(unittest.TestCase):
    def test_summary_counts(self):
        gate = make_gate(quorum=1, total=2)
        gate.submit("branch-a", "a", "a1")["merge_id"]
        id2 = gate.submit("branch-b", "b", "a2")["merge_id"]
        id3 = gate.submit("branch-c", "c", "a3")["merge_id"]
        gate.approve(id2, "v1")   # quorum=1, so this approves it
        gate.reject(id3, "v1")
        s = gate.get_summary()
        self.assertEqual(s["pending"], 1)
        self.assertEqual(s["approved"], 1)
        self.assertEqual(s["rejected"], 1)
        self.assertEqual(s["quorum"], 1)

    def test_get_pending_returns_only_pending(self):
        gate = make_gate(quorum=1)
        gate.submit("branch-a", "a", "a1")
        id2 = gate.submit("branch-b", "b", "a2")["merge_id"]
        gate.approve(id2, "v1")
        pending = gate.get_pending()
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["branch"], "branch-a")


class TestMergeGateConfigure(unittest.TestCase):
    def test_configure_changes_quorum(self):
        gate = make_gate(quorum=2)
        gate.configure(1, 3)
        self.assertEqual(gate.get_summary()["quorum"], 1)

    def test_configure_affects_new_approvals(self):
        gate = make_gate(quorum=3)
        mid = gate.submit("feat", "abc", "a1")["merge_id"]
        gate.configure(1, 3)
        # After reconfigure to quorum=1, one approval should be enough
        # NOTE: existing pending requests use the gate's current quorum at vote time
        result = gate.approve(mid, "v1")
        self.assertTrue(result["ready"])


class TestMergeGatePersistence(unittest.TestCase):
    def test_state_survives_reload(self):
        tf = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        tf.close()
        os.unlink(tf.name)

        gate1 = MergeGate(tf.name, 2, 3)
        mid = gate1.submit("feat", "abc", "a1")["merge_id"]
        gate1.approve(mid, "v1")

        gate2 = MergeGate(tf.name, 2, 3)
        req = gate2.get_request(mid)
        self.assertIsNotNone(req)
        self.assertEqual(req["branch"], "feat")
        self.assertEqual(req["approvals"], 1)
        self.assertEqual(req["state"], "pending")

        os.unlink(tf.name)

    def test_quorum_config_persists(self):
        tf = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        tf.close()
        os.unlink(tf.name)

        gate1 = MergeGate(tf.name, 2, 3)
        gate1.configure(1, 5)

        gate2 = MergeGate(tf.name, 2, 3)  # defaults ignored, file wins
        self.assertEqual(gate2.get_summary()["quorum"], 1)
        self.assertEqual(gate2.get_summary()["total_validators"], 5)

        os.unlink(tf.name)


class TestMergeGateExpiry(unittest.TestCase):
    def test_reap_expired_marks_stale(self):
        gate = make_gate()
        mid = gate.submit("feat", "abc", "a1")["merge_id"]

        # Manually backdate the submitted_at
        with gate._lock:
            gate._requests[mid]["submitted_at"] -= merge_gate.MERGE_TTL + 1

        expired = gate.reap_expired()
        self.assertEqual(expired, 1)
        self.assertEqual(gate.get_request(mid)["state"], "expired")

    def test_reap_skips_decided(self):
        gate = make_gate(quorum=1)
        mid = gate.submit("feat", "abc", "a1")["merge_id"]
        gate.approve(mid, "v1")

        with gate._lock:
            gate._requests[mid]["submitted_at"] -= merge_gate.MERGE_TTL + 1

        expired = gate.reap_expired()
        self.assertEqual(expired, 0)
        self.assertEqual(gate.get_request(mid)["state"], "approved")


class TestMergeGateConcurrency(unittest.TestCase):
    def test_concurrent_approvals_no_double_count(self):
        """20 validators race to approve; quorum=10. Final count must be exact."""
        gate = make_gate(quorum=10, total=20)
        mid = gate.submit("feat", "abc", "a1")["merge_id"]

        barrier = threading.Barrier(20)
        results = []

        def vote(vid: int) -> None:
            barrier.wait()
            results.append(gate.approve(mid, f"validator-{vid}"))

        threads = [threading.Thread(target=vote, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        req = gate.get_request(mid)
        # Once quorum is reached (10), further votes are blocked; final count == quorum
        self.assertEqual(req["approvals"], 10)
        self.assertEqual(req["state"], "approved")

        ready_results = [r for r in results if r.get("ready")]
        # Exactly one response should have flipped ready=True
        self.assertEqual(len(ready_results), 1)

    def test_concurrent_submits_unique_ids(self):
        gate = make_gate()
        ids = []
        lock = threading.Lock()

        def submit(i: int) -> None:
            r = gate.submit(f"branch-{i}", "abc", "a1")
            with lock:
                ids.append(r["merge_id"])

        threads = [threading.Thread(target=submit, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(len(ids), len(set(ids)))


class TestMergeGateHTTP(unittest.TestCase):
    """Integration tests against the HTTP handler."""

    def setUp(self):
        merge_gate._gate = make_gate(quorum=2, total=3)

    def _call(self, method: str, path: str, body: dict | None = None):
        handler = MagicMock(spec=merge_gate.MergeGateHandler)
        handler.path = path
        handler.headers = {}
        body_bytes = json.dumps(body).encode() if body else b""
        handler.headers["Content-Length"] = str(len(body_bytes))
        handler.rfile = BytesIO(body_bytes)
        responses = []
        handler.send_response = lambda code: responses.append(("code", code))
        handler.send_header = MagicMock()
        handler.end_headers = MagicMock()
        written = []
        handler.wfile = MagicMock()
        handler.wfile.write = lambda data: written.append(data)

        if method == "GET":
            merge_gate.MergeGateHandler.do_GET(handler)
        else:
            merge_gate.MergeGateHandler.do_POST(handler)

        code = next((v for k, v in responses if k == "code"), None)
        resp_body = json.loads(written[0]) if written else {}
        return code, resp_body

    def test_http_submit(self):
        code, body = self._call("POST", "/submit", {"branch": "feat", "commit": "abc", "author": "a1"})
        self.assertEqual(code, 201)
        self.assertIn("merge_id", body)

    def test_http_status_summary(self):
        code, body = self._call("GET", "/status")
        self.assertEqual(code, 200)
        self.assertIn("pending", body)

    def test_http_approve_and_status(self):
        _, sub = self._call("POST", "/submit", {"branch": "feat", "commit": "abc", "author": "a1"})
        mid = sub["merge_id"]
        code, body = self._call("POST", "/approve", {"merge_id": mid, "validator_id": "v1"})
        self.assertEqual(code, 200)
        self.assertFalse(body["ready"])

    def test_http_reject(self):
        _, sub = self._call("POST", "/submit", {"branch": "feat", "commit": "abc", "author": "a1"})
        mid = sub["merge_id"]
        code, body = self._call("POST", "/reject", {"merge_id": mid, "validator_id": "v1", "reason": "bad"})
        self.assertEqual(code, 200)
        req = merge_gate._gate.get_request(mid)
        self.assertEqual(req["state"], "rejected")

    def test_http_get_status_by_id(self):
        _, sub = self._call("POST", "/submit", {"branch": "feat", "commit": "abc", "author": "a1"})
        mid = sub["merge_id"]
        code, body = self._call("GET", f"/status/{mid}")
        self.assertEqual(code, 200)
        self.assertEqual(body["branch"], "feat")

    def test_http_get_pending(self):
        self._call("POST", "/submit", {"branch": "feat", "commit": "abc", "author": "a1"})
        code, body = self._call("GET", "/pending")
        self.assertEqual(code, 200)
        self.assertIsInstance(body, list)
        self.assertEqual(len(body), 1)

    def test_http_configure(self):
        code, body = self._call("POST", "/configure", {"quorum": 1, "total_validators": 2})
        self.assertEqual(code, 200)
        self.assertTrue(body["ok"])

    def test_http_submit_missing_branch(self):
        code, body = self._call("POST", "/submit", {"commit": "abc"})
        self.assertEqual(code, 400)

    def test_http_approve_missing_fields(self):
        code, body = self._call("POST", "/approve", {"merge_id": "x"})
        self.assertEqual(code, 400)

    def test_http_unknown_route(self):
        code, _ = self._call("GET", "/no-such-route")
        self.assertEqual(code, 404)


if __name__ == "__main__":
    unittest.main()
