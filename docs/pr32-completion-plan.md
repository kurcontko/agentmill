# PR #32 completion plan

Scope: finish the reliable execution foundation. Report, durable resume, and
first-run packaging follow after this PR; they are not merge requirements here.

## Required changes and evidence

- [x] Explicit outcomes: separate agent claims from verified completion; write a
  versioned terminal record; propagate documented nonzero outcomes through the
  foreground CLI. Cover rejected claims, absent verification, limits, errors,
  setup failure, and cancellation.
- [x] Initialization and rejection recovery: record the verifier baseline;
  preserve strictly metadata-only initialization on a red baseline; support
  direct implementation; retain rejected patches and bounded verifier feedback
  outside rollback. Prove implementation starts and feedback reaches the next
  worker after rollback.
- [x] Run identity: allocate collision-free run directories before setup, record
  original HEAD and sanitized configuration/policy/runtime metadata, retain
  checkpoints, and make CLI log lookup run-aware. Prove repeated invocations
  cannot overwrite or mix evidence. No resume command in this PR.
- [x] Limits and accounting: consistent setup/session/check/run deadlines and
  cleanup, role-specific usage, unknown-cost semantics, remaining-budget limits,
  and review reserve. Prove hanging setup cannot start a worker and insufficient
  allowance cannot start another paid session.
- [x] Regression and documentation: preserve runtime-safety coverage; update
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

Accounting now preserves empty TSV fields, preventing absent subtype/usage
values from shifting into other columns.

At `59f73db`, the Linux shell, Docker build, packaged reviewer, supervisor,
confinement, DinD, and security checks passed. The advisory external model review
was still running when checked.

Run-identity implementation adds per-run directories under XDG state, an
exclusive manifest, original mission/policy snapshots, checkpoint events, image
and packaged CLI metadata, and explicit/latest/legacy CLI log lookup. Local
identity, recovery, outcome, CLI and loop regressions pass (the alias-path
fixture was corrected and its remaining suite rerun). Linux packaged checks
must run on this change before its checklist item is complete.

The Scorecard workflow from merged PR #31 is restored unchanged. The positioning
document now states the actual implementation and its limits, with no unsupported
competitor or performance claims.

Limits/accounting implementation adds role-specific session records, explicit
unknown and estimated cost states, remaining Claude session allowances with a
review reserve, and setup/session/check/total deadlines. A fixed supervisor
backstop bounds the packaged worker without expanding its command interface.
Local accounting (5 tests), worker-deadline (3 tests), limits, CLI, and full loop
regressions pass. The GNU-only setup deadline still requires Linux CI.

At `311e6a2`, packaged reviewer checks passed, but DinD failed: its host CLI
fixture used a foreign worker UID with the new private host-owned run directory.
The fixture now maps the worker UID as `mill build` does on Linux, keeps state
inside its disposable directory, and reads the new paths on failure. Separate
cross-UID reviewer tests are unchanged. This fix needs Docker CI validation.

## Completion audit

At `d06ff4c`, CI run `34042290481` passed every step: ShellCheck, all loop/CLI
and dedicated contract suites, Linux confinement, Python compilation, Docker
build, packaged reviewer/ownership and CLI smoke tests, concurrent DinD lifecycle,
and supervisor RPC/deadline checks. The DinD fixture fix is verified. CodeQL,
dependency review, secret scanning, Actions analysis, and all Trivy jobs passed.

| Requirement | Acceptance evidence |
| --- | --- |
| Truthful completion and terminal exits | `tests/test_outcomes.sh`, loop completion/review cases, CLI exit propagation cases |
| Red-baseline repair can start | `tests/test_recovery.sh`: retained metadata advances to implementation; mixed code/planning is still rejected |
| Rejection survives rollback | Recovery test checks retained patch/output and injected next-worker feedback |
| Collision-free run evidence | `tests/test_run_state.py`: same-HEAD repeated runs preserve every earlier file; reused ID is rejected; CLI explicit/latest/legacy lookup cases |
| Unknown and role-specific usage | `tests/test_accounting.py` and `tests/test_limits.sh`: reviewer included, missing/estimated amounts distinct, unknown total remains null |
| Remaining allowance prevents new paid work | Limit fixtures inspect worker/reviewer launch caps, reserve, insufficient allowance, and unknown-cost blocking |
| Bounded setup and total lifecycle | Linux setup timeout, total deadline during setup/backoff, worker deadline unit cases, packaged supervisor deadline checks |
| Existing runtime boundaries | Packaged reviewer/ownership, Landlock, supervisor, and concurrent DinD tests unchanged in purpose and passing |
| Accurate guarantees | README, positioning, and CLAUDE guidance distinguish endpoint verification, CLI-dependent monetary limits, and non-tamper-proof evidence |

PR #32 targets main, is mergeable, and now has a title/body describing the actual
scope rather than the initial small-loop design. The final documentation-only
commit still needs its own green CI head before handoff. No real-provider task
trials or comparative benchmarks were run; report/resume/onboarding and empirical
product evaluation remain follow-up work. No merge has been performed.
