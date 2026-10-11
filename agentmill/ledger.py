"""Supervisor-owned acceptance ledger: which checks each candidate passes.

The best candidate passes the most checks without losing any check that the
previous best passed. Ties move forward to the newer candidate. Workers only see
a rendered copy in their prompt; this file lives in the supervisor's run directory.
"""

from .records import atomic_json


class Ledger:
    def __init__(self, checks, path):
        self.checks = checks
        self.path = path
        self.best = None
        self.best_passed = frozenset()
        self.latest = {}
        self.regressed = ()
        self.first_passed = {}
        self.history = []

    def record(self, session, candidate, results):
        """Record one complete check set. Returns True when the best set grew."""
        statuses = {check.id: "not_run" for check in self.checks}
        for check, result in zip(self.checks, results):
            statuses[check.id] = result["status"]
        passed = frozenset(name for name, status in statuses.items() if status == "passed")
        self.latest = statuses
        self.regressed = tuple(check.id for check in self.checks
                               if check.id in self.best_passed and check.id not in passed)
        grew = self.best is None or passed > self.best_passed
        if self.best is None or passed >= self.best_passed:
            self.best, self.best_passed = candidate, passed
        for name in sorted(passed):
            self.first_passed.setdefault(name, session)
        self.history.append({"session": session, "candidate_sha": candidate,
                             "passed": [c.id for c in self.checks if c.id in passed],
                             "regressed": list(self.regressed)})
        atomic_json(self.path, {"schema_version": 1, **self.summary(),
                                "checks": [{"id": c.id, "run": c.run, "describe": c.describe}
                                           for c in self.checks],
                                "history": self.history})
        return grew

    def summary(self):
        return {"total": len(self.checks), "best_candidate_sha": self.best,
                "best_passed": [c.id for c in self.checks if c.id in self.best_passed],
                "latest": dict(self.latest), "regressed": list(self.regressed),
                "first_passed_session": dict(self.first_passed)}

    def render(self):
        """The worker's read-only view: one line per check, then progress."""
        lines = []
        for check in self.checks:
            status = self.latest.get(check.id, "unchecked")
            text = f"- [{status}] {check.id}: {check.run}"
            if check.describe:
                text += f" -- {check.describe}"
            lines.append(text)
        if self.best is not None:
            lines.append(f"Best candidate so far passes {len(self.best_passed)}/{len(self.checks)} checks.")
        if self.regressed:
            lines.append("Regressed in the latest candidate (passed before, fail now): "
                         + ", ".join(self.regressed) + ". Restore them before new work.")
        return "\n".join(lines)
