"""Exercise the shipped entrypoint with a fake Claude executable and real git."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, pathlib, signal, subprocess, sys, time
mode = os.environ.get("FAKE_MODE", "done")
assert "--json-schema" in sys.argv and "--output-format" in sys.argv
assert "--continue" not in sys.argv and "--resume" not in sys.argv
assert "Test mission" in sys.argv[sys.argv.index("-p") + 1]
pathlib.Path(os.environ["FAKE_STARTED"]).touch()
if mode == "hang":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen([sys.executable, "-c",
        "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(120)"])
    pathlib.Path(os.environ["FAKE_CHILD"]).write_text(str(child.pid))
    time.sleep(120)
progress = pathlib.Path("PROGRESS.md")
iteration = int(progress.read_text()) + 1 if progress.exists() else 1
progress.write_text(str(iteration))
if mode == "bad_check":
    pathlib.Path("fail").touch()
if mode != "dirty":
    subprocess.run(["git", "add", "."], check=True)
    subprocess.run(["git", "commit", "-qm", "progress"], check=True)
if mode == "malformed":
    print("TASK_COMPLETE")
else:
    done = mode != "limit" and (mode != "two_sessions" or iteration == 2)
    reply = {"done": "true" if mode == "bad_schema" else done, "summary": "Worked"}
    print(json.dumps({"type": "result", "subtype": "success", "is_error": mode == "error",
                      "structured_output": reply}))
sys.exit(1 if mode == "crash" else 0)
'''


class BasicLoopTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo with spaces"
        self.repo.mkdir()
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        claude = self.bin / "claude"
        claude.write_text(FAKE_CLAUDE)
        claude.chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.root / "home"),
                    "AUTO_SETUP": "true", "REPO_SETUP_COMMAND": "", "EXTRA_PYTHON_TOOLS": "",
                    "PATH": f"{self.bin}:{os.environ['PATH']}", "CHECK_CMD": "test ! -f fail",
                    "FAKE_STARTED": str(self.root / "started"), "FAKE_CHILD": str(self.root / "child")}
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            self.env.pop(key, None)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.com")
        (self.repo / "MILL.md").write_text("Test mission: implement the feature.\n")
        self.git("add", ".")
        self.git("commit", "-qm", "mission")
        self.initial = self.git("rev-parse", "HEAD")
        self.runner = self.root / "runner.py"
        self.runner.write_text(
            f"import sys\nsys.path.insert(0, {str(ROOT)!r})\n"
            "from pathlib import Path\nimport basic_loop\n"
            f"raise SystemExit(basic_loop.main(Path({str(self.repo)!r}), Path({str(self.logs)!r}), "
            f"Path({str(ROOT / 'setup-repo-env.sh')!r})))\n"
        )

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, env=self.env, text=True).strip()

    def argv(self, timeout=10):
        command = [sys.executable, "-I"]
        if os.environ.get("AGENTMILL_TEST_COVERAGE") == "1":
            command += ["-m", "coverage", "run"]
        return [*command, str(self.runner), "--iterations", "2", "--timeout", str(timeout)]

    def run_loop(self, mode="done", check=None, timeout=10):
        self.env["FAKE_MODE"] = mode
        if check is not None:
            self.env["CHECK_CMD"] = check
        result = subprocess.run(self.argv(timeout), env=self.env, capture_output=True, text=True, timeout=20)
        outcome = json.loads((self.logs / "outcome.json").read_text())
        self.assertEqual(result.returncode, outcome["exit_code"], result.stdout + result.stderr)
        return outcome

    def test_complete_requires_check_at_recorded_commit(self):
        outcome = self.run_loop()
        self.assertEqual(outcome["exit_code"], 0)
        self.assertEqual(outcome["reason"], "verified_complete")
        self.assertEqual(outcome["checked_commit"], self.git("rev-parse", "HEAD"))
        self.assertNotEqual(outcome["checked_commit"], self.initial)
        self.assertTrue((self.logs / "baseline.log").exists())

    def test_setup_activates_tools_for_checks_and_agent(self):
        tools = self.root / "installed-tools"
        tools.mkdir()
        tool = tools / "fixture-check"
        tool.write_text('#!/bin/sh\nexit 0\n')
        tool.chmod(0o755)
        self.env["TOOLS_DIR"] = str(tools)
        self.env["REPO_SETUP_COMMAND"] = 'export PATH="$TOOLS_DIR:$PATH"'
        outcome = self.run_loop(check="fixture-check")
        self.assertEqual(outcome["exit_code"], 0)
        self.assertTrue((self.logs / "setup.log").exists())

    def test_setup_failure_stops_before_baseline_or_agent(self):
        self.env["REPO_SETUP_COMMAND"] = "exit 7"
        outcome = self.run_loop()
        self.assertEqual(outcome["reason"], "setup_failed")
        self.assertFalse((self.logs / "baseline.log").exists())
        self.assertFalse((self.root / "started").exists())

    def test_setup_timeout_is_bounded(self):
        self.env["REPO_SETUP_COMMAND"] = "sleep 60"
        outcome = self.run_loop(timeout=1)
        self.assertEqual(outcome["reason"], "setup_timeout")
        self.assertFalse((self.root / "started").exists())

    def test_setup_cannot_silently_dirty_the_checkout(self):
        self.env["REPO_SETUP_COMMAND"] = "touch unexpected"
        outcome = self.run_loop()
        self.assertEqual(outcome["reason"], "dirty_checkout")
        self.assertFalse((self.root / "started").exists())

    def test_fresh_sessions_use_committed_handoff(self):
        outcome = self.run_loop("two_sessions")
        self.assertEqual(outcome["exit_code"], 0)
        self.assertEqual(outcome["iterations"], 2)
        self.assertEqual((self.repo / "PROGRESS.md").read_text(), "2")

    def test_limit_is_not_success_even_with_passing_checks(self):
        outcome = self.run_loop("limit")
        self.assertEqual(outcome["exit_code"], 2)
        self.assertEqual(outcome["reason"], "iteration_limit")

    def test_rejected_completion_preserves_work(self):
        outcome = self.run_loop("bad_check")
        self.assertEqual(outcome["exit_code"], 1)
        self.assertEqual(outcome["reason"], "check-1_failed")
        self.assertTrue(outcome["agent_claimed_done"])
        self.assertIsNone(outcome["checked_commit"])
        self.assertTrue((self.repo / "fail").exists())
        self.assertNotEqual(self.git("rev-parse", "HEAD"), self.initial)

    def test_red_baseline_never_starts_agent(self):
        outcome = self.run_loop(check="exit 7")
        self.assertEqual(outcome["reason"], "baseline_failed")
        self.assertFalse((self.root / "started").exists())

    def test_dirty_start_preserves_changes(self):
        (self.repo / "mine").write_text("my work")
        outcome = self.run_loop()
        self.assertEqual(outcome["reason"], "dirty_checkout")
        self.assertFalse((self.root / "started").exists())
        self.assertEqual((self.repo / "mine").read_text(), "my work")

    def test_dirty_agent_result_is_preserved_and_rejected(self):
        outcome = self.run_loop("dirty")
        self.assertEqual(outcome["reason"], "dirty_checkout")
        self.assertIsNone(outcome["checked_commit"])
        self.assertTrue((self.repo / "PROGRESS.md").exists())

    def test_unhealthy_and_malformed_results_cannot_complete(self):
        for mode in ("error", "crash", "malformed", "bad_schema"):
            with self.subTest(mode=mode):
                outcome = self.run_loop(mode)
                self.assertEqual(outcome["exit_code"], 1)
                self.assertIsNone(outcome["checked_commit"])

    def test_verifier_cannot_change_checked_commit(self):
        outcome = self.run_loop(check="git commit --allow-empty -qm unexpected")
        self.assertEqual(outcome["reason"], "verifier_changed_commit")
        self.assertFalse((self.root / "started").exists())

    def test_verifier_timeout(self):
        outcome = self.run_loop(check="sleep 120", timeout=1)
        self.assertEqual(outcome["reason"], "baseline_timeout")

    def assert_child_stopped(self):
        pid = (self.root / "child").read_text()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            state = subprocess.run(["ps", "-o", "stat=", "-p", pid], capture_output=True, text=True)
            if not state.stdout.strip() or state.stdout.strip().startswith("Z"):
                return
            time.sleep(0.05)
        self.fail(f"Child {pid} survived cleanup")

    def test_worker_timeout_kills_term_resistant_descendants(self):
        outcome = self.run_loop("hang", timeout=1)
        self.assertEqual(outcome["reason"], "session-1_timeout")
        self.assert_child_stopped()

    def test_signal_cancellation_kills_descendants_and_records_outcome(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                (self.root / "child").unlink(missing_ok=True)
                process = subprocess.Popen(self.argv(), env={**self.env, "FAKE_MODE": "hang"},
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    deadline = time.monotonic() + 5
                    while not (self.root / "child").exists():
                        self.assertIsNone(process.poll())
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.05)
                    process.send_signal(signum)
                    self.assertEqual(process.wait(timeout=8), 128 + signum)
                    outcome = json.loads((self.logs / "outcome.json").read_text())
                    self.assertEqual(outcome["reason"], "cancelled")
                    self.assert_child_stopped()
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait()

    def test_cli_launch_contract_and_repeated_run_directories(self):
        if os.getuid() == 0:
            self.skipTest("host launcher intentionally requires a non-root user")
        docker = self.bin / "docker"
        docker.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                          "open(os.environ['DOCKER_ARGS'], 'w').write(json.dumps(sys.argv[1:]))\n"
                          "sys.exit(2)\n")
        docker.chmod(0o755)
        harness = self.root / "harness"
        harness.mkdir()
        shutil.copy(ROOT / "mill", harness / "mill")
        (harness / ".env").write_text("AGENTMILL_IMAGE=agentmill:symlink-test\nMODEL=config-model\n")
        installed = self.bin / "mill"
        installed.symlink_to("../harness/mill")
        captured = self.root / "docker.json"
        env = {**self.env, "DOCKER_ARGS": str(captured), "XDG_STATE_HOME": str(self.root / "state")}
        env["MODEL"] = "shell-model"
        env.pop("AGENTMILL_IMAGE", None)
        command = ["bash", str(harness / "mill"), "run", str(self.repo),
                   "--check", "test ! -f fail", "--iterations", "2"]
        for executable in (harness / "mill", installed):
            command[1] = str(executable)
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
        args = json.loads(captured.read_text())
        self.assertIn(f"type=bind,src={self.repo.resolve()},dst=/workspace", args)
        self.assertIn("no-new-privileges", args)
        self.assertIn("GIT_CONFIG_VALUE_0=/workspace", args)
        self.assertIn("ANTHROPIC_API_KEY", args)
        self.assertIn("/basic_loop.py", args)
        self.assertIn("agentmill:symlink-test", args)
        self.assertEqual(args[-1], "shell-model")
        self.assertNotIn("--privileged", args)
        self.assertEqual(len(list((self.root / "state/agentmill/runs").iterdir())), 2)
        captured.unlink()
        result = subprocess.run(command + ["--iterations", "0"], env=env, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(captured.exists())
        result = subprocess.run(["bash", str(installed), "build"], env=env, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(Path(json.loads(captured.read_text())[-1]).resolve(), harness.resolve())
        captured.unlink()
        result = subprocess.run(["bash", str(harness / "mill"), "run", str(self.repo), "--basic"],
                                env=env, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(captured.exists())

    def test_basic_init_creates_mission_and_preserves_existing_work(self):
        harness = self.root / "harness"
        harness.mkdir()
        shutil.copy(ROOT / "mill", harness / "mill")
        mission = self.repo / "MILL.md"
        mission.unlink()
        command = ["bash", str(harness / "mill"), "init", str(self.repo)]
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, check=True)
        self.assertIn("Acceptance criteria", mission.read_text())
        self.assertIn("Next: mill run", result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)
        self.assertFalse((harness / ".env").exists())
        self.assertFalse((harness / "prompts").exists())
        mission.write_text("My existing mission\n")
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, check=True)
        self.assertIn("Keeping existing mission", result.stdout)
        self.assertEqual(mission.read_text(), "My existing mission\n")


if __name__ == "__main__":
    unittest.main()
