# R8: Cross-Repo Agent Coordination

## Problem

When agents work on multiple interdependent repositories (e.g., a library and
its consumers), they need to coordinate:

1. **API change propagation** — if lib-A renames a function, consumers must adapt.
2. **Version bump notification** — downstream repos need to update their dependency
   manifests.
3. **Integration testing** — consumers must confirm compatibility after upstream
   changes.
4. **Dependency ordering** — changes should flow in topological order to avoid
   cascading failures.

The current single-repo model has no mechanism for this. Git branches don't
span repos; the task queue is repo-scoped.

---

## Research: How Existing Tools Handle This

### Monorepo tools (Nx, Turborepo, Bazel)

Move everything into one repo, using a build graph to determine what needs
rebuilding. Nx uses a "project graph" derived from imports; Turborepo uses a
`turbo.json` pipeline; Bazel uses explicit `BUILD` files.

**Advantage**: single git history, no cross-repo sync, CI sees everything.
**Disadvantage**: not an option when repos are separately owned or already exist
as separate projects.

### Microservice teams: breaking changes protocol

Common patterns:
- **Expand-contract** (aka strangler fig): add the new API, support both old and
  new for N versions, then remove the old one. Never a hard break.
- **Consumer-driven contract testing** (Pact): consumers publish their expectations
  ("I call `GET /foo` and expect shape X"). Providers run those contracts in CI.
- **AsyncAPI / OpenAPI versioning**: publish a versioned schema; consumers pin to
  a version; a changelog event triggers adaptation tasks.

### Event-driven approaches

KEDA and similar systems trigger workers based on events (a Kafka topic, an SQS
queue). Cross-repo coordination can be modelled similarly: an API-change event
triggers "adaptation" tasks in downstream repos.

---

## Prototype: `cross_repo_coordinator.py`

A lightweight HTTP service (port 3008) that acts as the shared manifest and
event bus for cross-repo coordination. Python 3.11+ stdlib only.

### Data model

```
repos       id, url, version, status
            a registered repository with an agent working on it

deps        (consumer, provider) directed edge
            "consumer depends on provider's API"
            cycle detection prevents circular dependencies

events      id, type, repo_id, payload, notified, acks, created_at
            a change notification broadcast to affected repos
```

### Event lifecycle

```
1. lib-A agent changes a public API
2. POST /events  {type: "api_change", repo_id: "lib-a", payload: {...}}
3. Coordinator finds all consumers of lib-a; stores event with notified=[app-b, app-c]
4. app-b agent polls GET /events; sees the event; adapts its code
5. app-b agent posts POST /events  {type: "integration_result", repo_id: "app-b",
                                     payload: {ok: true, details: "tests pass"}}
6. app-b agent posts POST /events/<id>/ack  {repo_id: "app-b"}
7. When all notified repos ack, event leaves the active queue
```

### API summary

| Method | Path | Description |
|--------|------|-------------|
| POST | `/repos` | Register a repository |
| GET | `/repos` | List all repos |
| DELETE | `/repos/<id>` | Remove repo (also removes its deps) |
| POST | `/deps` | Add a dependency edge (with cycle detection) |
| GET | `/deps` | List all dependency edges |
| DELETE | `/deps/<consumer>/<provider>` | Remove a dependency edge |
| POST | `/events` | Publish an api_change / version_bump / integration_result |
| GET | `/events` | List unacknowledged events |
| POST | `/events/<id>/ack` | Acknowledge event as a consumer |
| GET | `/manifest` | Full snapshot: repos, deps, pending_events |
| POST | `/version` | Update a repo's version string |
| GET | `/status` | Counts: repos, deps, events, unacked |

### Cycle detection

Before adding `(consumer, provider)`, a DFS walks existing dependency edges to
check if `provider` can already reach `consumer`. If yes, the new edge would
form a cycle and is rejected (400). This prevents deadlocks where A waits for B
and B waits for A.

### Concurrency and persistence

- `threading.Lock` guards all state mutations.
- State is persisted to `logs/cross_repo_state.json` after every mutation.
- On restart, state is re-loaded; no events or deps are lost.
- A background reaper removes events older than `CROSS_REPO_EVENT_TTL` (default
  3600 s) to prevent unbounded growth.

---

## Comparison of Approaches

| Approach | Atomicity | Persistence | Push notifications | Cross-container | Complexity |
|----------|-----------|-------------|-------------------|-----------------|------------|
| Shared file manifest | TOCTOU race | ✓ (file) | ✗ (polling) | ✓ (volume) | Low |
| SQLite | ✓ (WAL) | ✓ | ✗ | ✓ (volume) | Medium |
| HTTP coordinator (chosen) | ✓ (lock) | ✓ (JSON) | SSE-ready | ✓ (network) | Medium |
| Message broker (Kafka/RabbitMQ) | ✓ | ✓ | ✓ | ✓ | High |

The HTTP coordinator matches the project's existing pattern (R1–R7 all use HTTP)
and adds no external dependencies.

---

## Integration with Other Research Components

| Component | Integration point |
|-----------|------------------|
| R2 Coordinator | On task completion in lib-A, coordinator POSTs an api_change event; assigns adaptation tasks to app-B workers |
| R3 Merge Gate | lib-A branch cannot merge until all consumers have acked the change |
| R4 Message Bus | Cross-repo events can be republished onto the message bus for real-time streaming |
| R7 Dynamic Scaler | Event backlog depth (unacked count) can drive scaling: more consumers to adapt → spin up more agents |

---

## Limitations and Future Work

1. **Agent awareness**: agents must actively poll `/events` and post acks. A
   push model (SSE subscription per repo) would reduce latency.
2. **API diff tooling**: the `payload` for `api_change` is free-form. Integration
   with semantic diff tools (language-specific AST comparison) would let the
   coordinator automatically classify breaking vs. non-breaking changes.
3. **Transitive fan-out**: currently only direct consumers are notified. If
   app-B depends on lib-A and svc-C depends on app-B, a breaking change in
   lib-A may cascade. A BFS/topological traversal of the dep graph would catch
   this.
4. **Contract testing**: integrating Pact-style contracts would allow the
   coordinator to automatically verify consumer expectations against provider
   changes before marking the event ready to ack.

---

## Recommendation

Use `cross_repo_coordinator.py` as a sidecar in multi-repo AgentMill deployments.
Register each repo on startup; agents publish events on API changes and poll for
unacked events targeting their repo. The manifest endpoint gives a dashboard a
full topology view. For teams with ≥ 3 interdependent repos, this is simpler
than embedding the logic in each agent's entrypoint and avoids the TOCTOU races
of shared-file approaches.
