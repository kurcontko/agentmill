"""A bounded, checked runner for native coding CLIs."""

from .contracts import RunOutcome, RunSpec
from .runner import run

__all__ = ["RunSpec", "RunOutcome", "run"]
