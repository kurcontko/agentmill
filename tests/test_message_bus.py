"""Tests for message_bus.py"""

import json
import os
import sys
import tempfile
import threading
import time
import unittest
from http.client import HTTPConnection
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent))

import message_bus
from message_bus import MessageBus


class TestMessageBusCore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.tmp.close()
        os.unlink(self.tmp.name)  # start fresh
        self.bus = MessageBus(state_file=self.tmp.name)

    def tearDown(self):
        try:
            os.unlink(self.tmp.name)
        except FileNotFoundError:
            pass

    # ------------------------------------------------------------------
    # Publish / mailbox basics
    # ------------------------------------------------------------------

    def test_publish_returns_id(self):
        msg_id = self.bus.publish("agent-1", "*", "status", {"state": "running"})
        self.assertIsInstance(msg_id, str)
        self.assertTrue(len(msg_id) > 0)

    def test_broadcast_reaches_all_known_agents(self):
        # Prime mailboxes by publishing targeted messages first
        self.bus.publish("agent-1", "agent-2", "hello", {})
        self.bus.publish("agent-2", "agent-1", "hello", {})
        # Now broadcast
        self.bus.publish("agent-1", "*", "status", {"ok": True})
        mb1 = self.bus.get_mailbox("agent-1")
        mb2 = self.bus.get_mailbox("agent-2")
        topics1 = [m["topic"] for m in mb1]
        topics2 = [m["topic"] for m in mb2]
        self.assertIn("status", topics1)
        self.assertIn("status", topics2)

    def test_targeted_message_only_in_recipient_mailbox(self):
        self.bus.publish("agent-1", "agent-2", "request", {"task": "x"})
        self.bus.publish("agent-2", "agent-3", "request", {"task": "y"})
        mb2 = self.bus.get_mailbox("agent-2")
        msgs_to_2 = [m for m in mb2 if m["to"] == "agent-2"]
        self.assertTrue(any(m["from"] == "agent-1" for m in msgs_to_2))
        mb3 = self.bus.get_mailbox("agent-3")
        self.assertFalse(any(m["from"] == "agent-1" for m in mb3))

    def test_message_fields(self):
        self.bus.publish("agent-1", "agent-2", "heartbeat", {"alive": True})
        msgs = self.bus.get_mailbox("agent-2")
        self.assertEqual(len(msgs), 1)
        m = msgs[0]
        self.assertEqual(m["from"], "agent-1")
        self.assertEqual(m["to"], "agent-2")
        self.assertEqual(m["topic"], "heartbeat")
        self.assertEqual(m["body"], {"alive": True})
        self.assertIn("id", m)
        self.assertIn("ts", m)

    def test_empty_mailbox_returns_empty_list(self):
        msgs = self.bus.get_mailbox("nonexistent-agent")
        self.assertEqual(msgs, [])

    def test_ack_removes_message(self):
        msg_id = self.bus.publish("a1", "a2", "status", {})
        self.assertEqual(len(self.bus.get_mailbox("a2")), 1)
        found = self.bus.ack("a2", msg_id)
        self.assertTrue(found)
        self.assertEqual(len(self.bus.get_mailbox("a2")), 0)

    def test_ack_wrong_agent_returns_false(self):
        msg_id = self.bus.publish("a1", "a2", "status", {})
        found = self.bus.ack("a3", msg_id)
        self.assertFalse(found)
        # message still in a2's mailbox
        self.assertEqual(len(self.bus.get_mailbox("a2")), 1)

    def test_ack_unknown_id_returns_false(self):
        self.bus.publish("a1", "a2", "status", {})
        found = self.bus.ack("a2", "does-not-exist")
        self.assertFalse(found)

    def test_clear_mailbox(self):
        self.bus.publish("a1", "a2", "status", {})
        self.bus.publish("a1", "a2", "heartbeat", {})
        self.bus.clear_mailbox("a2")
        self.assertEqual(self.bus.get_mailbox("a2"), [])

    # ------------------------------------------------------------------
    # History
    # ------------------------------------------------------------------

    def test_get_history_returns_all(self):
        self.bus.publish("a1", "*", "t1", {})
        self.bus.publish("a2", "*", "t2", {})
        self.bus.publish("a3", "*", "t3", {})
        h = self.bus.get_history()
        self.assertEqual(len(h), 3)

    def test_history_limit(self):
        for i in range(10):
            self.bus.publish("a1", "*", f"t{i}", {})
        h = self.bus.get_history(limit=5)
        self.assertEqual(len(h), 5)
        # should be the 5 most recent
        topics = [m["topic"] for m in h]
        self.assertEqual(topics, [f"t{i}" for i in range(5, 10)])

    # ------------------------------------------------------------------
    # Topics
    # ------------------------------------------------------------------

    def test_get_topics(self):
        self.bus.publish("a1", "*", "status", {})
        self.bus.publish("a2", "*", "heartbeat", {})
        self.bus.publish("a3", "*", "status", {})
        topics = self.bus.get_topics()
        self.assertEqual(sorted(topics), ["heartbeat", "status"])

    # ------------------------------------------------------------------
    # Status
    # ------------------------------------------------------------------

    def test_status_counts(self):
        self.bus.publish("a1", "a2", "msg", {})
        s = self.bus.status()
        self.assertEqual(s["total_messages"], 1)
        self.assertEqual(s["pending_acks"], 1)  # a2 mailbox has 1 unacked
        self.assertIn("a1", s["agents"])
        self.assertIn("a2", s["agents"])

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def test_state_persisted_and_loaded(self):
        self.bus.publish("a1", "a2", "status", {"k": "v"})
        # Create a new bus instance from the same file
        bus2 = MessageBus(state_file=self.tmp.name)
        msgs = bus2.get_mailbox("a2")
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["topic"], "status")

    def test_messages_history_persisted(self):
        self.bus.publish("a1", "*", "t1", {})
        self.bus.publish("a2", "*", "t2", {})
        bus2 = MessageBus(state_file=self.tmp.name)
        h = bus2.get_history()
        self.assertEqual(len(h), 2)

    # ------------------------------------------------------------------
    # SSE subscribe
    # ------------------------------------------------------------------

    def test_subscribe_receives_new_messages(self):
        q, unsub = self.bus.subscribe("agent-sse")
        self.bus.publish("sender", "agent-sse", "ping", {"n": 1})
        try:
            data = q.get(timeout=1)
        finally:
            unsub()
        msg = json.loads(data)
        self.assertEqual(msg["topic"], "ping")

    def test_subscribe_receives_broadcasts(self):
        q, unsub = self.bus.subscribe("agent-sse")
        self.bus.publish("sender", "*", "ping", {"n": 1})
        try:
            data = q.get(timeout=1)
        finally:
            unsub()
        msg = json.loads(data)
        self.assertEqual(msg["topic"], "ping")

    def test_subscribe_does_not_receive_others_targeted(self):
        import queue as qmod
        q, unsub = self.bus.subscribe("agent-a")
        self.bus.publish("sender", "agent-b", "private", {})
        try:
            with self.assertRaises(qmod.Empty):
                q.get(timeout=0.1)
        finally:
            unsub()

    def test_unsubscribe_stops_delivery(self):
        import queue as qmod
        q, unsub = self.bus.subscribe("agent-sse")
        unsub()
        self.bus.publish("sender", "agent-sse", "after-unsub", {})
        with self.assertRaises(qmod.Empty):
            q.get(timeout=0.1)

    # ------------------------------------------------------------------
    # Concurrent publish — no double-delivery
    # ------------------------------------------------------------------

    def test_concurrent_publish_no_duplicates(self):
        """20 threads each publish 1 message; each recipient gets exactly N messages."""
        N = 20
        results = []
        errors = []

        def worker(i):
            try:
                self.bus.publish(f"agent-{i}", "collector", "event", {"i": i})
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(N)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(errors, [])
        msgs = self.bus.get_mailbox("collector")
        indices = sorted(m["body"]["i"] for m in msgs)
        self.assertEqual(indices, list(range(N)))

    def test_concurrent_ack_idempotent(self):
        """Acking the same message from multiple threads should be safe."""
        msg_id = self.bus.publish("a1", "a2", "status", {})
        results = []

        def worker():
            results.append(self.bus.ack("a2", msg_id))

        threads = [threading.Thread(target=worker) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # Exactly one ack should succeed (find=True)
        self.assertEqual(results.count(True), 1)
        self.assertEqual(results.count(False), 9)


# ---------------------------------------------------------------------------
# HTTP API integration tests
# ---------------------------------------------------------------------------


class TestMessageBusHTTP(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        cls.tmp.close()
        os.unlink(cls.tmp.name)

        cls.port = 19903
        # Patch global BUS used by HTTP handler
        cls.bus = MessageBus(state_file=cls.tmp.name)
        message_bus.BUS = cls.bus

        from http.server import HTTPServer
        cls.server = HTTPServer(("127.0.0.1", cls.port), message_bus.BusHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        try:
            os.unlink(cls.tmp.name)
        except FileNotFoundError:
            pass

    def _conn(self):
        return HTTPConnection("127.0.0.1", self.port)

    def test_publish_returns_201(self):
        conn = self._conn()
        body = json.dumps({"from": "a1", "to": "*", "topic": "status", "body": {}}).encode()
        conn.request("POST", "/publish", body, {"Content-Length": str(len(body))})
        r = conn.getresponse()
        self.assertEqual(r.status, 201)
        data = json.loads(r.read())
        self.assertTrue(data["ok"])
        self.assertIn("id", data)

    def test_publish_missing_topic_returns_400(self):
        conn = self._conn()
        body = json.dumps({"from": "a1", "to": "*", "body": {}}).encode()
        conn.request("POST", "/publish", body, {"Content-Length": str(len(body))})
        r = conn.getresponse()
        self.assertEqual(r.status, 400)

    def test_mailbox_get(self):
        conn = self._conn()
        body = json.dumps({"from": "a1", "to": "mb-test", "topic": "hello", "body": {"x": 1}}).encode()
        conn.request("POST", "/publish", body, {"Content-Length": str(len(body))})
        conn.getresponse().read()

        conn2 = self._conn()
        conn2.request("GET", "/mailbox/mb-test")
        r = conn2.getresponse()
        self.assertEqual(r.status, 200)
        data = json.loads(r.read())
        self.assertGreaterEqual(len(data["messages"]), 1)
        self.assertEqual(data["messages"][-1]["topic"], "hello")

    def test_ack_endpoint(self):
        conn = self._conn()
        body = json.dumps({"from": "a1", "to": "ack-agent", "topic": "t", "body": {}}).encode()
        conn.request("POST", "/publish", body, {"Content-Length": str(len(body))})
        pub_data = json.loads(conn.getresponse().read())
        msg_id = pub_data["id"]

        conn2 = self._conn()
        ack_body = json.dumps({"agent": "ack-agent", "id": msg_id}).encode()
        conn2.request("POST", "/ack", ack_body, {"Content-Length": str(len(ack_body))})
        r = conn2.getresponse()
        self.assertEqual(r.status, 200)
        data = json.loads(r.read())
        self.assertTrue(data["ok"])
        self.assertTrue(data["found"])

    def test_delete_mailbox(self):
        conn = self._conn()
        body = json.dumps({"from": "a1", "to": "del-agent", "topic": "t", "body": {}}).encode()
        conn.request("POST", "/publish", body, {"Content-Length": str(len(body))})
        conn.getresponse().read()

        conn2 = self._conn()
        conn2.request("DELETE", "/mailbox/del-agent")
        r = conn2.getresponse()
        self.assertEqual(r.status, 200)

        conn3 = self._conn()
        conn3.request("GET", "/mailbox/del-agent")
        data = json.loads(conn3.getresponse().read())
        self.assertEqual(data["messages"], [])

    def test_status_endpoint(self):
        conn = self._conn()
        conn.request("GET", "/status")
        r = conn.getresponse()
        self.assertEqual(r.status, 200)
        data = json.loads(r.read())
        self.assertIn("total_messages", data)
        self.assertIn("agents", data)
        self.assertIn("pending_acks", data)

    def test_topics_endpoint(self):
        conn = self._conn()
        body = json.dumps({"from": "a1", "to": "*", "topic": "unique-topic-xyz", "body": {}}).encode()
        conn.request("POST", "/publish", body, {"Content-Length": str(len(body))})
        conn.getresponse().read()

        conn2 = self._conn()
        conn2.request("GET", "/topics")
        data = json.loads(conn2.getresponse().read())
        self.assertIn("unique-topic-xyz", data["topics"])

    def test_messages_endpoint(self):
        conn = self._conn()
        conn.request("GET", "/messages")
        r = conn.getresponse()
        self.assertEqual(r.status, 200)
        data = json.loads(r.read())
        self.assertIn("messages", data)

    def test_unknown_route_404(self):
        conn = self._conn()
        conn.request("GET", "/nonexistent")
        r = conn.getresponse()
        self.assertEqual(r.status, 404)

    def test_ack_missing_fields_400(self):
        conn = self._conn()
        body = json.dumps({"agent": "a1"}).encode()  # missing id
        conn.request("POST", "/ack", body, {"Content-Length": str(len(body))})
        r = conn.getresponse()
        self.assertEqual(r.status, 400)


if __name__ == "__main__":
    unittest.main()
