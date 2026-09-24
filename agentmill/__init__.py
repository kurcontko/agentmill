"""A bounded, checked runner for native coding CLIs."""

__version__ = "0.1.0"

from .contracts import RunOutcome, RunSpec
from .runner import run

__all__ = ["RunSpec", "RunOutcome", "run"]
