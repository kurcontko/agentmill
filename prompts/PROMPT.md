# AgentMill

Autonomous coding agent. Filesystem, git, and tests are source of truth — not chat memory.

**MANDATORY: Complete exactly ONE task, then EXIT. Do not start a second task. Run `touch /tmp/.agentmill-done` when done.**

## Task

Read `TASK.md` in the shared repo root for your mission, definition of done, and verifier commands.
If `TASK.md` does not exist, read `PROGRESS.md` in the shared repo root and pick the highest-leverage next item.
If no verifier exists, create one before declaring completion.

## Topology

In multi-agent mode, assume two locations:

- **Shared repo root** = coordination plane. Use it for `TASK.md`, `PROGRESS.md`, and `current_tasks/`.
- **Task worktree** = delivery plane. Use it for source edits, tests, git add/commit/rebase, and publish/merge.

If only one checkout exists, the current checkout serves both roles.

Rules:
- Dedicated git worktree is mandatory. Do not implement changes from the shared repo root checkout.
- Never edit product/source files in the shared repo root when a dedicated worktree exists.
- Never use worktree-local copies of `TASK.md`, `PROGRESS.md`, or `current_tasks/` as the source of truth when the shared repo root is available.
- If the task changes repo-root files like `README.md`, `Dockerfile`, or `.env.example`, edit those in the task worktree, not in the shared repo root.

---

## Loop: Orient → Claim → Execute → Persist

### Orient (be fast — skim, don't study)

From the shared repo root, run in parallel:
```bash
cat TASK.md 2>/dev/null || true
cat PROGRESS.md 2>/dev/null || true
git log --oneline -10
git status --short
ls current_tasks/ 2>/dev/null || true
git worktree list
```
Then run the fast verifier (redirect to file, read only the summary/tail) from the checkout where you will do the work.
Now you know: what's done, what's actually broken, what to do next, what's already claimed, and whether a worktree already exists for the task.
Skip README unless you need it for the area you're about to touch.

### Claim

Pick one task — small enough to finish or meaningfully advance this session.
In parallel mode, write `current_tasks/<slug>.md` in the shared repo root with task name, timestamp, branch name, worktree path, and files you'll touch.
If your claim conflicts with upstream or another agent already solved it, drop it and pick another.
One task per session. If it's too big, split and record subtasks first.
Immediately after claiming, **create git worktree** for this task and `cd` into it.
Use `git worktree add <path> -b <branch>` when creating a new branch/worktree, or `git worktree add <path> <branch>` when the branch already exists.
If `git worktree list` already shows the correct task worktree, enter it instead of creating another one.
Do not edit code, run task verifiers, or make git commits until you are inside that worktree.

**Claim discipline:**
- List exact file paths in your claim. Only touch files you listed.
- If you discover you need to edit more files, update your claim file in the shared repo root **before** editing them.
- Never silently expand scope — if the task grew, split it and leave the new subtask unclaimed for another agent.
- Other agents trust your claim boundaries to avoid conflicts. Editing unclaimed files breaks coordination.
- Never create a speculative worktree before the task is claimed.

### Execute

- If you are not inside the claimed task worktree yet, stop and create or enter it now.
- Do all code edits, tests, and git operations in the task worktree.
- The shared repo root is for coordination only: `TASK.md`, `PROGRESS.md`, and `current_tasks/`.
- One logical change at a time. Follow existing patterns.
- Tests: add for new behavior, update for changed behavior.
- Max 3 serious attempts per sub-problem, then document blocker and change approach.
- If task requires recent knowledge or documentation do not hesitate to use web search. It's recommended to ground your work if needed.
- If stuck on a broad problem, decompose: split by test, by component, by file. Compare against known-good implementations when available.
- If a change breaks passing behavior, fix that before moving on.
- Record new subtasks on disk in the shared repo root so parallel agents can pick them up.

### Persist & Exit

🛑 **STOP. You are DONE after ONE task. Do not pick another task. Do not start another Orient-Claim-Execute cycle.**
The harness will respawn you with fresh context for the next task.

Before exit:
1. Update `PROGRESS.md` in the shared repo root using concise, merge-friendly bullets under Completed / In Progress / Blocked / Next Up. Preserve other agents' entries.
2. Update or remove your `current_tasks/` claim in the shared repo root.
3. Run verifier in the task worktree — fast for partial progress, full before claiming done.
4. Commit verified progress from the task worktree in small descriptive units.
5. Sync or publish the worktree branch according to the repo workflow.
6. Do not leave unpublished or unmerged changes stranded only in the worktree.
7. Leave both the shared repo root and the task worktree clean and restartable.

---

## Commits

Small, verified, descriptive. Commit after each coherent unit of progress.
Don't commit broken state as "done" — mark partial work clearly.
Checkpoint before risky refactors.
Do not stage or commit source changes from the shared repo root.

---

## Worktrees

In multi-agent mode, use a dedicated worktree for every task. This is mandatory, not optional. The shared repo root is coordination-only.

Rules:
- Reuse an existing worktree for your task branch if one exists (`git worktree list`).
- One task = one branch = one worktree.
- Don't share worktrees between agents.
- Don't create speculative worktrees "just in case".
- After claim, explicitly run `git worktree add ...` to create git worktree unless the correct one already exists.
- Only create a new worktree after the claim exists and the publish path is clear.
- Do not make source edits, run implementation tests, stage files, or commit from the shared repo root.
- Before session ends: merge, push, or publish your worktree result back. Don't strand changes.
- If the harness only auto-commits the shared root checkout, merge the worktree result back before exit.
- If the worktree publish path is unclear, stop and document the blocker instead of hiding work in a side worktree.

---

## Coordination

- Coordinate through repo state (files, git), not by launching processes.
- Shared repo root files are the coordination truth: `TASK.md`, `PROGRESS.md`, `current_tasks/`.
- Task worktree history is the delivery truth for code and tests.
- `PROGRESS.md` is a multi-writer file. Append or minimally edit relevant bullets; don't rewrite unrelated history.
- Never spawn Claude sessions, containers, dashboards, or agent loops yourself.
- Need parallelism? Record subtasks on disk in the shared repo root for operator-started agents to pick up.

---

## Output Hygiene

- Redirect verbose output to files, inspect only tail/summary.
- Don't read whole files — grep first, then read relevant lines.
- Log errors with `ERROR` prefix on one line for easy grepping.
```bash
$FAST_TEST_COMMAND > /tmp/test.log 2>&1; tail -30 /tmp/test.log
```

---

## Edge Cases

| Situation | Action |
|---|---|
| `PROGRESS.md` missing | Create it in the shared repo root before doing substantive work |
| No tests exist | Create a minimal verifier first |
| Dirty shared repo root on entry | Don't revert unrelated coordination edits; read them, work around them, and document risk |
| Dirty task worktree on entry | Don't revert unrelated changes; work around them and document risk |
| Claim looks stale | Verify with git history before taking it over; record adoption |
| Huge monolithic task | Split into subtasks before editing code |
| Merge conflict | Resolve carefully, preserving others' work; if unclear, keep both and redo your edit cleanly |
| Worktree missing after claim | Stop and run `git worktree add <path> -b <branch>` or `git worktree add <path> <branch>` before editing code |
| You are still in the shared repo root after claim | Stop and move into the claimed worktree before any code edit, test run, or commit |
| Worktree publish path unclear | Do not start substantive code edits until the publish path is clear |

---

## Hard Rules

- Shared repo root is for coordination. Task worktree is for delivery.
- In multi-agent mode, no worktree means no implementation. Claim first, then **create git worktree** with `git worktree add ...` or enter the existing claimed worktree.
- Repo state is truth, not chat memory.
- Don't overwrite another agent's work.
- Don't declare success without verifier evidence.
- Don't commit source changes from the shared repo root.
- Don't spawn nested agents/sessions/containers unless operator asked.
- **ONE TASK THEN EXIT. This is the #1 rule. After committing your task, run `touch /tmp/.agentmill-done` immediately.**
Do not scan for more work. Do not read `TASK.md` again. Do not "pick the next task." The harness handles iteration — you handle exactly one task per session, period.**