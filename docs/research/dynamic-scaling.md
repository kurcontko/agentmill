# R7: Dynamic Agent Scaling

## Goal

Automatically spawn/kill agent containers based on workload. When the task queue is deep, scale up. When idle, scale down.

## Background

### Kubernetes HPA

The Horizontal Pod Autoscaler adjusts replica count in a control loop:

1. Fetch current metric (CPU, custom queue depth)
2. Compute `desired = ceil(current_metric / target_metric_per_pod)`
3. Clamp to `[minReplicas, maxReplicas]`
4. Apply scale command

Key lessons for AgentMill:
- **Hysteresis** — HPA only scales down when utilization is below `(current-1)/current` of threshold to prevent thrashing.
- **Cooldowns** — separate `scaleUpStabilizationWindowSeconds` and `scaleDownStabilizationWindowSeconds` prevent oscillation.
- **Custom metrics** — queue depth maps directly to HPA's "external metric" concept.

### KEDA (Kubernetes Event-Driven Autoscaling)

KEDA scales to/from zero based on event source length (Kafka lag, Redis list length, HTTP queue depth). Key insight: **scale to zero** is safe when tasks are event-driven — no idle costs. For AgentMill, scaling to zero means keeping `min_agents = 0` and trusting the queue to re-trigger scale-up.

### Docker Compose scaling

`docker compose up -d --scale <service>=<N>` scales a service to N replicas without recreating existing containers. The `--no-recreate` flag preserves running containers. This is the lowest-friction approach for AgentMill.

Limitation: Compose `--scale` only works if the service doesn't have `container_name` set (it generates names like `agentmill-agent-1-1`, `agentmill-agent-1-2`, etc.). Multi-agent services (`agent-1`, `agent-2`, `agent-3`) in AgentMill already follow this pattern.

## Approach Comparison

| Approach | Complexity | Docker dependency | Latency |
|---|---|---|---|
| Shell wrapper calling `docker compose` | Low | docker CLI | ~2s |
| Docker Engine REST API (unix socket) | Medium | /var/run/docker.sock | ~100ms |
| docker-py library | Medium | third-party dep | ~100ms |
| Kubernetes/Nomad operator | High | full orchestrator | varies |

**Recommendation**: Use `docker compose up --scale` for simplicity. Fall back to Docker Engine API for tighter integration or when `docker` CLI isn't available in the scaler container.

## Implementation: `scaler.py`

### Architecture

```
┌─────────────────────────────────────────────────────┐
│  scaler.py (port 3007)                               │
│                                                      │
│  ┌──────────────┐    ┌──────────────────────────┐   │
│  │  Poll loop   │───▶│  Scaler state machine    │   │
│  │  (bg thread) │    │  - policy (min/max/ratio) │   │
│  └──────────────┘    │  - cooldown timers        │   │
│         │            │  - hysteresis             │   │
│         ▼            └──────────┬───────────────┘   │
│  fetch_pending()                │                   │
│  (queue_server or               ▼                   │
│   coordinator)       ┌──────────────────┐           │
│                      │  Backend         │           │
│                      │  - ComposeBackend │           │
│                      │  - DockerAPI     │           │
│                      │  - NoneBackend   │           │
│                      └──────────────────┘           │
│                                                     │
│  HTTP API: /status /policy /scale /pause /resume   │
└─────────────────────────────────────────────────────┘
         │
         │ queue depth
         ▼
┌─────────────────┐    ┌─────────────────┐
│  queue_server   │    │  coordinator    │
│  (port 3002)    │ OR │  (port 3003)    │
└─────────────────┘    └─────────────────┘
```

### Scaling Algorithm

```python
desired = clamp(ceil(pending / tasks_per_agent), min_agents, max_agents)
```

**Scale up** when `desired > current` and `now - last_scale_up > up_cooldown`.

**Scale down** when `desired < current` AND `pending < (current - 1) * tasks_per_agent` (hysteresis) AND `now - last_scale_down > down_cooldown`.

Default parameters:
- `min_agents = 1`, `max_agents = 8`
- `tasks_per_agent = 3`
- `scale_up_cooldown = 30s`, `scale_down_cooldown = 120s`

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SCALER_PORT` | 3007 | HTTP API port |
| `SCALER_QUEUE_URL` | `http://localhost:3002` | queue_server URL |
| `SCALER_COORDINATOR_URL` | `` | coordinator URL (takes priority if set) |
| `SCALER_COMPOSE_SERVICE` | `agent-1` | Compose service to scale |
| `SCALER_COMPOSE_FILE` | `docker-compose.yml` | Compose file path |
| `SCALER_MIN_AGENTS` | 1 | Minimum replicas |
| `SCALER_MAX_AGENTS` | 8 | Maximum replicas |
| `SCALER_TASKS_PER_AGENT` | 3 | Tasks per agent (scaling ratio) |
| `SCALER_UP_COOLDOWN` | 30 | Scale-up cooldown (seconds) |
| `SCALER_DOWN_COOLDOWN` | 120 | Scale-down cooldown (seconds) |
| `SCALER_POLL_INTERVAL` | 15 | Poll interval (seconds) |
| `SCALER_DRY_RUN` | false | Log intent without executing |
| `SCALER_BACKEND` | `compose` | `compose`, `docker_api`, `none` |
| `SCALER_STATE_FILE` | `logs/scaler_state.json` | Persistent state path |

### HTTP API

```
GET  /status     → {"current": N, "desired": N, "pending": N, "policy": {...}, "paused": bool}
GET  /history    → {"events": [...]}
POST /policy     body: {"min": N, "max": N, "tasks_per_agent": N, "scale_up_cooldown": N, ...}
POST /scale      body: {"count": N}   # manual override
POST /pause      → disable auto-scaling
POST /resume     → re-enable auto-scaling
```

### Usage

**Run as a service:**
```bash
SCALER_COMPOSE_SERVICE=agent-1 \
SCALER_QUEUE_URL=http://localhost:3002 \
SCALER_MAX_AGENTS=5 \
python3 scaler.py
```

**Dry-run (no docker calls):**
```bash
SCALER_DRY_RUN=true SCALER_BACKEND=none python3 scaler.py
```

**Add to docker-compose.yml:**
```yaml
scaler:
  build: .
  entrypoint: ["python3", "/scaler.py"]
  environment:
    SCALER_QUEUE_URL: http://queue-server:3002
    SCALER_COMPOSE_SERVICE: agent-1
    SCALER_MAX_AGENTS: 8
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
    - ./docker-compose.yml:/docker-compose.yml:ro
    - ./logs:/workspace/logs
```

Note: The scaler container needs `docker` CLI and access to `docker.sock` to execute compose commands.

## Integration with Other Components

- **R1 (queue_server)**: Primary metric source. `/status` endpoint returns `pending` count.
- **R2 (coordinator)**: Alternative metric source when `SCALER_COORDINATOR_URL` is set. Provides task-level visibility beyond raw queue depth.
- **R6 (agent_roles)**: When scaling up, the role manager auto-assigns roles to new agents. Scaler does not need role-awareness.

## Findings

1. **Simplest viable autoscaler**: The full loop from "queue depth exceeds threshold" to "new container running" takes ~5 seconds with `docker compose` — fast enough for multi-minute agent iterations.

2. **Hysteresis is critical**: Without it, a queue at exactly `tasks_per_agent` tasks triggers constant up/down oscillation. The `(current-1)*tasks_per_agent` scale-down threshold provides a stable operating band.

3. **Separate cooldowns**: Scale-up should be aggressive (30s cooldown); scale-down should be conservative (120s) because spinning down agents mid-task wastes work.

4. **Scale to zero is possible**: Set `min_agents=0` for fully elastic deployments. Re-triggering from zero takes ~10s, acceptable if tasks queue up for minutes.

5. **Docker Compose --scale limitation**: Services must not have a static `container_name`. AgentMill's numbered services (`agent-1`, `agent-2`, `agent-3`) already work. Scaling `agent-1` to N replicas creates `agentmill-agent-1-1` ... `agentmill-agent-1-N`.

6. **Vs. Kubernetes HPA**: HPA is battle-tested but requires a K8s cluster. For local multi-agent Docker Compose setups, this scaler provides 80% of HPA's value with 5% of the infrastructure complexity.
