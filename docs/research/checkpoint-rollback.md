# R9: Checkpoint & Rollback Protocol

## Problem

Agents iteratively modify a codebase. Over several iterations, quality can degrade: the agent introduces a regression, oscillates on a refactor, or pursues a dead-end. Without checkpoints, recovery means either starting from scratch or manual git archaeology.

We want periodic snapshots — _checkpoints_ — so an agent can self-assess and roll back to the last known-good state automatically.

---

## Approach: Git Tags as Checkpoints

Git already stores every commit permanently. We need:
1. A named pointer to "this commit was good" — a git tag.
2. A quality score attached to that tag.
3. A decision process: keep or roll back?
4. An HTTP service so agents can record and query checkpoints across sessions.

### Why git tags?

| Option | Pros | Cons |
|---|---|---|
| Git tags | Permanent, visible in `git log`, portable | Shared namespace (namespaced with `ckpt/session/n`) |
| Git branches | Easy to checkout | Branch proliferation, harder to prune |
| External DB | Query-flexible | Another service dependency |
| File markers | Simple | Lost on `git clean`, not atomic |

Git tags are the right primitive: they survive reboots, are visible to all agents, and integrate naturally with `git describe`/`git log`.

---

## Implementation: `checkpoint.py`

An HTTP service (default port **3009**) with Python 3.11+ stdlib only.

### Core concepts

```
checkpoint   git annotated tag (ckpt/<session>/<n>)
             metadata: session, commit SHA, score, label, timestamp
session      named run (agent hostname + pid, or any string)
score        float quality signal supplied by caller
evaluation   optional shell command (CHECKPOINT_EVAL_CMD) run after
             each iteration; exit 0 = pass, non-zero = fail;
             first line of stdout parsed as float score
```

### API

```
POST /checkpoints             Create checkpoint at commit (default HEAD)
                              body: {session, commit, score, label}
                              -> 201 {id, commit, score, ...}

GET  /checkpoints             List all checkpoints (optional ?session=)
GET  /checkpoints/<id>        Get single checkpoint
DELETE /checkpoints/<id>      Delete checkpoint (also removes git tag)

POST /rollback                Roll back to a chosen checkpoint
                              body: {session, strategy, target, dry_run}
                              strategies: best | prev | specific
                              -> 200 {rolled_back_to, commit, dry_run}

GET  /rollback/history        Audit log of all rollbacks

POST /evaluate                Run EVAL_CMD against a commit
                              -> 200 {ok, score, recommendation: keep|rollback}

GET  /status                  Summary counts
```

### Rollback strategies

| Strategy | Description | Use case |
|---|---|---|
| `best` | Highest-scored checkpoint in session | Recover from a streak of bad iterations |
| `prev` | One step back | Undo the last iteration |
| `specific` | Named id or git ref | Manual override or external orchestration |

### Evaluation integration

Set `CHECKPOINT_EVAL_CMD` to any shell command. The command receives `GIT_COMMIT` as an env var and should:
- Exit 0 on pass, non-zero on fail
- Optionally write a float score (0.0–1.0) on the first line of stdout

Example — test suite as evaluator:
```bash
export CHECKPOINT_EVAL_CMD='python3 -m unittest discover -s tests 2>/dev/null && echo 1.0 || echo 0.0'
```

Example — lint score:
```bash
export CHECKPOINT_EVAL_CMD='pylint src/ --score=y 2>/dev/null | awk "/rated/{print \$7}" | tr -d "/10"'
```

### Agent loop integration

```bash
# After each iteration in entrypoint.sh:
curl -s -X POST http://localhost:3009/evaluate \
     -H "Content-Type: application/json" \
     -d "{\"session\":\"$AGENT_ID\",\"commit\":\"HEAD\"}" \
| jq -r '.recommendation'
# "keep" → proceed, "rollback" → call POST /rollback
```

---

## Design Decisions

### Hysteresis / rollback threshold

The current implementation delegates the keep/rollback decision to the caller: `POST /evaluate` returns a recommendation but doesn't automatically roll back. This is intentional — the operator chooses the threshold (e.g., only roll back if score < 0.5 and last 3 iterations failed).

### Session namespace

Checkpoints are namespaced by session to avoid collisions between concurrent agents. A session is any opaque string; typically `$AGENT_ID` or `hostname-pid`.

### Git tag naming

Tags use `ckpt-<session>-<seq>` (dashes instead of slashes) to maximise compatibility with git hosting services that restrict tag path segments. The `id` field in the API uses the slash form (`ckpt/<session>/<seq>`) for readability.

### Pruning

`CHECKPOINT_MAX_PER_SESSION` (default 50) prevents unbounded tag accumulation. Oldest checkpoints are evicted first; the most-recent 50 are always kept.

### Dry-run mode

`CHECKPOINT_DRY_RUN=1` (or `dry_run: true` per-request) logs the intended `git reset --hard` without executing it. Useful for testing pipelines.

### Crash recovery

State persists to `logs/checkpoint_state.json` after every write. On restart, all sessions, checkpoint metadata, and rollback history are restored. The git tags themselves are the ground truth for commit pointers; the JSON file only caches metadata.

---

## Comparison to the baseline

The baseline (no checkpointing) requires:
- Manual `git log` inspection to find regressions
- Full re-run from scratch if context is lost

With checkpointing:
- Any iteration can be scored automatically
- Best-scored state is always reachable in one HTTP call
- Rollback history provides audit trail for multi-agent debugging

---

## Integration with other R-tasks

| Task | Integration |
|---|---|
| R2 Coordinator | Coordinator calls `/evaluate` after a worker finishes; triggers rollback if score drops below threshold |
| R3 Merge Gate | Gate only approves merges if latest checkpoint score ≥ quorum threshold |
| R4 Message Bus | Agent broadcasts `checkpoint_created` / `rolled_back` events for observability |
| R7 Scaler | Scaler can scale down agents that roll back repeatedly (quality signal for idle detection) |

---

## Future work

- **Bisect integration**: Use git bisect with the eval command to find the exact commit that introduced a regression (like `git bisect run`).
- **Cross-agent checkpoint sharing**: Let one agent roll back to another agent's high-scoring checkpoint in a collaborative session.
- **Score smoothing**: Rolling average to avoid thrashing on noisy eval commands.
- **Checkpoint diff**: Show what changed between two checkpoints to help diagnose regressions.
