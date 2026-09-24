"""Source-checkout launcher; the checked loop now lives in agentmill.runner."""

from pathlib import Path
import sys

# The shell launcher uses -I to isolate supervisor imports from the caller.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentmill.cli import main

if __name__ == "__main__":
    raise SystemExit(main(launcher=(str(Path(__file__).resolve().with_name("mill")),)))
