"""Run evidence must survive repeated invocations and retain its original policy."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RunIdentityTests(unittest.TestCase):
    def test_repeated_runs_preserve_evidence_and_original_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, logs, home, binary = [root / name for name in ("repo", "logs", "home", "bin")]
            for directory in (repo, logs, home, binary):
                directory.mkdir()
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (repo / "MILL.md").write_text("Repair the widget\n")
            subprocess.run(["git", "-C", str(repo), "add", "MILL.md"], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=test", "-c",
                            "user.email=test@example.com", "commit", "-qm", "baseline"], check=True)
            baseline = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            (root / "prompt").write_text("Do the task\n")
            worker = binary / "claude"
            worker.write_text("#!/usr/bin/env bash\n"
                              "[[ ${1:-} != --help ]] || exit 0\n"
                              "printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\","
                              "\"is_error\":false,\"num_turns\":3,\"result\":\"TASK_COMPLETE\"}'\n")
            worker.chmod(0o755)
            environment = dict(os.environ, HOME=str(home), PATH=f"{binary}:{os.environ['PATH']}",
                               REPO_DIR=str(repo), LOG_DIR=str(logs), PROMPT_FILE=str(root / "prompt"),
                               ANTHROPIC_API_KEY="secret-must-not-be-recorded", CHECK_CMD="true",
                               MAX_ITERATIONS="1", LOOP_DELAY="0", ERROR_BACKOFF="0")
            first = None
            for _ in range(2):
                result = subprocess.run(["bash", str(ROOT / "loop.sh")], env=environment,
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                current = (logs / "latest").resolve()
                manifest = json.loads((current / "manifest.json").read_text())
                self.assertEqual(manifest["original_commit"], baseline)
                self.assertEqual(manifest["configuration"]["CHECK_CMD"], "true")
                self.assertEqual(len(manifest["mission_sha256"]), 64)
                self.assertEqual(len(manifest["policy_sha256"]), 64)
                self.assertNotIn("secret-must-not-be-recorded", (current / "manifest.json").read_text())
                self.assertEqual(len((current / "results.jsonl").read_text().splitlines()), 1)
                if first is None:
                    first = current
                    preserved = {p.name: p.read_bytes() for p in current.iterdir() if p.is_file()}
                else:
                    self.assertNotEqual(first, current)
                    for name, contents in preserved.items():
                        self.assertEqual((first / name).read_bytes(), contents, name)
            self.assertEqual(len(list(logs.glob("*/manifest.json"))), 3)  # two runs plus latest link

    def test_supplied_run_id_cannot_reinitialize_existing_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            command = ["python3", str(ROOT / "run_state.py"), "init", temporary,
                       temporary, str(Path(temporary) / "missing-mission"), "--run-id", "run-test-123"]
            subprocess.run(command, check=True, capture_output=True)
            manifest = (Path(temporary) / "manifest.json").read_bytes()
            second = subprocess.run(command, capture_output=True)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual((Path(temporary) / "manifest.json").read_bytes(), manifest)


if __name__ == "__main__":
    unittest.main()
