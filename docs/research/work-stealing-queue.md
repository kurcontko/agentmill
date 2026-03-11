# R1: Work-Stealing Queue — Research & Prototype

**Branch**: `research/work-stealing-queue`
**Status**: Complete
**Date**: 2026-03-11

---

## Problem: The Baseline

AgentMill's current coordination mechanism uses a **file-based task claim** pattern:

```
current_tasks/<slug>.md   # agent writes this to claim a task
```

Agents read `TASK.md`, pick an unclaimed task, then write a claim file. This has a classic **TOCTOU race**:
- Agent A reads: "R1 is unclaimed"
- Agent B reads: "R1 is unclaimed"
- Agent A writes `current_tasks/R1.md`
- Agent B writes `current_tasks/R1.md` (overwrites — double claim!)

Both agents then work on R1. Their branches diverge, creating merge conflicts. At best, one agent's work is wasted.

**Baseline throughput metric**: With N agents and M tasks, worst-case waste is O(N) duplicate work per task.

---

## Approaches Evaluated

### 1. File-Based Queue with Atomic Rename (Simplest)

**Idea**: Pre-populate a `queue/` directory with one file per task. Claiming is `mv queue/<task>.md in_flight/<task>-<agent>.md`. POSIX `rename(2)` is atomic — only one process wins.

**Pros**:
- Zero new dependencies
- Works on any shared volume
- Inspectable with `ls`

**Cons**:
- Tasks must be pre-populated (no dynamic enqueue)
- No retry / failure tracking without more file juggling
- Atomic only on POSIX-compliant filesystems (NFS: maybe not)
- No ordering guarantees with concurrent `readdir` + `rename`

**Verdict**: Good for a fixed, static task list. Breaks down with dynamic workloads.

### 2. SQLite-Backed Queue (Robust, Shared Volume)

**Idea**: SQLite with WAL mode on a shared volume. Agents `BEGIN IMMEDIATE` + `SELECT ... LIMIT 1 FOR UPDATE` (SQLite uses table lock) to claim a row, `COMMIT`.

**Pros**:
- ACID guarantees: no double-dequeue
- Supports dynamic enqueue, retry counts, priority
- SQLite WAL allows concurrent readers

**Cons**:
- SQLite has known issues with NFS/CIFS volumes (file locking unreliable)
- Requires SQLite3 module (available in Python stdlib, but not bash)
- Performance degrades above ~1000 writes/sec (irrelevant here)

**Verdict**: Best for persistent, auditable queues. Risky on NFS mounts.

### 3. HTTP Queue Server (Selected for Prototype)

**Idea**: A lightweight HTTP service (`queue_server.py`) holds the queue in memory behind a `threading.Lock`. HTTP is the serialization point — the OS TCP stack ensures exactly one request wins each dequeue.

**Pros**:
- True atomicity: no filesystem races, no NFS concerns
- Works across containers with only a port exposed (no shared volume needed for coordination)
- Dynamic enqueue/fail/retry — tasks can arrive at runtime
- Crash recovery: persists to JSON on every mutation; on restart, in-flight tasks are recovered to pending
- Inspectable via `GET /status` and `GET /tasks`

**Cons**:
- Requires the server to be running (adds a process to manage)
- Single point of failure (mitigated: crash recovery means state is durable)
- HTTP overhead: ~1ms per operation (irrelevant for agent timescales of minutes)

**Verdict**: Best fit for AgentMill's Docker Compose model. One extra container, zero new dependencies (stdlib only).

---

## Prototype: `queue_server.py`

### Architecture

```
┌─────────────────────────────────────┐
│         queue_server.py             │
│                                     │
│  QueueState (in-memory + JSON file) │
│    pending:   [task, task, ...]      │
│    in_flight: {id: task, ...}       │
│    done:      [task, ...]           │
│    failed:    [task, ...]           │
│                                     │
│  QueueHandler (HTTP)                │
│    POST /enqueue                    │
│    GET  /dequeue  ← atomic pop      │
│    POST /complete                   │
│    POST /fail     ← retry ≤3        │
│    GET  /status                     │
│    GET  /tasks                      │
│    DELETE /task/<id>                │
└─────────────────────────────────────┘
         ↕ HTTP
┌──────┐ ┌──────┐ ┌──────┐
│agent1│ │agent2│ │agent3│
└──────┘ └──────┘ └──────┘
```

### Key Properties

**Atomic dequeue**: `QueueState.dequeue()` holds `threading.Lock` for the entire pop-and-move operation. Concurrent HTTP requests serialize at the lock — impossible to double-dequeue.

**Crash recovery**: State is written atomically (`rename` from `.tmp`) on every mutation. On restart, any `in_flight` tasks are moved back to `pending` (prepended for priority).

**Retry with limit**: `fail()` re-queues a task up to 3 times. After that it moves to `failed` — preventing infinite retry loops (matching AgentMill's `PUSH_REBASE_MAX_RETRIES` pattern).

**FIFO with priority recovery**: Normal tasks are appended (FIFO). Recovered/failed tasks are prepended (high priority).

### API Usage from Agents

```bash
# Dequeue a task
curl -s http://queue:3002/dequeue | jq .

# Complete a task
curl -s -X POST http://queue:3002/complete \
  -H 'Content-Type: application/json' \
  -d '{"id": "R1-work-stealing-queue"}'

# Fail a task (re-queues for retry)
curl -s -X POST http://queue:3002/fail \
  -H 'Content-Type: application/json' \
  -d '{"id": "R1", "reason": "git rebase conflict"}'
```

```python
# From Python (no requests dep)
from queue_server import client_dequeue, client_complete

task = client_dequeue(host="queue", port=3002)
if task:
    do_work(task["payload"])
    client_complete(task["id"], host="queue", port=3002)
```

### Docker Compose Integration

Add to `docker-compose.yml`:

```yaml
services:
  queue:
    build: .
    entrypoint: ["python3", "/workspace/repo/queue_server.py"]
    ports:
      - "3002:3002"
    volumes:
      - ${REPO_PATH}:/workspace/repo
    environment:
      - QUEUE_PORT=3002
      - QUEUE_STATE_FILE=/workspace/repo/logs/queue_state.json
    restart: unless-stopped

  agent-1:
    environment:
      - QUEUE_HOST=queue
      - QUEUE_PORT=3002
    depends_on:
      - queue
    # ... existing agent config
```

---

## Comparison: Baseline vs. HTTP Queue

| Property | File-based (`current_tasks/`) | HTTP Queue (`queue_server.py`) |
|---|---|---|
| Atomicity | No (TOCTOU race) | Yes (mutex + HTTP serialization) |
| Double-claim possible | Yes | No |
| Dynamic task addition | Manual file write | `POST /enqueue` |
| Failure recovery | Manual | Automatic (up to 3 retries) |
| Crash recovery | State in git | JSON persistence + recovery |
| Inspectable | `ls current_tasks/` | `GET /status`, `GET /tasks` |
| Dependencies | None | None (stdlib) |
| Portability | POSIX only | Any OS |
| Network required | No (shared volume) | Yes (port 3002) |
| Added complexity | Minimal | One extra service |

---

## Distributed Work-Stealing Background

### Classic Work Stealing (Cilk / Go Scheduler)

Work-stealing schedulers (Cilk Plus, Go's goroutine scheduler) use **per-worker deques**. Each worker pops from the front of its own deque. When idle, a worker *steals* from the back of another worker's deque.

This avoids central bottlenecks but requires shared memory (not applicable across containers). The key insight: **stealing from the back minimizes interference** with the owner working at the front.

### Tokio's Work-Stealing Runtime

Tokio uses a **local queue + global queue** model. Workers pop from their local queue; when empty they steal from other workers or pull from the global queue. The global queue is protected by a mutex.

For AgentMill's use case (tasks take minutes, not microseconds), the overhead of a central HTTP server is negligible. The Tokio-style "global queue with mutex" is exactly what `queue_server.py` implements.

### Stigmergy (Ant Colony Model)

Ant colonies coordinate through **environment state** (pheromone trails) rather than direct communication. AgentMill's git-based coordination is already stigmergic: agents read and write repo state to coordinate.

The HTTP queue extends this: the queue server is a shared environment artifact that agents query and update. The difference from the file-based approach is that the server serializes mutations, eliminating races.

---

## Findings & Recommendations

1. **Replace `current_tasks/` with `queue_server.py` for multi-agent deployments.** The file-based approach has a fundamental race condition that causes wasted work and git conflicts.

2. **Keep file-based claiming for single-agent mode.** No coordination needed; no server overhead.

3. **The HTTP queue adds one container but zero code dependencies.** It follows the existing `codex_preview_server.py` pattern and requires no third-party packages.

4. **For NFS/remote volumes, HTTP queue is strongly preferred over SQLite.** SQLite file locking is unreliable over NFS.

5. **Crash recovery is the killer feature.** When an agent container dies mid-task, in-flight tasks are automatically recovered on server restart — something impossible with the file-based approach without extra machinery.

---

## Verifier

```bash
python3 -m unittest tests.test_queue_server
# Expected: 22 tests, OK
```

All 22 tests pass, including a concurrent dequeue test verifying no double-dequeue with 20 simultaneous threads.
