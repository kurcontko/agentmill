# Research: Hierarchical / Supervisor-Worker Model

**Task**: R2
**Branch**: `research/hierarchical-coordination`
**Status**: Done

---

## Problem

AgentMill's current model is flat: N identical agents each independently pick
tasks from `current_tasks/`, write code, and push. There's no supervision,
no task decomposition, and no validation before merging. Every agent does
everything.

The question: can we improve throughput, quality, and coherence by introducing
a **coordinator** that plans and assigns work, letting workers stay focused on
execution?

---

## Prior Art Survey

### CrewAI
- Roles: `Researcher`, `Writer`, `Reviewer`, defined in YAML or Python objects
- Each agent has a *backstory*, *goal*, and *tools*
- Coordinator (`Crew`) runs a sequential or hierarchical process
- Hierarchical mode: Manager LLM decides which agent executes each step
- **Lesson**: Role-based specialization reduces context rot. Manager adds latency but improves delegation quality.

### AutoGen (Microsoft)
- `AssistantAgent` + `UserProxyAgent` pattern
- `GroupChat` for multi-agent round-robin; `GroupChatManager` selects next speaker
- Agents can spawn sub-agents (nested chats)
- **Lesson**: Loose message-passing between agents is flexible but hard to observe. Needs structured termination conditions.

### Devin / SWE-agent
- Single agent with planning, coding, and testing steps baked into the loop
- No multi-agent coordination as of research date
- **Lesson**: Specialization at the task level (plan→implement→test) matters even for a single agent.

### Cilk / Go Scheduler (work-stealing reference)
- These operate at the thread/goroutine level, not LLM level
- Relevant principle: **work locality** — assign tasks to the worker most likely to finish them fast (e.g., has context on that module)
- AgentMill equivalent: coordinator tracks which worker last touched which files and prefers assigning related tasks to the same worker

---

## Design: AgentMill Coordinator

### Architecture

```
                  ┌─────────────────────────┐
  TASK.md  ──────►│      coordinator.py      │
                  │                         │
                  │  • parses TASK.md        │
                  │  • maintains task queue  │
                  │  • heartbeat/reaping     │
                  │  • merge-readiness gate  │
                  └────────────┬────────────┘
                               │ HTTP API (port 3003)
                ┌──────────────┼──────────────┐
                │              │              │
           worker-1        worker-2        worker-3
           (agent loop)    (agent loop)    (agent loop)
```

Workers are unmodified `entrypoint.sh` agents, extended with two calls:
1. `POST /assign` — get next task instead of scanning `current_tasks/`
2. `POST /checkin` — heartbeat every N seconds while working
3. `POST /complete` — signal done, include branch name for merge gate
4. `POST /fail` — signal failure with reason

### Task Lifecycle

```
TASK.md ──seed──► pending
                     │
        POST /assign ▼
                  assigned ──── heartbeat ──── assigned
                     │
        POST /complete│  POST /fail (× < 3)
                      ▼         ▼
                    done     pending (retry)
                                 │
                    POST /fail (× = 3)
                                 ▼
                              failed
```

### Stale Task Reaping

Each assignment records `assigned_at`. Workers must call `/checkin` within
`HEARTBEAT_TTL` seconds (default 120s). The coordinator's background reaper
thread runs every `REAP_INTERVAL` seconds (default 30s). Stale tasks are moved
back to `pending` with original priority, so a faster/healthier worker picks
them up immediately.

This handles the common failure mode: worker container OOM-killed mid-task.

### Crash Recovery

State is persisted to `logs/coordinator_state.json` on every mutation (same
pattern as `queue_server.py`). On startup, all `assigned` tasks are re-queued.
No task is lost even if the coordinator process itself crashes.

---

## Implementation

**`coordinator.py`** (385 lines, stdlib only):
- `CoordinatorState` — thread-safe task state with persistence
- `CoordinatorHandler` — HTTP handler (`do_GET`, `do_POST`, `do_DELETE`)
- `parse_task_md()` — parses TASK.md, extracts tasks not yet marked `[x]` or `[!]`
- `reaper_loop()` — background daemon thread
- CLI: `python3 coordinator.py [--port N] [--state-file F] [--task-md F] [--no-seed]`

**`tests/test_coordinator.py`** (28 tests):
- Unit tests for all CoordinatorState methods
- Concurrent assign test: 20 threads, no double-dequeue
- Crash recovery test
- TASK.md parser tests (priority extraction, branch extraction, done-task exclusion)
- HTTP integration tests

---

## Comparison to Baseline

| Dimension | Git-based (baseline) | HTTP Coordinator |
|---|---|---|
| Task claiming | Write file to `current_tasks/` (TOCTOU possible) | Atomic via `threading.Lock` |
| Stale task recovery | Manual / never | Automatic heartbeat reaping |
| Task prioritization | None (first-come) | Priority field, FIFO within priority |
| Crash recovery | Agent picks up on restart by re-scanning | Re-queued on coordinator restart |
| Task decomposition | Human writes TASK.md | Coordinator seeds from TASK.md; can add subtasks via API |
| Merge gate | None | `/complete` records branch; ready for gate extension |
| Observability | `ls current_tasks/` | `/status`, `/tasks` JSON endpoints |
| Added complexity | None | +1 process, +1 port, workers need 3 HTTP calls |

**When to use**: For runs with 3+ agents where task collision and orphaned work
are observed problems. Not worth the added process for 1-2 agents.

---

## Extension Points

1. **Role-based assignment**: Add `role` field to tasks and workers. Coordinator
   only assigns `role:tester` tasks to workers with `WORKER_ROLE=tester` in env.

2. **Merge gate integration**: On `/complete`, coordinator runs `git merge-tree`
   or a test script before allowing the branch to be merged. This becomes the
   foundation for R3 (Consensus-Based Merge Gate).

3. **Dynamic scaling signal**: Coordinator exposes `/status` with queue depth.
   An autoscaler (R7) polls this and calls `docker compose scale` when
   `pending > threshold`.

4. **Work locality**: Coordinator tracks `files_touched` per task (from git diff
   after completion), and preferentially assigns related tasks to the same worker.

---

## Recommendations

- **Deploy coordinator as a sidecar** in `docker-compose.yml` alongside agents.
  Workers set `COORDINATOR_URL=http://coordinator:3003` and poll `/assign`.
- **Keep fallback**: If coordinator is unreachable, workers fall back to file-based
  `current_tasks/` claiming. This prevents a single-point-of-failure.
- **Heartbeat interval**: 30s is a good default. Claude Code sessions are long-lived
  (minutes per task), so 120s TTL with 30s heartbeat gives 4 missed beats before
  reaping — robust against transient network hiccups inside Docker.
- **Persist state to a volume mount**, not the repo itself. Use `logs/` which is
  already excluded from git commits in the framework.

---

## Verification

```bash
python3 -m unittest tests.test_coordinator   # 28 tests, OK
python3 -m py_compile coordinator.py         # syntax OK
```
