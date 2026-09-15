"""Exercise mill -> packaged Docker entrypoint, without provider credentials."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

from test_basic_loop import FAKE_CLAUDE, ROOT


def main():
    image = f"agentmill-basic-test:{uuid.uuid4().hex}"
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        # Exercise the launcher without loading the developer's real .env.
        shutil.copy(ROOT / "mill", root / "mill")
        fake = FAKE_CLAUDE.replace('os.environ.get("FAKE_MODE", "done")',
                                  'pathlib.Path("mode").read_text().strip()')
        fake = fake.replace('os.environ["FAKE_STARTED"]', '"/logs/started"')
        fake = fake.replace('os.environ["FAKE_CHILD"]', '"/logs/child"')
        (root / "claude").write_text(fake)
        (root / "claude").chmod(0o755)
        base_image = os.environ.get("AGENTMILL_SMOKE_IMAGE", "agentmill:ci")
        (root / "Dockerfile").write_text(f"FROM {base_image}\nCOPY claude /usr/local/bin/claude\n")
        subprocess.run(["docker", "build", "-t", image, str(root)], check=True)
        try:
            setup_repo = root / "setup-checkout"
            (setup_repo / ".venv").mkdir(parents=True)
            marker = setup_repo / ".venv/host-marker"
            marker.write_text("keep host environment")
            (setup_repo / "pyproject.toml").write_text(
                '[project]\nname="fixture"\nversion="0.1.0"\nrequires-python=">=3.11"\n'
                '[project.optional-dependencies]\ndev=[]\n[dependency-groups]\nci=[]\n'
            )
            subprocess.run([
                "docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}",
                "--mount", f"type=bind,src={setup_repo},dst=/workspace",
                "--env", "HOME=/tmp/setup-home", "--workdir", "/workspace",
                "--entrypoint", "bash", image, "-ec",
                'uv lock --offline; . /setup-repo-env.sh "$PWD"; '
                'test "$(command -v python)" = "$UV_PROJECT_ENVIRONMENT/bin/python"',
            ], check=True)
            assert marker.read_text() == "keep host environment"
            repo = root / "checkout"
            repo.mkdir()
            for name in ("pyproject.toml", "uv.lock"):
                shutil.copy(setup_repo / name, repo / name)
            (repo / ".gitignore").write_text(".venv/\n")
            (repo / ".venv").mkdir()
            host_marker = repo / ".venv/host-marker"
            host_marker.write_text("keep host environment")
            for args in (("init", "-q", "-b", "main"), ("config", "user.name", "Test"),
                         ("config", "user.email", "test@example.com")):
                subprocess.run(["git", "-C", str(repo), *args], check=True)
            (repo / "MILL.md").write_text("Test mission: update the handoff and commit.\n")
            env = {**os.environ, "AGENTMILL_IMAGE": image, "XDG_STATE_HOME": str(root / "state"),
                   "AUTO_SETUP": "true", "REPO_SETUP_COMMAND": "", "EXTRA_PYTHON_TOOLS": "",
                   "ANTHROPIC_API_KEY": "", "CLAUDE_CODE_OAUTH_TOKEN": ""}
            for mode, expected in (("done", 0), ("hang", 143), ("bad_check", 1)):
                (repo / "mode").write_text(mode)
                subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
                subprocess.run(["git", "-C", str(repo), "commit", "-qm", mode], check=True)
                command = ["bash", str(root / "mill"), "run", str(repo),
                           "--check", 'test "$(command -v python)" = "$UV_PROJECT_ENVIRONMENT/bin/python" && test ! -f fail',
                           "--iterations", "2", "--timeout", "15"]
                process = subprocess.Popen(command, env=env)
                try:
                    if mode == "hang":
                        deadline = time.monotonic() + 20
                        while not list((root / "state").glob("agentmill/runs/*/child")):
                            if process.poll() is not None or time.monotonic() > deadline:
                                raise AssertionError("packaged worker did not start")
                            time.sleep(0.1)
                        process.send_signal(signal.SIGTERM)
                    assert process.wait(timeout=30) == expected, mode
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait()
                outcomes = list((root / "state").glob("agentmill/runs/*/outcome.json"))
                latest = max(outcomes, key=lambda path: path.stat().st_mtime_ns)
                outcome = json.loads(latest.read_text())
                assert outcome["exit_code"] == expected, outcome
                assert host_marker.read_text() == "keep host environment"
                assert "uv sync --frozen --extra dev" in (latest.parent / "setup.log").read_text()
                if mode == "done":
                    head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
                    assert outcome["checked_commit"] == head, outcome
                container = f"agentmill-{latest.parent.name}"
                exists = subprocess.run(["docker", "inspect", container], capture_output=True)
                assert exists.returncode != 0, "run container survived exit"
            assert len(outcomes) == 3, "runs overwrote each other's evidence"
            assert (repo / "fail").exists(), "failed candidate was discarded"
            print("Packaged basic-loop completion, rejection, and cancellation passed.")
        finally:
            # These resources belong only to this fixture image.
            containers = subprocess.check_output(
                ["docker", "ps", "-aq", "--filter", f"ancestor={image}"], text=True).split()
            if containers:
                subprocess.run(["docker", "rm", "-f", *containers], check=True)
            subprocess.run(["docker", "image", "rm", image], check=True)


if __name__ == "__main__":
    main()
