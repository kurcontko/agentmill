"""Exercise mill -> packaged Docker entrypoint, without provider credentials."""

import json
import os
from pathlib import Path
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
        fake = FAKE_CLAUDE.replace('os.environ.get("FAKE_MODE", "done")',
                                  'pathlib.Path("mode").read_text().strip()')
        fake = fake.replace('os.environ["FAKE_STARTED"]', '"/logs/started"')
        fake = fake.replace('os.environ["FAKE_CHILD"]', '"/logs/child"')
        (root / "claude").write_text(fake)
        (root / "claude").chmod(0o755)
        (root / "Dockerfile").write_text("FROM agentmill:ci\nCOPY claude /usr/local/bin/claude\n")
        subprocess.run(["docker", "build", "-t", image, str(root)], check=True)
        try:
            repo = root / "checkout"
            repo.mkdir()
            for args in (("init", "-q", "-b", "main"), ("config", "user.name", "Test"),
                         ("config", "user.email", "test@example.com")):
                subprocess.run(["git", "-C", str(repo), *args], check=True)
            (repo / "MILL.md").write_text("Test mission: update the handoff and commit.\n")
            env = {**os.environ, "AGENTMILL_IMAGE": image, "XDG_STATE_HOME": str(root / "state"),
                   "ANTHROPIC_API_KEY": "", "CLAUDE_CODE_OAUTH_TOKEN": ""}
            for mode, expected in (("done", 0), ("hang", 143), ("bad_check", 1)):
                (repo / "mode").write_text(mode)
                subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
                subprocess.run(["git", "-C", str(repo), "commit", "-qm", mode], check=True)
                command = ["bash", str(ROOT / "mill"), "run", "--basic", str(repo),
                           "--check", "test ! -f fail", "--iterations", "2", "--timeout", "15"]
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
