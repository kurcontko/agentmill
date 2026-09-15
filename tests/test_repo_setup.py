import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RepoSetupTests(unittest.TestCase):
    def test_uv_environment_is_activated_without_using_host_venv(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            repo.mkdir()
            (repo / "pyproject.toml").write_text('[project]\nname="fixture"\nversion="0.1"\n')
            (repo / "uv.lock").touch()
            host = repo / ".venv"
            host.mkdir()
            (host / "marker").write_text("host environment")
            environment = root / "container-venv"
            (environment / "bin").mkdir(parents=True)
            uv = root / "uv"
            uv.write_text('#!/bin/sh\nexit 0\n')
            uv.chmod(0o755)
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                   "UV_PROJECT_ENVIRONMENT": str(environment), "AUTO_SETUP": "true",
                   "REPO_SETUP_COMMAND": "", "EXTRA_PYTHON_TOOLS": ""}
            result = subprocess.run(["bash", "-c", '. "$1" "$2"; printf "%s\\n" "$PATH"',
                                     "_", str(ROOT / "setup-repo-env.sh"), str(repo)],
                                    env=env, check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.splitlines()[-1].split(":")[0], str(environment / "bin"))
            self.assertEqual((host / "marker").read_text(), "host environment")

    def test_uv_selects_dev_only_from_its_own_table(self):
        cases = [
            ('[project.optional-dependencies]\ndev=[]\n[dependency-groups]\nci=[]\n',
             ["--extra", "dev"]),
            ('[project.optional-dependencies]\ntui=[]\n[dependency-groups]\ndev=[]\n',
             ["--group", "dev"]),
            ('[project.optional-dependencies]\n"dev"=[]\n[dependency-groups]\ndev=[]\n',
             ["--extra", "dev", "--group", "dev"]),
            ('[project.optional-dependencies]\ntui=[]\n[dependency-groups]\nci=[]\n[tool.other]\ndev=true\n',
             []),
        ]
        for project, flags in cases:
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "pyproject.toml").write_text(project)
                (root / "uv.lock").touch()
                binary = root / "bin"
                binary.mkdir()
                uv = binary / "uv"
                uv.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$UV_CALLS"\n')
                uv.chmod(0o755)
                calls = root / "uv.calls"
                env = {**os.environ, "PATH": f"{binary}:{os.environ['PATH']}",
                       "UV_CALLS": str(calls), "AUTO_SETUP": "true",
                       "REPO_SETUP_COMMAND": "", "EXTRA_PYTHON_TOOLS": ""}
                subprocess.run(["bash", str(ROOT / "setup-repo-env.sh"), str(root)],
                               env=env, check=True, capture_output=True, text=True)
                self.assertEqual(calls.read_text().splitlines(), ["sync", "--frozen", *flags])
