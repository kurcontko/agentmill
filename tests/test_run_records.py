"""Record helper contracts without depending on the replacement runner."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "run_state.py"


class RunRecordTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def command(self, *arguments):
        return subprocess.run(
            ["python3", str(HELPER), *map(str, arguments)],
            capture_output=True, text=True, check=False,
        )

    def test_initialization_preserves_prior_evidence(self):
        mission = self.root / "mission"
        mission.write_text("Repair the widget\n")
        logs = self.root / "logs"
        paths = []
        for _ in range(2):
            result = self.command("init", logs, self.root, mission)
            self.assertEqual(result.returncode, 0, result.stderr)
            paths.append(Path(result.stdout.strip()))
        self.assertNotEqual(paths[0], paths[1])
        first = json.loads((paths[0] / "manifest.json").read_text())
        self.assertEqual(first["schema_version"], 1)
        self.assertEqual(len(first["mission_sha256"]), 64)
        self.assertEqual((paths[0] / "artifacts/mission-at-start.md").read_text(),
                         "Repair the widget\n")
        self.assertEqual((logs / "latest").resolve(), paths[1])

    def test_supplied_id_cannot_reset_existing_run(self):
        logs = self.root / "logs"
        arguments = ("init", logs, self.root, self.root / "missing",
                     "--run-id", "run-record-test")
        self.assertEqual(self.command(*arguments).returncode, 0)
        original = (logs / "manifest.json").read_bytes()
        self.assertNotEqual(self.command(*arguments).returncode, 0)
        self.assertEqual((logs / "manifest.json").read_bytes(), original)

    def test_completion_requires_acceptance_evidence(self):
        outcome = self.root / "outcome.json"
        result = self.command(outcome, "run-test", 0, "verified_completion",
                              "true", "failed", "not_run", "abc", 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(outcome.exists())
        result = self.command(outcome, "run-test", 2, "iteration_limit",
                              "true", "passed", "needs_work", "abc", 1)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(outcome.read_text())
        self.assertEqual(record["completion"], "incomplete")
        self.assertTrue(record["agent_claimed_done"])
        self.assertEqual(record["exit_code"], 2)


if __name__ == "__main__":
    unittest.main()
