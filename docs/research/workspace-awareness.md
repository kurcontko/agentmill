# R5 — Shared Workspace Awareness

**Branch**: `research/hierarchical-coordination`
**Status**: Done

---

## Problem

In multi-agent setups, two agents can edit the same file concurrently. The current mitigation is reactive: agents rebase after push conflicts. This causes wasted work (one agent's session is thrown away), noisy history, and potential merge ambiguity when both agents make structural changes to the same file.

Proactive awareness — agents advertising which files they're about to edit and checking for prior claims — eliminates most conflicts before they occur.

---

## Approaches Surveyed

### 1. `.locks/` Directory (Advisory Lock Files)
Each agent writes `<file-path>.lock` containing its agent ID and expiry. Other agents check before editing.

**Pros**: Trivially simple, zero dependencies, works on any shared volume.
**Cons**: TOCTOU race (check-then-act window); stale locks survive agent crashes if TTL not enforced; no atomic test-and-set on a shared filesystem.

This is the same race as `current_tasks/` claiming — mitigated but not eliminated by careful rename-based writes.

### 2. NFS Advisory Locks (`fcntl.lockf`)
POSIX file locking. Works if all agents share the same NFS mount with proper locking protocol.

**Pros**: OS-enforced.
**Cons**: NFS lock reliability is notoriously inconsistent across Linux kernel versions. Docker volumes are bind-mounted local filesystems — `fcntl` locks work only within the same host, not across containers on different hosts.

### 3. etcd Leases
Distributed key-value store with TTL leases. Industry standard (used by Kubernetes).

**Pros**: Strongly consistent, automatic TTL cleanup.
**Cons**: External dependency, heavyweight for small-scale deployments. Overkill for a Docker Compose setup.

### 4. SQLite with WAL Mode
A shared SQLite file with transactions for atomic test-and-set.

**Pros**: Atomic operations, stdlib `sqlite3`, persistent, no network.
**Cons**: SQLite shared-volume access in Docker containers (file locking) can be unreliable under contention. WAL mode requires the WAL file to be on the same filesystem, which Docker bind mounts often are — but not guaranteed across container restarts. No push/notify.

### 5. HTTP Lock Manager (Recommended)
A single lightweight HTTP service (the approach implemented here) mediates all lock requests. Agents `POST /acquire` before editing and `POST /release` when done. The service enforces atomicity via an in-process `threading.Lock` — no filesystem races.

**Pros**:
- Atomic test-and-set guaranteed (single lock per file, no TOCTOU)
- Automatic TTL expiry for crashed agents
- Heartbeat to extend TTL for long-running sessions
- Batch acquisition with sorted order (deadlock prevention)
- Works across Docker containers sharing a network
- State persisted to disk for crash recovery
- Pure Python stdlib, consistent with other modules in this project

**Cons**: Single point of failure (mitigated by crash recovery and automatic restart). Not suitable for cross-host deployments without additional HA setup.

---

## Implementation — `lock_manager.py`

### API

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/acquire` | Acquire a single file lock |
| `POST` | `/acquire_batch` | Acquire multiple files atomically |
| `POST` | `/release` | Release a specific lock |
| `POST` | `/release_all` | Release all locks held by an agent |
| `POST` | `/heartbeat` | Renew lock TTL |
| `GET`  | `/locks` | List all active locks |
| `GET`  | `/locks/<file>` | Check lock on a specific file |
| `GET`  | `/agent/<id>` | List locks held by agent |
| `GET`  | `/status` | Summary stats |

### Key Design Decisions

**Advisory, not enforced**: The OS does not prevent an agent from editing a file without a lock. Agents must cooperate. This matches how distributed file systems (NFS, SMB) work in practice — enforcement via coordination, not coercion.

**Deadlock prevention via sorted batch acquisition**: When multiple files are requested together, the server acquires them in sorted (lexicographic) order. As long as all agents use `acquire_batch` instead of sequential `acquire` calls for multi-file operations, circular wait is impossible.

**Single-rejection veto**: A 409 response from `/acquire` signals the caller to wait or pick different work. The coordinator (R2) can reassign the task rather than spinning.

**TTL + heartbeat**: Locks expire automatically after `DEFAULT_TTL` seconds (default 300s). Long-running agents send `POST /heartbeat` to extend. Crashed agents' locks expire and are reaped by the background thread every `REAP_INTERVAL` seconds (default 15s).

**Crash recovery**: State is atomically written (`os.replace`) to `logs/lock_state.json` on every mutation. Active (non-expired) locks are reloaded on startup.

---

## Integration Points

### With R2 Coordinator
Before assigning a task that touches specific files, the coordinator can pre-acquire locks and hand `lock_ids` to the worker. Worker releases on task completion.

```python
# coordinator assigns task
locks = requests.post("http://lockmanager:3004/acquire_batch",
                      json={"agent": worker_id, "files": task["files"], "ttl": 600})
if not locks.json()["ok"]:
    # conflicts — defer task, assign something else
    pass
```

### With R4 Message Bus
Agents broadcast `lock-acquired` and `lock-released` events so other agents know proactively what's in use without polling the lock manager.

```python
requests.post("http://messagebus:3003/publish", json={
    "from": agent_id, "to": "*", "topic": "lock-acquired",
    "body": {"files": list(lock_ids.keys())}
})
```

### With Entrypoint
At the start of each iteration, the agent queries `GET /agent/<id>` to verify no stale locks from a prior crashed session, then calls `POST /release_all` to clean up before starting fresh.

---

## Comparison to Baseline

| Approach | TOCTOU Safe | Crash Recovery | Cross-Container | Complexity |
|----------|-------------|----------------|-----------------|------------|
| Current (none) | N/A | N/A | N/A | Lowest |
| `.locks/` files | No | TTL on poll | Yes (shared vol) | Low |
| SQLite | Mostly | Yes | Unreliable | Medium |
| HTTP lock manager | Yes | Yes | Yes | Medium |
| etcd | Yes | Yes | Yes | High |

The HTTP lock manager is the right fit for this project: consistent with `queue_server.py`, `coordinator.py`, `merge_gate.py`, and `message_bus.py`; zero new dependencies; reliably atomic.

---

## Test Results

```
python3 -m unittest tests.test_lock_manager
Ran 44 tests in 0.655s — OK
```

Tests cover: single acquire/release, concurrent acquire (20 threads, exactly one wins), concurrent release (10 threads, exactly one succeeds), batch acquire (with partial conflict), heartbeat renewal, TTL expiry, persistence across "restart", deadlock-prevention sort order, and the full HTTP API (200/403/404/409 responses).
