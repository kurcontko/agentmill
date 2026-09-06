# AgentMill: bounded tasks with reviewable evidence

The product direction is to make it easy to leave a bounded development task
running and return to a change that a developer can assess efficiently.

> Give AgentMill a task and a verification command. It works in an isolated
> checkout, preserves checked progress, and returns a diff, evidence, cost
> information, and an honest explanation of why it stopped.

This is the target experience, not a claim that every part is already shipped.
The current CLI runs against the selected checkout; a private checkout by
default, durable resume, and a consolidated report remain follow-up work.

## What the runtime already provides

AgentMill uses native Claude and Codex CLIs for implementation. It adds a
repeatable task handoff, verification at iteration endpoints, rollback of
rejected work, bounded cancellation, steering, and retained artifacts.

Completion claims are distinct from verified completion and process success.
Planning metadata can survive an initially failing verifier without accepting
unverified implementation. Rejection evidence survives rollback.

Optional review runs under a separate user in a disposable snapshot, with
Linux Landlock write confinement and a narrowly scoped root supervisor for
reviewer launch and cleanup. It runs in the same container as the worker, not
a second container. DinD and this reviewer mode cannot be combined.

These controls establish checked execution and reviewer write confinement.
They do not make worker-writable evidence tamper-proof or prove that repository
tests are complete and cannot be weakened. Model review is additional evidence,
not an oracle. Passing checks establish facts about the checked endpoint, not
every intermediate commit or every aspect of the mission.

## What should make the product useful

The intended experience connects low-friction setup, bounded execution,
recoverable progress, explicit verification, and easy human review. A loop or
container alone is not a sufficient product promise. We should demonstrate the
value of this combination rather than claim that competitors cannot offer it.

Finish the foundation in PR #32: explicit outcomes, initialization and rejection
recovery, durable run identity, consistent limits, complete usage accounting,
and regression coverage. The implementation checklist is in
[pr32-completion-plan.md](pr32-completion-plan.md).

Then build a deterministic `mill report` from recorded observations: accepted
diff, verified commit, command results, reviewer findings, rejected attempts,
known and unknown usage, and stop reason. Keep worker summaries and reviewer
judgments distinguishable from command results.

Durable resume must preserve the original comparison baseline, accepted
checkpoint, policy, and consumed allowance. Setup improvements should include
preflight diagnostics, tested Python/Node recipes, pinned images, actionable
authentication support, and an independent checkout from committed HEAD that
leaves the developer's uncommitted work untouched.

## Evidence before positioning claims

Compare native CLI execution, a minimal respawning loop, and AgentMill on the
same repository snapshots and bounded tasks. Match model/CLI versions and
resources, include reviewer usage, and use repeated trials. Measure verified
success, false completion, cost per accepted task, interventions, review effort,
and recovery correctness. Use independently maintained acceptance tests and
human review for calibration.

No comparative performance claim is justified by the runtime's complexity or
its own smoke tests. Fresh contexts and model review have costs and should be
evaluated alongside their benefits.

Keep TUI work, swarm coordination, vector memory, issue queues, provider-plugin
frameworks, and automatic merging outside this roadmap. The parked harness
integration in PR #30 can remain available for later experiments without
becoming another required execution mode.
