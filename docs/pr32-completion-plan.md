# PR #32 completion plan

Scope: finish the reliable execution foundation. Report, durable resume, and
first-run packaging follow after this PR; they are not merge requirements here.

## Required changes and evidence

- [ ] Explicit outcomes: separate agent claims from verified completion; write a
  versioned terminal record; propagate documented nonzero outcomes through the
  foreground CLI. Cover rejected claims, absent verification, limits, errors,
  setup failure, and cancellation.
- [ ] Initialization and rejection recovery: record the verifier baseline;
  preserve strictly metadata-only initialization on a red baseline; support
  direct implementation; retain rejected patches and bounded verifier feedback
  outside rollback. Prove implementation starts and feedback reaches the next
  worker after rollback.
- [ ] Run identity: allocate collision-free run directories before setup, record
  original HEAD and sanitized configuration/policy/runtime metadata, retain
  checkpoints, and make CLI log lookup run-aware. Prove repeated invocations
  cannot overwrite or mix evidence. No resume command in this PR.
- [ ] Limits and accounting: consistent setup/session/check/run deadlines and
  cleanup, role-specific usage, unknown-cost semantics, remaining-budget limits,
  and review reserve. Prove hanging setup cannot start a worker and insufficient
  allowance cannot start another paid session.
- [ ] Regression and documentation: preserve runtime-safety coverage; update
  outcome, initialization, accounting, and endpoint-verification guarantees.
  Run ShellCheck, shell suites, Python checks, Docker/runtime integration,
  supervisor, confinement, DinD, and existing security workflows.
- [ ] PR hygiene: verify comparison with main, retarget #32 from the merged #31
  branch, update title/body to match final behavior, publish changes and verify
  required checks on the final head.

## Starting evidence

Local branch `lean/rewrite` was clean at `3c8d0fb`. GitHub confirmed #31 merged
and #32 open with base `chore/publish-readiness`; existing checks passed at that
head. This does not validate changes made afterward or real-provider tasks.

## Outcome contract

Exit 0 means verified completion. Exit 1 means failure; 2 incomplete at a limit;
3 blocked; 4 stop-file cancellation; 130/143 interrupt/termination cancellation.
Detached launch success acknowledges launch only. Abrupt process loss may leave
no terminal record and must never be inferred to mean completion.

Keep execution in the existing shell flow and extract new record serialization
incrementally into Python. Preserve the narrowly scoped reviewer supervisor.
No TUI, swarm coordination, vector memory, automatic merging, or generalized
provider framework.

## Implementation checkpoints

- `f86ac02`: outcome contract, terminal serialization, explicit expected exit
  codes in existing tests, dedicated outcome tests, CLI propagation tests.
- `9a0807b`: include the Python helper in Docker's allowlisted build context.
- PR #32 now targets `main`. Its old base has the same tree as main's #31 merge;
  no source changes needed reconciliation for the retarget.
- Recovery work adds baseline observations, a strictly metadata-only planning
  exception, direct-task instructions, candidate patches, and durable rejection
  feedback. The full loop suite and dedicated recovery/outcome tests pass
  locally, as does ShellCheck. CLI tests pass, including every outcome exit.

Remaining validation includes Linux-only deadlines, confinement, supervisor,
packaged runtime, and DinD in CI: this macOS host has no Docker daemon or GNU
timeout. The older CI ShellCheck reports SC2317 for callbacks invoked through
traps/dispatchers; this is now annotated without disabling the lint job.
At `9a0807b`, Linux shell tests and all security scans passed; packaged runtime
was skipped because the older ShellCheck needed that annotation. Rerun on the
recovery commit before considering those gates satisfied.

Accounting follow-up: the TSV parser uses whitespace IFS, which collapses empty
fields and can shift missing subtype/usage values into the wrong columns.
Preserve empty fields while implementing unknown-cost semantics.
