"""Tests for cross_repo_coordinator.py"""
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from http.server import HTTPServer
from pathlib import Path

# Ensure project root is on path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import cross_repo_coordinator as crc


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_state(tmp_dir: str) -> crc.CrossRepoState:
    return crc.CrossRepoState(os.path.join(tmp_dir, "state.json"))


def _register(state: crc.CrossRepoState, *ids: str) -> None:
    for rid in ids:
        state.register_repo(rid, f"https://github.com/org/{rid}", "1.0.0")


# ---------------------------------------------------------------------------
# Repo registration
# ---------------------------------------------------------------------------

class TestRepoRegistration(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        self.state = make_state(self.tmp)

    def test_register_new_repo(self) -> None:
        ok = self.state.register_repo("lib-a", "https://example.com/lib-a", "1.0.0")
        self.assertTrue(ok)
        repos = self.state.list_repos()
        self.assertEqual(len(repos), 1)
        self.assertEqual(repos[0]["id"], "lib-a")
        self.assertEqual(repos[0]["version"], "1.0.0")

    def test_register_duplicate_rejected(self) -> None:
        self.state.register_repo("lib-a", "https://example.com/lib-a", "1.0.0")
        ok = self.state.register_repo("lib-a", "https://example.com/other", "2.0.0")
        self.assertFalse(ok)
        repos = self.state.list_repos()
        self.assertEqual(len(repos), 1)

    def test_delete_repo(self) -> None:
        _register(self.state, "lib-a")
        ok = self.state.delete_repo("lib-a")
        self.assertTrue(ok)
        self.assertEqual(self.state.list_repos(), [])

    def test_delete_nonexistent_repo(self) -> None:
        ok = self.state.delete_repo("ghost")
        self.assertFalse(ok)

    def test_delete_repo_removes_deps(self) -> None:
        _register(self.state, "lib-a", "app-b")
        self.state.add_dep("app-b", "lib-a")
        self.state.delete_repo("lib-a")
        self.assertEqual(self.state.list_deps(), [])

    def test_update_version(self) -> None:
        _register(self.state, "lib-a")
        ok = self.state.update_version("lib-a", "2.0.0")
        self.assertTrue(ok)
        repos = {r["id"]: r for r in self.state.list_repos()}
        self.assertEqual(repos["lib-a"]["version"], "2.0.0")

    def test_update_version_unknown_repo(self) -> None:
        ok = self.state.update_version("ghost", "2.0.0")
        self.assertFalse(ok)

    def test_list_repos_empty(self) -> None:
        self.assertEqual(self.state.list_repos(), [])


# ---------------------------------------------------------------------------
# Dependency management
# ---------------------------------------------------------------------------

class TestDependencies(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        self.state = make_state(self.tmp)
        _register(self.state, "lib-a", "lib-b", "app-c")

    def test_add_dep_ok(self) -> None:
        ok, err = self.state.add_dep("app-c", "lib-a")
        self.assertTrue(ok)
        self.assertEqual(err, "")
        deps = self.state.list_deps()
        self.assertEqual(len(deps), 1)
        self.assertEqual(deps[0], {"consumer": "app-c", "provider": "lib-a"})

    def test_add_dep_unknown_consumer(self) -> None:
        ok, err = self.state.add_dep("ghost", "lib-a")
        self.assertFalse(ok)
        self.assertIn("consumer", err)

    def test_add_dep_unknown_provider(self) -> None:
        ok, err = self.state.add_dep("app-c", "ghost")
        self.assertFalse(ok)
        self.assertIn("provider", err)

    def test_add_dep_self_loop_rejected(self) -> None:
        ok, err = self.state.add_dep("lib-a", "lib-a")
        self.assertFalse(ok)
        self.assertIn("self", err)

    def test_add_dep_duplicate_rejected(self) -> None:
        self.state.add_dep("app-c", "lib-a")
        ok, err = self.state.add_dep("app-c", "lib-a")
        self.assertFalse(ok)
        self.assertIn("already exists", err)

    def test_cycle_detection_simple(self) -> None:
        # lib-a -> lib-b, lib-b -> lib-a should be rejected
        self.state.add_dep("lib-a", "lib-b")
        ok, err = self.state.add_dep("lib-b", "lib-a")
        self.assertFalse(ok)
        self.assertIn("cycle", err)

    def test_cycle_detection_transitive(self) -> None:
        # A -> B -> C, then C -> A should be rejected
        _register(self.state, "svc-d")
        self.state.add_dep("lib-a", "lib-b")
        self.state.add_dep("lib-b", "app-c")
        ok, err = self.state.add_dep("app-c", "lib-a")
        self.assertFalse(ok)
        self.assertIn("cycle", err)

    def test_non_cycle_allowed(self) -> None:
        # Diamond: app-c -> lib-a, app-c -> lib-b, lib-a -> lib-b  (no cycle)
        ok1, _ = self.state.add_dep("app-c", "lib-a")
        ok2, _ = self.state.add_dep("app-c", "lib-b")
        ok3, _ = self.state.add_dep("lib-a", "lib-b")
        self.assertTrue(all([ok1, ok2, ok3]))

    def test_delete_dep(self) -> None:
        self.state.add_dep("app-c", "lib-a")
        ok = self.state.delete_dep("app-c", "lib-a")
        self.assertTrue(ok)
        self.assertEqual(self.state.list_deps(), [])

    def test_delete_dep_nonexistent(self) -> None:
        ok = self.state.delete_dep("app-c", "lib-a")
        self.assertFalse(ok)

    def test_consumers_of(self) -> None:
        _register(self.state, "app-d")
        self.state.add_dep("app-c", "lib-a")
        self.state.add_dep("app-d", "lib-a")
        consumers = sorted(self.state.consumers_of("lib-a"))
        self.assertEqual(consumers, ["app-c", "app-d"])

    def test_consumers_of_no_consumers(self) -> None:
        self.assertEqual(self.state.consumers_of("lib-a"), [])


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

class TestEvents(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        self.state = make_state(self.tmp)
        _register(self.state, "lib-a", "app-b", "app-c")
        self.state.add_dep("app-b", "lib-a")
        self.state.add_dep("app-c", "lib-a")

    def test_publish_api_change_notifies_consumers(self) -> None:
        eid, notified = self.state.publish_event("api_change", "lib-a",
                                                  {"change": "renamed foo->bar"})
        self.assertIn(eid, self.state.events)
        self.assertEqual(sorted(notified), ["app-b", "app-c"])

    def test_publish_version_bump_notifies_consumers(self) -> None:
        eid, notified = self.state.publish_event("version_bump", "lib-a",
                                                  {"version": "2.0.0"})
        self.assertEqual(sorted(notified), ["app-b", "app-c"])

    def test_publish_integration_result_no_notifications(self) -> None:
        eid, notified = self.state.publish_event("integration_result", "app-b",
                                                  {"ok": True})
        self.assertEqual(notified, [])

    def test_ack_event(self) -> None:
        eid, _ = self.state.publish_event("api_change", "lib-a", {})
        ok, err = self.state.ack_event(eid, "app-b")
        self.assertTrue(ok)
        self.assertEqual(err, "")

    def test_ack_event_not_in_notified_list(self) -> None:
        eid, _ = self.state.publish_event("api_change", "lib-a", {})
        # lib-a itself is not in the notified list
        ok, err = self.state.ack_event(eid, "lib-a")
        self.assertFalse(ok)
        self.assertIn("not in notified", err)

    def test_ack_nonexistent_event(self) -> None:
        ok, err = self.state.ack_event("bad-id", "app-b")
        self.assertFalse(ok)
        self.assertIn("not found", err)

    def test_list_events_excludes_fully_acked(self) -> None:
        eid, _ = self.state.publish_event("api_change", "lib-a", {})
        self.state.ack_event(eid, "app-b")
        self.state.ack_event(eid, "app-c")
        events = self.state.list_events()
        ids = [e["id"] for e in events]
        self.assertNotIn(eid, ids)

    def test_list_events_shows_partial_acks(self) -> None:
        eid, _ = self.state.publish_event("api_change", "lib-a", {})
        self.state.ack_event(eid, "app-b")  # only app-b acked
        events = self.state.list_events()
        ids = [e["id"] for e in events]
        self.assertIn(eid, ids)
        ev = next(e for e in events if e["id"] == eid)
        self.assertEqual(ev["pending_acks"], ["app-c"])

    def test_reap_expired_events(self) -> None:
        eid, _ = self.state.publish_event("api_change", "lib-a", {})
        # Backdate the event
        self.state.events[eid]["created_at"] = time.time() - crc.EVENT_TTL - 1
        n = self.state.reap_expired_events()
        self.assertEqual(n, 1)
        self.assertNotIn(eid, self.state.events)

    def test_reap_does_not_remove_fresh_events(self) -> None:
        eid, _ = self.state.publish_event("api_change", "lib-a", {})
        n = self.state.reap_expired_events()
        self.assertEqual(n, 0)
        self.assertIn(eid, self.state.events)

    def test_integration_result_included_in_list(self) -> None:
        eid, _ = self.state.publish_event("integration_result", "app-b",
                                          {"ok": True, "details": "all tests pass"})
        # integration_result has no notified repos, so it IS shown (no acks needed)
        events = self.state.list_events()
        ids = [e["id"] for e in events]
        self.assertIn(eid, ids)


# ---------------------------------------------------------------------------
# Manifest and status
# ---------------------------------------------------------------------------

class TestManifestAndStatus(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        self.state = make_state(self.tmp)
        _register(self.state, "lib-a", "app-b")
        self.state.add_dep("app-b", "lib-a")

    def test_manifest_structure(self) -> None:
        manifest = self.state.get_manifest()
        self.assertIn("lib-a", manifest["repos"])
        self.assertIn("app-b", manifest["repos"])
        self.assertEqual(manifest["deps"], [{"consumer": "app-b", "provider": "lib-a"}])
        self.assertEqual(manifest["pending_events"], 0)

    def test_manifest_counts_pending_events(self) -> None:
        self.state.publish_event("api_change", "lib-a", {})
        manifest = self.state.get_manifest()
        self.assertEqual(manifest["pending_events"], 1)

    def test_status(self) -> None:
        self.state.publish_event("api_change", "lib-a", {})
        status = self.state.get_status()
        self.assertEqual(status["repos"], 2)
        self.assertEqual(status["deps"], 1)
        self.assertEqual(status["events"], 1)
        self.assertEqual(status["unacked"], 1)


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

class TestPersistence(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()

    def test_state_survives_reload(self) -> None:
        state1 = make_state(self.tmp)
        _register(state1, "lib-a", "app-b")
        state1.add_dep("app-b", "lib-a")
        eid, _ = state1.publish_event("api_change", "lib-a", {"detail": "x"})
        state1.ack_event(eid, "app-b")

        state2 = make_state(self.tmp)
        self.assertIn("lib-a", {r["id"] for r in state2.list_repos()})
        self.assertEqual(state2.list_deps(), [{"consumer": "app-b", "provider": "lib-a"}])
        ev = state2.events.get(eid)
        self.assertIsNotNone(ev)
        self.assertIn("app-b", ev["acks"])

    def test_missing_state_file_starts_clean(self) -> None:
        state = make_state(os.path.join(self.tmp, "subdir"))
        self.assertEqual(state.list_repos(), [])
        self.assertEqual(state.list_deps(), [])


# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------

class TestConcurrency(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        self.state = make_state(self.tmp)

    def test_concurrent_register_no_duplicates(self) -> None:
        """20 threads try to register the same repo; exactly one should win."""
        results: list[bool] = []
        lock = threading.Lock()

        def try_register() -> None:
            ok = self.state.register_repo("shared-lib", "https://x.com", "1.0.0")
            with lock:
                results.append(ok)

        threads = [threading.Thread(target=try_register) for _ in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(sum(results), 1)
        self.assertEqual(len(self.state.list_repos()), 1)

    def test_concurrent_ack_exactly_once(self) -> None:
        """20 threads concurrently ack an event; each should succeed at most once."""
        _register(self.state, "lib-a")
        for i in range(10):
            self.state.register_repo(f"app-{i}", f"https://x.com/{i}", "1.0.0")
            self.state.add_dep(f"app-{i}", "lib-a")

        eid, notified = self.state.publish_event("api_change", "lib-a", {})

        successes: list[str] = []
        lock = threading.Lock()

        def ack(rid: str) -> None:
            ok, _ = self.state.ack_event(eid, rid)
            if ok:
                with lock:
                    successes.append(rid)

        threads = [threading.Thread(target=ack, args=(rid,)) for rid in notified]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # Each notified repo should have acked exactly once
        self.assertEqual(sorted(successes), sorted(notified))
        ev = self.state.events[eid]
        self.assertEqual(ev["acks"], set(notified))

    def test_concurrent_publish_events(self) -> None:
        """20 threads publish events simultaneously; all should be recorded."""
        _register(self.state, "lib-a", "app-b")
        self.state.add_dep("app-b", "lib-a")

        event_ids: list[str] = []
        lock = threading.Lock()

        def publish(i: int) -> None:
            eid, _ = self.state.publish_event("api_change", "lib-a",
                                               {"change": f"change-{i}"})
            with lock:
                event_ids.append(eid)

        threads = [threading.Thread(target=publish, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(len(event_ids), 20)
        self.assertEqual(len(set(event_ids)), 20)  # all unique IDs


# ---------------------------------------------------------------------------
# HTTP API
# ---------------------------------------------------------------------------

def _start_server(state: crc.CrossRepoState) -> tuple[HTTPServer, int]:
    """Start a test HTTP server on a random port."""
    crc._state = state
    server = HTTPServer(("127.0.0.1", 0), crc.CrossRepoHandler)
    port = server.server_address[1]
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server, port


def _call(port: int, method: str, path: str,
          body: dict | None = None) -> tuple[int, dict]:
    import urllib.request
    import urllib.error
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


class TestHTTPAPI(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        self.state = make_state(self.tmp)
        self.server, self.port = _start_server(self.state)

    def tearDown(self) -> None:
        self.server.shutdown()

    def _call(self, method: str, path: str,
              body: dict | None = None) -> tuple[int, dict]:
        return _call(self.port, method, path, body)

    def test_register_and_list_repos(self) -> None:
        code, data = self._call("POST", "/repos",
                                 {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        self.assertEqual(code, 201)
        code, data = self._call("GET", "/repos")
        self.assertEqual(code, 200)
        self.assertEqual(len(data["repos"]), 1)

    def test_register_duplicate_409(self) -> None:
        self._call("POST", "/repos",
                   {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        code, _ = self._call("POST", "/repos",
                              {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        self.assertEqual(code, 409)

    def test_register_missing_fields_400(self) -> None:
        code, _ = self._call("POST", "/repos", {"id": "lib-a"})
        self.assertEqual(code, 400)

    def test_delete_repo(self) -> None:
        self._call("POST", "/repos",
                   {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        code, _ = self._call("DELETE", "/repos/lib-a")
        self.assertEqual(code, 200)
        code, _ = self._call("DELETE", "/repos/lib-a")
        self.assertEqual(code, 404)

    def test_add_and_list_deps(self) -> None:
        self._call("POST", "/repos",
                   {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        self._call("POST", "/repos",
                   {"id": "app-b", "url": "https://x.com/b", "version": "1.0.0"})
        code, _ = self._call("POST", "/deps",
                              {"consumer": "app-b", "provider": "lib-a"})
        self.assertEqual(code, 201)
        code, data = self._call("GET", "/deps")
        self.assertEqual(code, 200)
        self.assertEqual(data["deps"], [{"consumer": "app-b", "provider": "lib-a"}])

    def test_add_dep_bad_consumer_400(self) -> None:
        code, _ = self._call("POST", "/deps",
                              {"consumer": "ghost", "provider": "lib-a"})
        self.assertEqual(code, 400)

    def test_delete_dep(self) -> None:
        self._call("POST", "/repos",
                   {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        self._call("POST", "/repos",
                   {"id": "app-b", "url": "https://x.com/b", "version": "1.0.0"})
        self._call("POST", "/deps", {"consumer": "app-b", "provider": "lib-a"})
        code, _ = self._call("DELETE", "/deps/app-b/lib-a")
        self.assertEqual(code, 200)
        code, _ = self._call("DELETE", "/deps/app-b/lib-a")
        self.assertEqual(code, 404)

    def test_publish_event_and_list(self) -> None:
        self._call("POST", "/repos",
                   {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        self._call("POST", "/repos",
                   {"id": "app-b", "url": "https://x.com/b", "version": "1.0.0"})
        self._call("POST", "/deps", {"consumer": "app-b", "provider": "lib-a"})
        code, data = self._call("POST", "/events",
                                 {"type": "api_change", "repo_id": "lib-a",
                                  "payload": {"detail": "foo renamed"}})
        self.assertEqual(code, 201)
        self.assertIn("event_id", data)
        self.assertEqual(data["notified"], ["app-b"])

        code, data = self._call("GET", "/events")
        self.assertEqual(code, 200)
        self.assertEqual(len(data["events"]), 1)

    def test_publish_event_invalid_type_400(self) -> None:
        self._call("POST", "/repos",
                   {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        code, _ = self._call("POST", "/events",
                              {"type": "bad_type", "repo_id": "lib-a", "payload": {}})
        self.assertEqual(code, 400)

    def test_publish_event_unknown_repo_404(self) -> None:
        code, _ = self._call("POST", "/events",
                              {"type": "api_change", "repo_id": "ghost", "payload": {}})
        self.assertEqual(code, 404)

    def test_ack_event(self) -> None:
        self._call("POST", "/repos",
                   {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        self._call("POST", "/repos",
                   {"id": "app-b", "url": "https://x.com/b", "version": "1.0.0"})
        self._call("POST", "/deps", {"consumer": "app-b", "provider": "lib-a"})
        _, ev = self._call("POST", "/events",
                           {"type": "api_change", "repo_id": "lib-a", "payload": {}})
        eid = ev["event_id"]
        code, _ = self._call("POST", f"/events/{eid}/ack", {"repo_id": "app-b"})
        self.assertEqual(code, 200)

    def test_ack_event_not_in_notified_404(self) -> None:
        self._call("POST", "/repos",
                   {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        _, ev = self._call("POST", "/events",
                           {"type": "api_change", "repo_id": "lib-a", "payload": {}})
        eid = ev["event_id"]
        code, _ = self._call("POST", f"/events/{eid}/ack", {"repo_id": "lib-a"})
        self.assertEqual(code, 404)

    def test_version_update(self) -> None:
        self._call("POST", "/repos",
                   {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        code, _ = self._call("POST", "/version",
                              {"repo_id": "lib-a", "version": "2.0.0"})
        self.assertEqual(code, 200)
        _, data = self._call("GET", "/repos")
        repo = next(r for r in data["repos"] if r["id"] == "lib-a")
        self.assertEqual(repo["version"], "2.0.0")

    def test_version_update_unknown_404(self) -> None:
        code, _ = self._call("POST", "/version",
                              {"repo_id": "ghost", "version": "2.0.0"})
        self.assertEqual(code, 404)

    def test_manifest(self) -> None:
        self._call("POST", "/repos",
                   {"id": "lib-a", "url": "https://x.com", "version": "1.0.0"})
        code, data = self._call("GET", "/manifest")
        self.assertEqual(code, 200)
        self.assertIn("repos", data)
        self.assertIn("deps", data)
        self.assertIn("pending_events", data)

    def test_status(self) -> None:
        code, data = self._call("GET", "/status")
        self.assertEqual(code, 200)
        self.assertIn("repos", data)
        self.assertIn("deps", data)
        self.assertIn("events", data)
        self.assertIn("unacked", data)

    def test_404_unknown_path(self) -> None:
        code, _ = self._call("GET", "/unknown")
        self.assertEqual(code, 404)

    def test_invalid_json_body_400(self) -> None:
        import urllib.request
        url = f"http://127.0.0.1:{self.port}/repos"
        req = urllib.request.Request(url, data=b"not-json", method="POST",
                                     headers={"Content-Type": "application/json",
                                              "Content-Length": "8"})
        import urllib.error
        try:
            urllib.request.urlopen(req)
            self.fail("Expected HTTP error")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 400)


if __name__ == "__main__":
    unittest.main()
