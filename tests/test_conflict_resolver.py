"""
Tests for conflict_resolver.py — Smart Merge Conflict Resolution.
"""
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
import conflict_resolver


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_store(tmp: str) -> conflict_resolver.ConflictStore:
    return conflict_resolver.ConflictStore(os.path.join(tmp, "state.json"))


def start_server(store: conflict_resolver.ConflictStore, port: int) -> HTTPServer:
    class _H(conflict_resolver.Handler):
        pass
    _H.store = store
    server = HTTPServer(("127.0.0.1", port), _H)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


def http(method: str, port: int, path: str,
         body: dict | None = None, retries: int = 3) -> tuple[int, dict]:
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    last_exc: Exception | None = None
    for attempt in range(retries):
        req = urllib.request.Request(url, data=data, method=method)
        if data:
            req.add_header("Content-Type", "application/json")
            req.add_header("Content-Length", str(len(data)))
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())
        except Exception as exc:
            last_exc = exc
            time.sleep(0.05 * (attempt + 1))
    raise last_exc


_PORT_BASE = 10200

# Sample conflict texts

WHITESPACE_CONFLICT = """\
line before
<<<<<<< HEAD
foo = 1

=======
foo = 1
>>>>>>> feature
line after
"""

IMPORT_CONFLICT = """\
<<<<<<< HEAD
import os
import sys
=======
import os
import json
>>>>>>> feature
"""

VERSION_CONFLICT = """\
<<<<<<< HEAD
version = "1.2.3"
=======
version = "1.3.0"
>>>>>>> feature
"""

ADDITIVE_CONFLICT = """\
<<<<<<< HEAD
def foo():
    pass
=======
def bar():
    pass
>>>>>>> feature
"""

NO_CONFLICT = """\
just normal content
no conflict markers here
"""

UNRESOLVABLE_CONFLICT = """\
<<<<<<< HEAD
x = complex_expression_a() + more_stuff
y = something_else()
=======
x = complex_expression_b()
y = something_entirely_different()
>>>>>>> feature
"""


# ---------------------------------------------------------------------------
# parse_conflicts
# ---------------------------------------------------------------------------

class TestParseConflicts(unittest.TestCase):

    def test_no_conflicts(self):
        result = conflict_resolver.parse_conflicts(NO_CONFLICT)
        self.assertEqual(result, [])

    def test_single_conflict(self):
        blocks = conflict_resolver.parse_conflicts(WHITESPACE_CONFLICT)
        self.assertEqual(len(blocks), 1)
        b = blocks[0]
        self.assertIn("ours", b)
        self.assertIn("theirs", b)
        self.assertIn("start", b)
        self.assertIn("end", b)

    def test_ours_and_theirs_labels(self):
        blocks = conflict_resolver.parse_conflicts(IMPORT_CONFLICT)
        self.assertEqual(blocks[0]["ours_label"], "HEAD")
        self.assertEqual(blocks[0]["theirs_label"], "feature")

    def test_multiple_conflicts(self):
        text = IMPORT_CONFLICT + "\n" + VERSION_CONFLICT
        blocks = conflict_resolver.parse_conflicts(text)
        self.assertEqual(len(blocks), 2)

    def test_diff3_style(self):
        text = (
            "<<<<<<< HEAD\n"
            "a = 1\n"
            "||||||| base\n"
            "a = 0\n"
            "=======\n"
            "a = 2\n"
            ">>>>>>> branch\n"
        )
        blocks = conflict_resolver.parse_conflicts(text)
        self.assertEqual(len(blocks), 1)
        self.assertIn("a = 0", blocks[0]["base"])


# ---------------------------------------------------------------------------
# classify_conflict
# ---------------------------------------------------------------------------

class TestClassifyConflict(unittest.TestCase):

    def _block(self, ours, theirs, base=""):
        return {"ours": ours, "theirs": theirs, "base": base}

    def test_identical_content(self):
        b = self._block("x = 1\n", "x = 1\n")
        strategy, conf = conflict_resolver.classify_conflict(b)
        self.assertEqual(strategy, "take_ours")
        self.assertAlmostEqual(conf, 1.0)

    def test_whitespace_only(self):
        b = self._block("x = 1\n\n", "x = 1\n")
        strategy, conf = conflict_resolver.classify_conflict(b)
        self.assertIn(strategy, ("take_ours", "take_theirs"))
        self.assertGreater(conf, 0.9)

    def test_ours_empty(self):
        b = self._block("", "some content\n")
        strategy, conf = conflict_resolver.classify_conflict(b)
        self.assertEqual(strategy, "take_theirs")
        self.assertAlmostEqual(conf, 1.0)

    def test_theirs_empty(self):
        b = self._block("some content\n", "")
        strategy, conf = conflict_resolver.classify_conflict(b)
        self.assertEqual(strategy, "take_ours")
        self.assertAlmostEqual(conf, 1.0)

    def test_import_conflict(self):
        blocks = conflict_resolver.parse_conflicts(IMPORT_CONFLICT)
        strategy, conf = conflict_resolver.classify_conflict(blocks[0])
        self.assertEqual(strategy, "merge_imports")
        self.assertGreater(conf, 0.85)

    def test_version_conflict(self):
        blocks = conflict_resolver.parse_conflicts(VERSION_CONFLICT)
        strategy, conf = conflict_resolver.classify_conflict(blocks[0])
        self.assertEqual(strategy, "take_higher_version")
        self.assertGreater(conf, 0.75)

    def test_additive_functions(self):
        blocks = conflict_resolver.parse_conflicts(ADDITIVE_CONFLICT)
        strategy, conf = conflict_resolver.classify_conflict(blocks[0])
        self.assertIn(strategy, ("append_both",))
        self.assertGreater(conf, 0.5)

    def test_unresolvable_is_split_task(self):
        blocks = conflict_resolver.parse_conflicts(UNRESOLVABLE_CONFLICT)
        strategy, conf = conflict_resolver.classify_conflict(blocks[0])
        self.assertEqual(strategy, "split_task")
        self.assertAlmostEqual(conf, 0.0)

    def test_non_overlapping_additions(self):
        b = self._block("alpha = 1\nbeta = 2\n", "gamma = 3\ndelta = 4\n", base="")
        strategy, conf = conflict_resolver.classify_conflict(b)
        self.assertEqual(strategy, "append_both")
        self.assertGreater(conf, 0.7)


# ---------------------------------------------------------------------------
# apply_strategy
# ---------------------------------------------------------------------------

class TestApplyStrategy(unittest.TestCase):

    def _block(self, ours, theirs, base=""):
        return {"ours": ours, "theirs": theirs, "base": base}

    def test_take_ours(self):
        b = self._block("a\n", "b\n")
        result = conflict_resolver.apply_strategy(b, "take_ours")
        self.assertEqual(result, "a\n")

    def test_take_theirs(self):
        b = self._block("a\n", "b\n")
        result = conflict_resolver.apply_strategy(b, "take_theirs")
        self.assertEqual(result, "b\n")

    def test_merge_imports_sorted(self):
        b = self._block("import sys\nimport os\n", "import json\nimport os\n")
        result = conflict_resolver.apply_strategy(b, "merge_imports")
        self.assertIsNotNone(result)
        lines = result.splitlines()
        self.assertIn("import sys", lines)
        self.assertIn("import json", lines)
        self.assertIn("import os", lines)
        # no duplicates
        self.assertEqual(len(lines), len(set(lines)))
        # sorted
        self.assertEqual(lines, sorted(lines))

    def test_take_higher_version_theirs_wins(self):
        b = self._block('version = "1.2.3"\n', 'version = "1.3.0"\n')
        result = conflict_resolver.apply_strategy(b, "take_higher_version")
        self.assertIn("1.3.0", result)

    def test_take_higher_version_ours_wins(self):
        b = self._block('version = "2.0.0"\n', 'version = "1.9.9"\n')
        result = conflict_resolver.apply_strategy(b, "take_higher_version")
        self.assertIn("2.0.0", result)

    def test_append_both(self):
        b = self._block("part_a\n", "part_b\n")
        result = conflict_resolver.apply_strategy(b, "append_both")
        self.assertIn("part_a", result)
        self.assertIn("part_b", result)

    def test_split_task_returns_none(self):
        b = self._block("complex a\n", "complex b\n")
        result = conflict_resolver.apply_strategy(b, "split_task")
        self.assertIsNone(result)


# ---------------------------------------------------------------------------
# resolve_file_content
# ---------------------------------------------------------------------------

class TestResolveFileContent(unittest.TestCase):

    def test_no_conflict(self):
        result = conflict_resolver.resolve_file_content(NO_CONFLICT)
        self.assertTrue(result["resolved"])
        self.assertEqual(result["unresolved_count"], 0)
        self.assertEqual(result["content"], NO_CONFLICT)

    def test_whitespace_resolved(self):
        result = conflict_resolver.resolve_file_content(WHITESPACE_CONFLICT)
        self.assertTrue(result["resolved"])
        self.assertEqual(result["unresolved_count"], 0)
        self.assertNotIn("<<<<<<<", result["content"])

    def test_import_resolved(self):
        result = conflict_resolver.resolve_file_content(IMPORT_CONFLICT)
        self.assertTrue(result["resolved"])
        self.assertNotIn("<<<<<<<", result["content"])
        # Both imports present
        self.assertIn("import sys", result["content"])
        self.assertIn("import json", result["content"])

    def test_version_resolved(self):
        result = conflict_resolver.resolve_file_content(VERSION_CONFLICT)
        self.assertTrue(result["resolved"])
        self.assertIn("1.3.0", result["content"])
        self.assertNotIn("<<<<<<<", result["content"])

    def test_additive_resolved(self):
        result = conflict_resolver.resolve_file_content(ADDITIVE_CONFLICT)
        self.assertTrue(result["resolved"])
        self.assertIn("def foo", result["content"])
        self.assertIn("def bar", result["content"])

    def test_unresolvable(self):
        result = conflict_resolver.resolve_file_content(UNRESOLVABLE_CONFLICT)
        self.assertFalse(result["resolved"])
        self.assertGreater(result["unresolved_count"], 0)

    def test_multiple_blocks_mixed(self):
        text = IMPORT_CONFLICT + "\n" + UNRESOLVABLE_CONFLICT
        result = conflict_resolver.resolve_file_content(text)
        # Import block resolved, unresolvable stays
        self.assertFalse(result["resolved"])
        self.assertEqual(result["unresolved_count"], 1)
        strategies = result["strategies"]
        resolved_strats = [s for s in strategies if s["resolved"]]
        self.assertTrue(resolved_strats)

    def test_content_preserves_surrounding_text(self):
        text = "header\n" + IMPORT_CONFLICT + "footer\n"
        result = conflict_resolver.resolve_file_content(text)
        self.assertIn("header", result["content"])
        self.assertIn("footer", result["content"])

    def test_strategies_list_length(self):
        text = IMPORT_CONFLICT + "\n" + VERSION_CONFLICT
        result = conflict_resolver.resolve_file_content(text)
        self.assertEqual(len(result["strategies"]), 2)


# ---------------------------------------------------------------------------
# ConflictStore
# ---------------------------------------------------------------------------

class TestConflictStore(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_empty_store(self):
        store = make_store(self.tmp)
        self.assertEqual(store.aggregate()["total"], 0)

    def test_add_and_get(self):
        store = make_store(self.tmp)
        rec = {
            "resolution_id": "abc123",
            "branch": "feat",
            "base_branch": "main",
            "repo_path": "/repo",
            "state": "resolved",
            "resolved_files": ["a.py"],
            "unresolved_files": [],
            "strategies": {},
            "subtasks": [],
            "created_at": time.time(),
        }
        store.add_resolution(rec)
        got = store.get_resolution("abc123")
        self.assertIsNotNone(got)
        self.assertEqual(got["branch"], "feat")

    def test_persistence(self):
        store = make_store(self.tmp)
        rec = {
            "resolution_id": "persist1",
            "branch": "b",
            "base_branch": "main",
            "repo_path": "/r",
            "state": "partial",
            "resolved_files": [],
            "unresolved_files": ["x.py"],
            "strategies": {},
            "subtasks": [],
            "created_at": time.time(),
        }
        store.add_resolution(rec)
        # Reload
        store2 = make_store(self.tmp)
        got = store2.get_resolution("persist1")
        self.assertIsNotNone(got)

    def test_list_pending(self):
        store = make_store(self.tmp)
        for rid, state in [("r1", "partial"), ("r2", "resolved"), ("r3", "unresolved")]:
            store.add_resolution({
                "resolution_id": rid,
                "branch": "b",
                "base_branch": "main",
                "repo_path": "/r",
                "state": state,
                "resolved_files": [],
                "unresolved_files": [],
                "strategies": {},
                "subtasks": [],
                "created_at": time.time(),
            })
        pending = store.list_pending()
        rids = {r["resolution_id"] for r in pending}
        self.assertIn("r1", rids)
        self.assertIn("r3", rids)
        self.assertNotIn("r2", rids)

    def test_record_subtask_increments_count(self):
        store = make_store(self.tmp)
        store.add_resolution({
            "resolution_id": "rid1",
            "branch": "b",
            "base_branch": "main",
            "repo_path": "/r",
            "state": "partial",
            "resolved_files": [],
            "unresolved_files": ["f.py"],
            "strategies": {},
            "subtasks": [],
            "created_at": time.time(),
        })
        store.record_subtask("rid1", "f.py", {"subtask_file": "/t/st.md", "subtask_slug": "s"})
        agg = store.aggregate()
        self.assertEqual(agg["subtasks_created"], 1)

    def test_get_missing_returns_none(self):
        store = make_store(self.tmp)
        self.assertIsNone(store.get_resolution("nope"))

    def test_aggregate_counts(self):
        store = make_store(self.tmp)
        for i, state in enumerate(["resolved", "resolved", "partial", "unresolved"]):
            store.add_resolution({
                "resolution_id": str(i),
                "branch": "b",
                "base_branch": "main",
                "repo_path": "/r",
                "state": state,
                "resolved_files": [],
                "unresolved_files": [],
                "strategies": {},
                "subtasks": [],
                "created_at": time.time(),
            })
        agg = store.aggregate()
        self.assertEqual(agg["total"], 4)
        self.assertEqual(agg["resolved"], 2)
        self.assertEqual(agg["partial"], 1)
        self.assertEqual(agg["unresolved"], 1)


# ---------------------------------------------------------------------------
# create_subtask
# ---------------------------------------------------------------------------

class TestCreateSubtask(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_creates_file(self):
        meta = conflict_resolver.create_subtask(
            file_path="src/foo.py",
            resolution_id="rid123",
            branch="feat",
            base_branch="main",
            strategies=[{"strategy": "split_task", "confidence": 0.0, "resolved": False}],
            repo_path=self.tmp,
        )
        self.assertIn("subtask_file", meta)
        self.assertTrue(Path(meta["subtask_file"]).exists())

    def test_file_content_includes_instructions(self):
        meta = conflict_resolver.create_subtask(
            file_path="lib/bar.py",
            resolution_id="rid456",
            branch="feat2",
            base_branch="main",
            strategies=[],
            repo_path=self.tmp,
        )
        content = Path(meta["subtask_file"]).read_text()
        self.assertIn("lib/bar.py", content)
        self.assertIn("feat2", content)
        self.assertIn("git add", content)

    def test_slug_is_filesystem_safe(self):
        meta = conflict_resolver.create_subtask(
            file_path="path/to/some file.py",
            resolution_id="rid789",
            branch="b",
            base_branch="main",
            strategies=[],
            repo_path=self.tmp,
        )
        slug = meta["subtask_slug"]
        self.assertNotIn(" ", slug)
        self.assertNotIn("/", slug)


# ---------------------------------------------------------------------------
# HTTP API tests
# ---------------------------------------------------------------------------

class TestHTTPAnalyze(unittest.TestCase):
    port = _PORT_BASE

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.store = make_store(cls.tmp)
        cls.server = start_server(cls.store, cls.port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_analyze_whitespace(self):
        code, body = http("POST", self.port, "/analyze",
                          {"conflict_text": WHITESPACE_CONFLICT})
        self.assertEqual(code, 200)
        self.assertTrue(body["resolved"])
        self.assertNotIn("<<<<<<<", body["content"])

    def test_analyze_imports(self):
        code, body = http("POST", self.port, "/analyze",
                          {"conflict_text": IMPORT_CONFLICT})
        self.assertEqual(code, 200)
        self.assertEqual(body["strategy"], "merge_imports")
        self.assertTrue(body["resolved"])

    def test_analyze_version(self):
        code, body = http("POST", self.port, "/analyze",
                          {"conflict_text": VERSION_CONFLICT})
        self.assertEqual(code, 200)
        self.assertEqual(body["strategy"], "take_higher_version")

    def test_analyze_unresolvable(self):
        code, body = http("POST", self.port, "/analyze",
                          {"conflict_text": UNRESOLVABLE_CONFLICT})
        self.assertEqual(code, 200)
        self.assertFalse(body["resolved"])

    def test_analyze_no_conflict(self):
        code, body = http("POST", self.port, "/analyze",
                          {"conflict_text": NO_CONFLICT})
        self.assertEqual(code, 200)
        self.assertTrue(body["resolved"])

    def test_analyze_missing_body(self):
        code, body = http("POST", self.port, "/analyze", {})
        self.assertEqual(code, 400)


class TestHTTPResolve(unittest.TestCase):
    port = _PORT_BASE + 1

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.store = make_store(cls.tmp)
        cls.server = start_server(cls.store, cls.port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def _make_conflicted_file(self, content: str) -> str:
        """Write a conflicted file to tmp dir, return relative path."""
        fpath = os.path.join(self.tmp, "conflict_test.py")
        with open(fpath, "w") as fh:
            fh.write(content)
        return "conflict_test.py"

    def test_resolve_no_branch_returns_400(self):
        code, body = http("POST", self.port, "/resolve", {"base_branch": "main"})
        self.assertEqual(code, 400)

    def test_resolve_with_files_override_resolved(self):
        self._make_conflicted_file(IMPORT_CONFLICT)
        code, body = http("POST", self.port, "/resolve", {
            "branch": "feat",
            "base_branch": "main",
            "repo_path": self.tmp,
            "files": ["conflict_test.py"],
        })
        self.assertEqual(code, 201)
        self.assertTrue(body["ok"])
        self.assertIn("resolution_id", body)
        # File was auto-resolved → should be in resolved_files
        self.assertIn("conflict_test.py", body["resolved_files"])
        self.assertEqual(body["unresolved_files"], [])

    def test_resolve_with_unresolvable_file(self):
        fpath = os.path.join(self.tmp, "hard.py")
        with open(fpath, "w") as fh:
            fh.write(UNRESOLVABLE_CONFLICT)
        code, body = http("POST", self.port, "/resolve", {
            "branch": "feat",
            "base_branch": "main",
            "repo_path": self.tmp,
            "files": ["hard.py"],
        })
        self.assertEqual(code, 201)
        self.assertIn("hard.py", body["unresolved_files"])

    def test_resolve_mixed_files(self):
        # easy: import conflict, hard: unresolvable
        easy = os.path.join(self.tmp, "easy.py")
        hard = os.path.join(self.tmp, "hard2.py")
        with open(easy, "w") as fh:
            fh.write(IMPORT_CONFLICT)
        with open(hard, "w") as fh:
            fh.write(UNRESOLVABLE_CONFLICT)
        code, body = http("POST", self.port, "/resolve", {
            "branch": "feat",
            "base_branch": "main",
            "repo_path": self.tmp,
            "files": ["easy.py", "hard2.py"],
        })
        self.assertEqual(code, 201)
        self.assertEqual(body["state"], "partial")
        self.assertIn("easy.py", body["resolved_files"])
        self.assertIn("hard2.py", body["unresolved_files"])

    def test_resolve_state_persisted(self):
        fpath = os.path.join(self.tmp, "persist.py")
        with open(fpath, "w") as fh:
            fh.write(VERSION_CONFLICT)
        code, body = http("POST", self.port, "/resolve", {
            "branch": "version-branch",
            "base_branch": "main",
            "repo_path": self.tmp,
            "files": ["persist.py"],
        })
        self.assertEqual(code, 201)
        rid = body["resolution_id"]
        code2, body2 = http("GET", self.port, f"/status/{rid}")
        self.assertEqual(code2, 200)
        self.assertEqual(body2["branch"], "version-branch")


class TestHTTPSplit(unittest.TestCase):
    port = _PORT_BASE + 2

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.store = make_store(cls.tmp)
        cls.server = start_server(cls.store, cls.port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def _seed_resolution(self) -> str:
        """Create an unresolved resolution and return its id."""
        fpath = os.path.join(self.tmp, "unresolved.py")
        with open(fpath, "w") as fh:
            fh.write(UNRESOLVABLE_CONFLICT)
        code, body = http("POST", self.port, "/resolve", {
            "branch": "feat",
            "base_branch": "main",
            "repo_path": self.tmp,
            "files": ["unresolved.py"],
        })
        self.assertEqual(code, 201)
        return body["resolution_id"]

    def test_split_creates_subtask_file(self):
        rid = self._seed_resolution()
        code, body = http("POST", self.port, "/split", {
            "resolution_id": rid,
            "file_path": "unresolved.py",
        })
        self.assertEqual(code, 201)
        self.assertTrue(body["ok"])
        self.assertTrue(Path(body["subtask_file"]).exists())

    def test_split_missing_resolution_id(self):
        code, body = http("POST", self.port, "/split", {"file_path": "x.py"})
        self.assertEqual(code, 400)

    def test_split_unknown_resolution(self):
        code, body = http("POST", self.port, "/split", {
            "resolution_id": "nonexistent",
            "file_path": "x.py",
        })
        self.assertEqual(code, 404)

    def test_split_increments_subtask_count(self):
        rid = self._seed_resolution()
        before = http("GET", self.port, "/status")[1]["subtasks_created"]
        http("POST", self.port, "/split", {
            "resolution_id": rid,
            "file_path": "unresolved.py",
        })
        after = http("GET", self.port, "/status")[1]["subtasks_created"]
        self.assertEqual(after, before + 1)


class TestHTTPStatus(unittest.TestCase):
    port = _PORT_BASE + 3

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.store = make_store(cls.tmp)
        cls.server = start_server(cls.store, cls.port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_status_empty(self):
        code, body = http("GET", self.port, "/status")
        self.assertEqual(code, 200)
        self.assertIn("total", body)

    def test_status_id_not_found(self):
        code, _ = http("GET", self.port, "/status/missing")
        self.assertEqual(code, 404)

    def test_pending_empty(self):
        code, body = http("GET", self.port, "/pending")
        self.assertEqual(code, 200)
        self.assertIsInstance(body, list)

    def test_unknown_route(self):
        code, _ = http("GET", self.port, "/nonexistent")
        self.assertEqual(code, 404)


# ---------------------------------------------------------------------------
# Concurrent resolution test (no double-resolution)
# ---------------------------------------------------------------------------

class TestConcurrentResolve(unittest.TestCase):
    port = _PORT_BASE + 4

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.store = make_store(cls.tmp)
        cls.server = start_server(cls.store, cls.port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_concurrent_analyze_no_corruption(self):
        """20 threads simultaneously analyze; each should get a valid response."""
        results = []
        errors = []

        def worker(i):
            try:
                code, body = http("POST", self.port, "/analyze",
                                  {"conflict_text": IMPORT_CONFLICT})
                results.append((code, body["resolved"]))
            except Exception as exc:
                errors.append(str(exc))

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(len(errors), 0, f"Errors: {errors}")
        self.assertEqual(len(results), 20)
        # All should be resolved
        for code, resolved in results:
            self.assertEqual(code, 200)
            self.assertTrue(resolved)

    def test_concurrent_resolve_unique_ids(self):
        """20 threads submit resolve requests; each gets a unique resolution_id."""
        ids = []
        errors = []
        fpath = os.path.join(self.tmp, "concurrent.py")
        with open(fpath, "w") as fh:
            fh.write(IMPORT_CONFLICT)

        def worker(i):
            try:
                code, body = http("POST", self.port, "/resolve", {
                    "branch": f"feat-{i}",
                    "base_branch": "main",
                    "repo_path": self.tmp,
                    "files": ["concurrent.py"],
                })
                if code == 201:
                    ids.append(body["resolution_id"])
            except Exception as exc:
                errors.append(str(exc))

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(len(errors), 0, f"Errors: {errors}")
        # All IDs unique
        self.assertEqual(len(ids), len(set(ids)), "Duplicate resolution IDs found")


# ---------------------------------------------------------------------------
# make_server / compile check
# ---------------------------------------------------------------------------

class TestMakeServer(unittest.TestCase):

    def test_make_server_returns_httpserver(self):
        from http.server import HTTPServer
        import tempfile
        tmp = tempfile.mkdtemp()
        server = conflict_resolver.make_server(
            port=_PORT_BASE + 5,
            state_file=os.path.join(tmp, "state.json"),
        )
        self.assertIsInstance(server, HTTPServer)
        server.server_close()


if __name__ == "__main__":
    unittest.main()
