"""A bounded, checked runner for native coding CLIs."""

__version__ = "0.1.0"

from .contracts import Check, RunOutcome, RunSpec
from .runner import run, verify

__all__ = ["Check", "RunSpec", "RunOutcome", "run", "verify"]
