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
        self.worker = self.root / "worker"
        self.logs = self.root / "logs"
        self.helper = extract_shell_function(Path("entrypoint.sh"), "push_branch_with_retries")

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

        run(["git", "clone", str(self.origin), str(self.worker)], cwd=self.root)
        run(["git", "checkout", "agent-1"], cwd=self.worker)
        run(["git", "config", "user.name", "Test User"], cwd=self.worker)
        run(["git", "config", "user.email", "test@example.com"], cwd=self.worker)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def make_worker_commit(self, message: str) -> None:
        target = self.worker / "change.txt"
        target.write_text(f"{message}\n")
        run(["git", "add", "change.txt"], cwd=self.worker)
        run(["git", "commit", "-m", message], cwd=self.worker)

    def run_helper(self) -> subprocess.CompletedProcess[str]:
        script = textwrap.dedent(
            f"""
            set -euo pipefail
            PUSH_REBASE_MAX_RETRIES=3
            AGENT_ID=1
            LOG_DIR="{self.logs}"
            mkdir -p "$LOG_DIR"

            log() {{
                printf '%s\\n' "$*"
            }}

            {self.helper}

            cd "{self.worker}"
            if push_branch_with_retries agent-1 3; then
                exit 0
            fi
            exit 1
            """
        )
        return subprocess.run(["bash", "-lc", script], capture_output=True, text=True)

    def test_stops_after_three_failed_retries(self) -> None:
        self.make_worker_commit("reject me")
        hook = self.origin / "hooks" / "pre-receive"
        hook.write_text("#!/usr/bin/env bash\nexit 1\n")
        hook.chmod(0o755)

        result = self.run_helper()

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("Push failed, rebasing and retrying"), 3)
        self.assertIn("ERROR: push failed after 3 retries", result.stdout)

    def test_returns_success_without_retries_when_push_works(self) -> None:
        self.make_worker_commit("allow me")

        result = self.run_helper()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Push failed, rebasing and retrying", result.stdout)
        self.assertNotIn("ERROR: push failed after 3 retries", result.stdout)


if __name__ == "__main__":
    unittest.main()
