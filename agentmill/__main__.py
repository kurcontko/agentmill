import sys

from .cli import main

raise SystemExit(main(launcher=(sys.executable, "-m", "agentmill")))
