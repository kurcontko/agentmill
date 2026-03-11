# R4 — Agent Message Bus

## Problem

AgentMill agents coordinate exclusively through git: branch naming, commit messages, and
shared files under `current_tasks/`. This works well for coarse-grained synchronisation
(task claiming, results) but has no mechanism for:

- Agents broadcasting real-time status (e.g., "I'm stuck, anyone available?")
- Targeted delegation (e.g., coordinator asking a specific worker to help)
- Liveness detection without polling git
- Integration with the merge gate (R3) — a worker can't signal "ready for review"
  without a side channel

## What We Need (Minimal Viable)

1. **Publish**: any agent posts a message with a topic and optional recipient.
2. **Subscribe (live)**: an agent streams incoming messages in real time.
3. **Mailbox (offline)**: messages are buffered if the recipient isn't connected;
   retrieved on reconnect and explicitly acked when processed.
4. **Broadcast**: `to: "*"` reaches all known agents.
5. **Persistence**: survive restarts — unacked mailbox messages must not be lost.

## Approaches Evaluated

### A — Shared File Mailbox

Each agent owns a directory `mailboxes/agent-N/` where other agents drop JSON files.
The recipient polls for new files, processes them, deletes them.

**Pros**: zero infrastructure, works across any shared volume.
**Cons**:
- TOCTOU: two senders writing the same filename can silently overwrite each other.
- Polling interval trade-off: too fast → filesystem noise; too slow → latency.
- No live push — agents must actively poll, burning cycles even when idle.
- Ordering not guaranteed across writers.

### B — Unix Named Pipes (FIFOs)

Create a FIFO per agent in the shared volume. Senders `open(fifo, 'a')` and write;
recipients `open(fifo, 'r')` and read.

**Pros**: kernel-buffered, no polling needed.
**Cons**:
- FIFOs don't persist across process restarts (Linux FIFOs are in-kernel; the named
  entry survives but buffered data does not).
- Multiple writers to a single FIFO can interleave partial writes unless every write
  is ≤ PIPE_BUF (4096 bytes) — easily exceeded by JSON payloads.
- Not accessible outside the container without a mounted path and careful permissions.

### C — SQLite Queue

A single `messages.db` on the shared volume. Writers `INSERT`; readers `SELECT` and
`DELETE` in a transaction.

**Pros**: ACID, ordering, persistence, queryable.
**Cons**:
- SQLite WAL mode required to allow concurrent readers/writers; still serialises on
  write locks.
- No push notification — readers must poll or use `inotify` hacks.
- File locking over NFS/Docker volumes is unreliable on some hosts.

### D — SSE-Based HTTP Bus (chosen)

A standalone HTTP service (`message_bus.py`) that agents connect to over the shared
Docker network. The server holds all state in-process (with a JSON persistence file)
and exposes:

- `POST /publish` — atomic publish to mailboxes + fan-out to live SSE subscribers.
- `GET /subscribe/<agent-id>` — SSE stream; server pushes messages as they arrive,
  pre-fills buffered mailbox on connect.
- `GET /mailbox/<agent-id>` — pull buffered messages (for agents that prefer polling).
- `POST /ack` — mark a message as processed; removes it from the mailbox.

**Pros**:
- Single `threading.Lock` for all state mutations — no filesystem races.
- Live push delivery via SSE; no client polling required.
- Crash recovery: unacked mailbox messages survive restarts (persisted to JSON).
- Reuses SSE pattern already in `codex_preview_server.py` — familiar and tested.
- Zero extra dependencies; Python stdlib only.

**Cons**:
- Single-process bottleneck. For 3–10 agents (the AgentMill use case), a single
  Python thread pool is more than sufficient; this would be a concern at 100+ agents.
- Agents need a network route to the bus container. In Docker Compose this is free;
  in split-VM deployments it requires explicit port exposure.

## Implementation

`message_bus.py` — 260 lines, stdlib only.

```
MessageBus
├── publish(from, to, topic, body) -> msg_id
│     ├── append to _messages ring buffer (MAX_HISTORY=500)
│     ├── deliver to recipient mailboxes (all if to="*")
│     ├── persist state to JSON
│     └── fan-out to live SSE subscriber queues
├── subscribe(agent_id) -> (queue, unsubscribe_fn)
│     ├── register Queue in _subscribers
│     ├── ensure mailbox exists
│     └── return unsubscribe callable
├── get_mailbox(agent_id) -> list[msg]
├── ack(agent_id, msg_id) -> bool
├── clear_mailbox(agent_id)
├── get_history(limit) -> list[msg]
├── get_topics() -> list[str]
└── status() -> dict

BusHandler (BaseHTTPRequestHandler)
├── POST /publish
├── POST /ack
├── DELETE /mailbox/<agent-id>
├── GET /subscribe/<agent-id>   (SSE)
├── GET /mailbox/<agent-id>
├── GET /status
├── GET /topics
└── GET /messages
```

### Message Format

```json
{
  "id": "uuid4",
  "from": "agent-1",
  "to": "agent-2",       // or "*" for broadcast
  "topic": "status",
  "body": { ... },
  "ts": 1710000000.0
}
```

### Conventional Topics

| Topic        | Meaning |
|---|---|
| `status`     | Agent broadcasts current state (idle, working, stuck) |
| `heartbeat`  | Liveness ping |
| `task-done`  | Task completed, branch pushed |
| `request`    | Ask for help / delegate subtask |
| `merge-ready`| Signal merge gate (R3) that branch is ready for review |

## Integration with Existing Components

### With R2 Coordinator (`coordinator.py`)

The coordinator can subscribe to `task-done` messages from workers instead of (or in
addition to) polling task state via HTTP. Workers publish on completion; the coordinator
picks up the event, marks the task done, and assigns the next one.

### With R3 Merge Gate (`merge_gate.py`)

Workers publish `merge-ready` with the branch name in the body. The coordinator (or any
listening validator) subscribes, calls `POST /request` on the merge gate, and publishes
the result back as `merge-result`. This decouples the worker from knowing the merge gate
URL.

### With R5 Workspace Awareness (future)

Agents can publish `file-lock` / `file-unlock` messages to the bus as an advisory
broadcast, giving others real-time awareness without polling a lock directory.

## Test Coverage

`tests/test_message_bus.py` — 31 tests.

Key scenarios:
- Broadcast delivery reaches all known agents
- Targeted messages don't leak to other agents
- Ack removes message from mailbox; double-ack is a no-op
- State persists across restart (new `MessageBus` instance loads same file)
- 20-thread concurrent publish: no double-delivery, no lost messages
- 10-thread concurrent ack: exactly one succeeds
- Full HTTP API coverage (201/200/400/404)

## Comparison to Baseline

| Dimension          | git-only baseline      | HTTP Message Bus        |
|---|---|---|
| Latency            | Minutes (push/pull)    | Milliseconds (SSE)      |
| Offline delivery   | Yes (git history)      | Yes (mailbox buffer)    |
| Broadcast          | None                   | `to: "*"`              |
| Ordering           | Commit timestamp       | Server insertion order  |
| Extra infra        | None                   | One container / process |
| Fault tolerance    | Very high (git)        | Restart-safe (JSON)     |

The bus is complementary to, not a replacement for, git-based coordination. Large
artefacts (code, docs, task state) stay in git. Small, time-sensitive signals (status,
heartbeat, review requests) move through the bus.

## Recommendation

For deployments with 3+ agents where coordination latency matters, add the message bus
as an optional sidecar. The bus runs on `BUS_PORT=3003` (default); agents that want live
messaging connect to it, those that don't are unaffected.

For single-agent or very simple setups, the git-only baseline remains the right choice.
