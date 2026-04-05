import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "setup-claude-config.sh"


class SetupClaudeConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory(prefix="setup-claude-config-")
        self.root = Path(self.tmpdir.name)
        self.home = self.root / "home"
        self.host = self.root / "host"
        (self.home / ".claude").mkdir(parents=True)
        self.host.mkdir()

        for name in ("plugins", "skills", "agents"):
            (self.host / name).mkdir()

    def tearDown(self) -> None:
        self.tmpdir.cleanup()

    def write_script_fixture(self) -> Path:
        script_text = SCRIPT_PATH.read_text()
        replacements = {
            "/home/agent/.host-claude.json": str(self.host / "host-claude.json"),
            "/home/agent/.claude/settings.host.json": str(self.host / "settings.host.json"),
            "/home/agent/.claude/settings.json": str(self.home / ".claude" / "settings.json"),
            "/home/agent/.host-plugins": str(self.host / "plugins"),
            "/home/agent/.claude/plugins": str(self.home / ".claude" / "plugins"),
            "/home/agent/.host-skills": str(self.host / "skills"),
            "/home/agent/.claude/skills": str(self.home / ".claude" / "skills"),
            "/home/agent/.host-agents": str(self.host / "agents"),
            "/home/agent/.claude/agents": str(self.home / ".claude" / "agents"),
        }
        for old, new in replacements.items():
            script_text = script_text.replace(old, new)

        fixture = self.root / "setup-claude-config.sh"
        fixture.write_text(script_text)
        fixture.chmod(0o755)
        return fixture

    def run_script(self) -> subprocess.CompletedProcess[str]:
        fixture = self.write_script_fixture()
        return subprocess.run(
            ["bash", str(fixture)],
            cwd=REPO_ROOT,
            env={**os.environ, "HOME": str(self.home)},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_malformed_host_claude_config_does_not_skip_settings_merge(self) -> None:
        (self.host / "host-claude.json").write_text("{bad json\n")
        (self.host / "settings.host.json").write_text(
            json.dumps(
                {
                    "permissions": {"allow": ["Bash"]},
                    "enabledPlugins": ["demo-plugin"],
                    "hooks": {"PostToolUse": []},
                    "env": {"FOO": "BAR"},
                }
            )
        )

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.home / ".claude.json").exists())
        settings = json.loads((self.home / ".claude" / "settings.json").read_text())
        self.assertEqual(settings["permissions"]["defaultMode"], "bypassPermissions")
        self.assertIn("Bash", settings["permissions"]["allow"])
        self.assertEqual(settings["enabledPlugins"], ["demo-plugin"])
        self.assertEqual(settings["hooks"], {"PostToolUse": []})
        self.assertEqual(settings["env"], {"FOO": "BAR"})


if __name__ == "__main__":
    unittest.main()
