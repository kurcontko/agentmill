"""Supervisor-owned acceptance ledger: which checks each candidate passes.

The best candidate passes the most checks without losing any check that the
previous best passed. Ties move forward to the newer candidate. Workers only see
a rendered copy in their prompt; this file lives in the supervisor's run directory.

A check may name a number in its output with a `progress` pattern. A candidate that
raises that number has made progress even though no new check passes, and a tie on
passed checks moves the best candidate forward only when no such number fell.
"""

from pathlib import Path
import re

from .records import atomic_json


def measure(check, result):
    """The last number the check's progress pattern finds in its stdout, or None."""
    if not check.progress:
        return None
    try:
        found = re.findall(check.progress, Path(result["stdout"]).read_text(errors="replace"))
        return float(found[-1]) if found else None
    except (OSError, ValueError):
        return None


class Ledger:
    def __init__(self, checks, path, held_out=False):
        self.checks = checks
        # With a check directory, a check that reads /checks cannot be run by the worker.
        self.hidden = frozenset(check.id for check in checks if held_out and "/checks" in check.run)
        self.path = path
        self.best = None
        self.best_passed = frozenset()
        self.values = {}       # latest candidate's measured numbers, by check ID
        self.best_values = {}  # the best candidate's
        self.peak = {}         # the highest seen for each check
        self.latest = {}
        self.regressed = ()
        self.first_passed = {}
        self.history = []

    def record(self, session, candidate, results):
        """Record one complete check set. Returns True when the best set grew or a measured number rose."""
        statuses = {check.id: "not_run" for check in self.checks}
        values = {}
        for check, result in zip(self.checks, results):
            statuses[check.id] = result["status"]
            if (value := measure(check, result)) is not None:
                values[check.id] = value
        rose = any(value > self.peak[name] for name, value in values.items() if name in self.peak)
        for name, value in values.items():
            self.peak[name] = max(value, self.peak.get(name, value))
        self.values = values
        passed = frozenset(name for name, status in statuses.items() if status == "passed")
        self.latest = statuses
        self.regressed = tuple(check.id for check in self.checks
                               if check.id in self.best_passed and check.id not in passed)
        grew = self.best is None or passed > self.best_passed or rose
        # A candidate whose check no longer reports the number has not shown that it kept it.
        fell = any(name not in values or values[name] < value for name, value in self.best_values.items())
        if self.best is None or passed > self.best_passed or (passed == self.best_passed and not fell):
            self.best, self.best_passed, self.best_values = candidate, passed, values
        for name in sorted(passed):
            self.first_passed.setdefault(name, session)
        self.history.append({"session": session, "candidate_sha": candidate,
                             "passed": [c.id for c in self.checks if c.id in passed],
                             "regressed": list(self.regressed), "values": values})
        atomic_json(self.path, {"schema_version": 1, **self.summary(),
                                "checks": [{"id": c.id, "run": c.run, "describe": c.describe,
                                            "progress": c.progress} for c in self.checks],
                                "history": self.history})
        return grew

    def summary(self):
        return {"total": len(self.checks), "best_candidate_sha": self.best,
                "best_passed": [c.id for c in self.checks if c.id in self.best_passed],
                "latest": dict(self.latest), "regressed": list(self.regressed),
                "first_passed_session": dict(self.first_passed),
                "values": dict(self.values), "best_values": dict(self.best_values)}

    def render(self):
        """The worker's read-only view: one line per check, then progress."""
        lines = []
        for check in self.checks:
            status = self.latest.get(check.id, "unchecked")
            # Showing a command the worker cannot run invites it to try, fail and reply blocked.
            command = "held out; runs after your session" if check.id in self.hidden else check.run
            text = f"- [{status}] {check.id}: {command}"
            if check.describe:
                text += f" -- {check.describe}"
            if check.id in self.values:
                text += f" (measured {self.values[check.id]:g}, best so far {self.peak[check.id]:g})"
            lines.append(text)
        if self.best is not None:
            lines.append(f"Best candidate so far passes {len(self.best_passed)}/{len(self.checks)} checks.")
        if self.hidden:
            lines.append("Held-out checks use files you cannot see. Do not try to run them, and do not reply "
                         "blocked because they are unavailable; their results reach the next session.")
        if self.regressed:
            lines.append("Regressed in the latest candidate (passed before, fail now): "
                         + ", ".join(self.regressed) + ". Restore them before new work.")
        return "\n".join(lines)
