"""Python wrapper for the AgentMill CLI.

The harness implementation lives in the repository's ``mill`` shell script.
This module provides a small zero-dependency subprocess wrapper so Python
automation can call the same surface without reimplementing behavior.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Mapping, Sequence


class Mill:
    """Call the local ``mill`` CLI from Python."""

    def __init__(self, root: str | os.PathLike[str] | None = None) -> None:
        self.root = Path(root).resolve() if root is not None else Path(__file__).resolve().parents[1]
        self.executable = self.root / "mill"

    def call(
        self,
        args: Sequence[str] = (),
        *,
        check: bool = False,
        capture_output: bool = False,
        text: bool = True,
        env: Mapping[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [str(self.executable), *map(str, args)]
        run_env = os.environ.copy()
        if env:
            run_env.update(env)
        return subprocess.run(
            command,
            cwd=self.root,
            check=check,
            capture_output=capture_output,
            text=text,
            env=run_env,
        )

    def run(self, *args: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
        return self.call(args, **kwargs)


def main(argv: Sequence[str] | None = None) -> int:
    import sys

    result = Mill().call(sys.argv[1:] if argv is None else argv)
    return result.returncode


__all__ = ["Mill", "main"]
