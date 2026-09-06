"""Usage and launch allowance are derived from role-specific evidence."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / "run_state.py"


class AccountingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def command(self, *arguments):
        return subprocess.check_output(["python3", str(HELPER), *map(str, arguments)], text=True).strip()

    def record(self, role, cost):
        metrics = self.root / "metrics"
        metrics.write_text(f"\tfalse\t{cost}\t3\t10\t12\t4\n")
        self.command("session", self.root, "1", role, "claude", metrics, "2", "0")
        return json.loads((self.root / "accounting.json").read_text())

    def test_roles_and_missing_fields_are_preserved(self):
        self.record("worker", "0.10")
        totals = self.record("reviewer", "0.05")
        self.assertAlmostEqual(totals["reported_cost_usd"], .15)
        self.assertEqual(totals["roles"]["reviewer"]["reported_cost_usd"], .05)
        rows = [json.loads(line) for line in (self.root / "sessions.jsonl").read_text().splitlines()]
        self.assertEqual(rows[0]["turns"], 3)
        self.assertEqual(rows[0]["tokens_in"], 12)
        self.assertEqual(rows[1]["duration_s"], 2)

    def test_unknown_is_not_zero_and_blocks_a_capped_next_session(self):
        totals = self.record("worker", "")
        self.assertIsNone(totals["total_cost_usd"])
        self.assertEqual(totals["unknown_sessions"], 1)
        self.assertEqual(self.command("allowance", self.root, "1", "", "0.5", "reviewer", "claude"), "cost_unknown")
        self.assertEqual(self.command("allowance", self.root, "", "", "0.5", "worker", "claude"), "allowed:")

    def test_remaining_budget_and_review_reserve_clamp_each_role(self):
        self.assertEqual(self.command("allowance", self.root, "1", "", "0.5", "worker", "claude"), "allowed:0.5")
        self.record("worker", "0.5")
        self.assertEqual(self.command("allowance", self.root, "1", "", "0.5", "worker", "claude"), "budget_limit")
        self.assertEqual(self.command("allowance", self.root, "1", "", "0.5", "reviewer", "claude"), "allowed:0.5")
        self.assertEqual(self.command("allowance", self.root, "1", "0.2", "0.5", "reviewer", "claude"), "allowed:0.2")

    def test_explicit_zero_and_unsupported_monetary_limits(self):
        totals = self.record("worker", "0")
        self.assertEqual(totals["total_cost_usd"], 0)
        self.assertEqual(totals["unknown_sessions"], 0)
        self.assertEqual(self.command("allowance", self.root, "1", "", "0", "worker", "codex"), "cost_unsupported")
        self.assertEqual(self.command("allowance", self.root, "0", "", "0", "worker", "claude"), "budget_limit")

    def test_estimated_usage_is_not_reported_as_known_spend(self):
        metrics = self.root / "metrics"
        metrics.write_text("success\tfalse\t0.5\t3\t0\t12\t4\n")
        self.command("session", self.root, "1", "worker", "claude", metrics, "2", "0", "estimated")
        totals = json.loads((self.root / "accounting.json").read_text())
        self.assertEqual(totals["reported_cost_usd"], 0)
        self.assertEqual(totals["estimated_cost_usd"], .5)
        self.assertEqual(totals["cost_state"], "estimated")
        self.assertIsNone(totals["total_cost_usd"])
        self.assertEqual(self.command("allowance", self.root, "1", "", "0", "worker", "claude"), "cost_unknown")


if __name__ == "__main__":
    unittest.main()
