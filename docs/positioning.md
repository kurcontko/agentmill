# AgentMill's boundary

AgentMill is a small, checked job runner around native coding CLIs.

> Give a native coding agent a task, a private workspace, and a bounded
> opportunity to work. Capture its changes, run your checks, and return an
> honest result.

## The product

One run has one pinned source revision, one task, one selected agent backend,
one private working checkout, and a bounded number of native sessions. Native
CLIs decide how to do the work. AgentMill decides how long they may work,
preserves what they produced, checks it, and reports what happened.

The useful increment over calling a CLI directly is:

- bounded continuation with failed-check feedback;
- source checkout protection and runner-owned candidate snapshots;
- separate check environments tied to exact candidate revisions;
- retained native evidence, patches and bundles;
- explicit, machine-readable terminal outcomes.

The integration boundary is `RunSpec -> run -> RunOutcome`. A scheduler can use
one session per run, consume JSONL events, inspect artifacts, and pass a candidate
into another run. No graph engine or HTTP API is needed in this layer.

## Honest completion

`checked_complete` means a successful native session claimed completion and the
configured checks passed on the captured candidate. It does not prove that the
checks are sufficient or independent of the agent's changes to repository tests.

Authoritative records and snapshots belong to the supervisor. Checks run in fresh
containers without supplied agent credentials. This separation supports reliable
reporting; it does not justify a universal correctness or adversarial-proof claim.

## Deliberately outside the core

An ADE or other caller owns planning, graphs, task boards, human approvals,
independent acceptance tests, model review, and merging or publishing results.
There is no mandatory auditor, provider SDK, shared agent memory, daemon,
database, plugin marketplace, or universal spend-accounting system.

Native usage and cost estimates are retained with their provenance. Hard common
limits are session count and elapsed time. Unknown usage is never reported as
zero. A failing baseline can be repaired; failed candidates and unfinished work
are preserved without being presented as complete.

## Development priorities

Maintain two thin adapters against the same lifecycle contract. Prioritize
correct cancellation, exact candidate capture, check provenance, and artifact
portability over adding providers or orchestration features. Pin packaged CLI
versions and test their native protocol, permission profile, and Docker lifecycle.

The acceptance scenario is a dirty source checkout left untouched while a failing
committed baseline is repaired across sessions, without requiring agent commits.
The exported artifact must reconstruct the recorded passing candidate exactly.
