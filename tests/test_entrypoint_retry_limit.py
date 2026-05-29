import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


def extract_shell_function(path: Path, function_name: str) -> str:
    lines = path.read_text().splitlines()
    function_lines: list[str] = []
    brace_depth = 0
    collecting = False

    for line in lines:
        if not collecting and line.startswith(f"{function_name}()"):
            collecting = True

        if not collecting:
            continue

        function_lines.append(line)
        brace_depth += line.count("{")
        brace_depth -= line.count("}")

        if collecting and brace_depth == 0:
            return "\n".join(function_lines) + "\n"

    raise ValueError(f"Function {function_name} not found in {path}")


class PushBranchWithRetriesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.origin = self.root / "origin.git"
        self.seed = self.root / "seed"
        self.logs = self.root / "logs"
        self.helper = (
            extract_shell_function(Path("entrypoint-common.sh"), "push_failure_is_retryable")
            + extract_shell_function(Path("entrypoint.sh"), "push_branch_with_retries")
        )

        run(["git", "init", "--bare", str(self.origin)], cwd=self.root)
        run(["git", "init", "-b", "main", str(self.seed)], cwd=self.root)
        run(["git", "config", "user.name", "Test User"], cwd=self.seed)
        run(["git", "config", "user.email", "test@example.com"], cwd=self.seed)

        (self.seed / "README.md").write_text("seed\n")
        run(["git", "add", "README.md"], cwd=self.seed)
        run(["git", "commit", "-m", "seed"], cwd=self.seed)
        run(["git", "remote", "add", "origin", str(self.origin)], cwd=self.seed)
        run(["git", "push", "origin", "main"], cwd=self.seed)
        run(["git", "checkout", "-b", "agent-1"], cwd=self.seed)
        run(["git", "push", "origin", "agent-1"], cwd=self.seed)
        run(["git", "symbolic-ref", "HEAD", "refs/heads/main"], cwd=self.origin)

        self.worker = self.clone_worker("worker")
        self.upstream_worker = self.clone_worker("upstream-worker")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def clone_worker(self, name: str) -> Path:
        worker = self.root / name
        run(["git", "clone", str(self.origin), str(worker)], cwd=self.root)
        run(["git", "checkout", "agent-1"], cwd=worker)
        run(["git", "config", "user.name", "Test User"], cwd=worker)
        run(["git", "config", "user.email", "test@example.com"], cwd=worker)
        return worker

    def make_commit(self, worker: Path, path: str, message: str, contents: str | None = None) -> None:
        target = worker / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents if contents is not None else f"{message}\n")
        run(["git", "add", path], cwd=worker)
        run(["git", "commit", "-m", message], cwd=worker)

    def make_worker_commit(self, message: str) -> None:
        self.make_commit(self.worker, "change.txt", message)

    def make_upstream_commit(self, message: str) -> None:
        self.make_commit(self.upstream_worker, "upstream.txt", message)
        run(["git", "push", "origin", "agent-1"], cwd=self.upstream_worker)

    def remote_file(self, path: str) -> str:
        return run(["git", "--git-dir", str(self.origin), "show", f"agent-1:{path}"], cwd=self.root).stdout

    def run_helper(self, worker: Path | None = None, retries: int = 3) -> subprocess.CompletedProcess[str]:
        worker = worker or self.worker
        script = textwrap.dedent(
            f"""
            set -euo pipefail
            PUSH_REBASE_MAX_RETRIES={retries}
            AGENT_ID=1
            LOG_DIR="{self.logs}"
            mkdir -p "$LOG_DIR"

            log() {{
                printf '%s\\n' "$*"
            }}

            enforce_git_remote_action_policy() {{
                return 0
            }}

            {self.helper}

            cd "{worker}"
            if push_branch_with_retries agent-1 {retries}; then
                exit 0
            fi
            exit 1
            """
        )
        return subprocess.run(["bash", "-lc", script], capture_output=True, text=True)

    def test_stops_retrying_on_permanent_push_failure(self) -> None:
        self.make_worker_commit("reject me")
        hook = self.origin / "hooks" / "pre-receive"
        hook.write_text("#!/usr/bin/env bash\nexit 1\n")
        hook.chmod(0o755)

        result = self.run_helper()

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("Push rejected, rebasing and retrying", result.stdout)
        self.assertIn("ERROR: git push failed permanently:", result.stdout)
        self.assertIn("remote rejected", result.stdout)

    def test_retries_non_fast_forward_failures(self) -> None:
        self.make_upstream_commit("upstream change")
        self.make_worker_commit("local change")

        result = self.run_helper()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("Push rejected, rebasing and retrying"), 1)
        self.assertNotIn("ERROR: git push failed permanently", result.stdout)

    def test_returns_success_without_retries_when_push_works(self) -> None:
        self.make_worker_commit("allow me")

        result = self.run_helper()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Push rejected, rebasing and retrying", result.stdout)
        self.assertNotIn("ERROR: push failed after 3 retries", result.stdout)

    def test_two_agents_push_same_branch_and_second_rebases_successfully(self) -> None:
        first_agent = self.clone_worker("first-agent")
        second_agent = self.clone_worker("second-agent")
        self.make_commit(first_agent, "first.txt", "first agent change")
        self.make_commit(second_agent, "second.txt", "second agent change")

        first_result = self.run_helper(first_agent)
        second_result = self.run_helper(second_agent)

        self.assertEqual(first_result.returncode, 0, first_result.stdout + first_result.stderr)
        self.assertEqual(second_result.returncode, 0, second_result.stdout + second_result.stderr)
        self.assertNotIn("Push rejected, rebasing and retrying", first_result.stdout)
        self.assertEqual(second_result.stdout.count("Push rejected, rebasing and retrying"), 1)
        self.assertEqual(self.remote_file("first.txt"), "first agent change\n")
        self.assertEqual(self.remote_file("second.txt"), "second agent change\n")

    def test_two_agents_conflict_and_second_fails_after_retry_limit(self) -> None:
        first_agent = self.clone_worker("conflict-first-agent")
        second_agent = self.clone_worker("conflict-second-agent")
        self.make_commit(first_agent, "shared.txt", "first conflict change", "first\n")
        self.make_commit(second_agent, "shared.txt", "second conflict change", "second\n")

        first_result = self.run_helper(first_agent, retries=2)
        second_result = self.run_helper(second_agent, retries=2)

        self.assertEqual(first_result.returncode, 0, first_result.stdout + first_result.stderr)
        self.assertEqual(second_result.returncode, 1, second_result.stdout + second_result.stderr)
        self.assertEqual(second_result.stdout.count("WARN: Rebase conflict on retry"), 2)
        self.assertIn("ERROR: push failed after 2 retries", second_result.stdout)
        self.assertEqual(self.remote_file("shared.txt"), "first\n")


if __name__ == "__main__":
    unittest.main()
