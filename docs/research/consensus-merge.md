# R3: Consensus-Based Merge Gate

## Goal

Block branch merges until N-of-M validator agents have approved. Implement a
lightweight consensus protocol as an HTTP service that CI or agents poll before
merging.

## Background Research

### CI-Gated Merges (traditional)

GitHub/GitLab branch protection requires N passing CI jobs before merge. The
"jobs" are processes (test runners, linters, security scanners). The gate is
enforced by the platform, not the agents themselves.

Analogously, with autonomous agents as reviewers, the gate must be enforced by
a service that all agents agree to consult — and that service must be
tamper-resistant enough that no single agent can self-approve a bad branch.

### Blockchain Consensus Models

| Protocol | Quorum | Key property |
|---|---|---|
| Simple majority | >50% | Tolerates up to N/2−1 faulty nodes |
| Two-thirds quorum (BFT) | >66% | Tolerates Byzantine (lying) nodes |
| All-agree | 100% | No fault tolerance |

For multi-agent code review, Byzantine faults are less likely than crashes or
test failures. **Simple majority (or a configurable N-of-M)** is sufficient.

A single rejection is treated as a veto (strong blocking), because a test
failure or security issue in any validator is a hard stop. This maps to how
GitHub status checks work: all required checks must pass.

### CrewAI / AutoGen Validation Patterns

- CrewAI uses a "guardrails" function on task output; the reviewer agent
  returns `(True, output)` or `(False, feedback)`. Sequential: one reviewer
  at a time.
- AutoGen `GroupChat` can route a message to multiple agents and aggregate
  replies, but consensus logic is left to the orchestrator.
- Devin uses human review as the final gate; no automated multi-agent
  consensus is documented publicly.

The gap: **none of these provide a persistent, multi-agent consensus store
that survives process restarts.**

## Design

### Architecture

```
                  ┌──────────────┐
   agent-1 ──────►│              │
   agent-2 ──────►│  merge_gate  │──► /status/<id>  ──► CI / merge script
   agent-3 ──────►│   (HTTP)     │
                  └──────────────┘
                       │
                  logs/merge_gate_state.json
```

### State Machine

```
submit ──► pending ──► approved (N approvals reached)
                  └──► rejected (any rejection)
                  └──► expired  (TTL exceeded without quorum)
```

### API

| Endpoint | Method | Description |
|---|---|---|
| `/submit` | POST | Register a branch for review; returns `merge_id` |
| `/approve` | POST | Validator casts approval vote |
| `/reject` | POST | Validator casts rejection (veto) |
| `/status/<id>` | GET | Fetch current state + vote counts |
| `/pending` | GET | List all open merge requests |
| `/status` | GET | Summary counts |
| `/configure` | POST | Adjust quorum/total_validators at runtime |

### Quorum Logic

- `MERGE_GATE_QUORUM` (default 2): approvals needed.
- `MERGE_GATE_TOTAL_VALIDATORS` (default 3): informational; used for
  progress display. Actual blocking is done by the quorum count only.
- A single rejection immediately transitions to `rejected`.
- Duplicate votes from the same validator overwrite (idempotent).

### Persistence & Crash Recovery

All state is written atomically to `logs/merge_gate_state.json` on every
mutation. On restart, in-flight (pending) merge requests are preserved. No
re-queuing needed: pending requests simply wait for more votes.

### Expiry

A background reaper thread runs every `MERGE_GATE_REAP_INTERVAL` seconds
(default 60s) and expires requests older than `MERGE_GATE_TTL` (default
3600s). Expired requests are permanently closed and do not block new
submissions for the same branch.

## Implementation

`merge_gate.py` — Python 3.11+, stdlib only.

```
PORT              = MERGE_GATE_PORT        (default 3004)
STATE_FILE        = MERGE_GATE_STATE_FILE  (default logs/merge_gate_state.json)
QUORUM            = MERGE_GATE_QUORUM      (default 2)
TOTAL_VALIDATORS  = MERGE_GATE_TOTAL_VALIDATORS (default 3)
MERGE_TTL         = MERGE_GATE_TTL         (default 3600s)
REAP_INTERVAL     = MERGE_GATE_REAP_INTERVAL (default 60s)
```

## Test Results

`tests/test_merge_gate.py` — 33 tests, all pass.

Coverage:
- Submit, approve, reject lifecycle
- Quorum threshold (N approvals triggers `approved`)
- Single rejection triggers `rejected`
- Double-vote idempotency
- State machine: votes after decision are blocked
- Persistence: state survives reload
- Config persistence: quorum stored in state file, not just env
- Expiry: TTL reaper marks stale requests
- Concurrency: 20 simultaneous validators, exactly one `ready=True` flip
- HTTP API: all endpoints

## Integration with R2 Coordinator

The coordinator (`coordinator.py`) currently marks tasks `done` when a worker
calls `/complete`. To enforce consensus before merging:

1. Worker calls `merge_gate /submit` with `branch` + `commit` after pushing.
2. Worker reports `merge_id` to coordinator via `/checkin` or a new field.
3. Coordinator assigns the branch to N validator workers (via `/assign` with a
   `validate` task type).
4. Validators call `/approve` or `/reject` on the gate.
5. CI/merge script polls `GET /status/<id>` and merges only when
   `state == "approved"`.

This keeps the gate stateless with respect to the coordinator — any agent can
use the gate independently of whether the full coordinator is running.

## Comparison to Baseline

| Approach | Atomicity | Crash-safe | Multi-agent | Complexity |
|---|---|---|---|---|
| Git branch protection (CI) | Platform-enforced | Yes | No (single CI) | Low |
| Approval file in git | TOCTOU risk | Yes (git history) | Yes (merge conflict) | Low |
| SQLite in shared volume | Yes (WAL mode) | Yes | Yes | Medium |
| **HTTP merge gate (this)** | **Yes (threading.Lock)** | **Yes (json persist)** | **Yes** | **Low** |

## Recommendations

- Use the HTTP merge gate for 2+ agent deployments where automatic merge
  validation is needed.
- Default quorum of `ceil(N/2) + 1` (simple majority) is sufficient for
  quality gates; increase to `N-1` or `N` for security-critical changes.
- Pair with [R4] Message Bus so validators are notified of new merge requests
  rather than polling.
- Pair with [R2] Coordinator to automatically assign validator agents to each
  new merge request.

## Next Steps

- R4: Agent Message Bus — validators can subscribe to merge request events
  instead of polling `/pending`.
- R6: Role-Based Agents — designate specific agents as "reviewer" role with
  access to the merge gate approve/reject endpoints.
