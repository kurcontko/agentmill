# Research: Role-Based Agent Specialization

## Summary

Instead of running N identical agents all reading the same generic prompt, we assign each agent a **role** — architect, implementer, tester, reviewer, or documenter — with a tailored prompt and restricted permissions. Specialization reduces duplicated effort, clarifies responsibility, and enables a division-of-labour similar to a small engineering team.

This document covers the design rationale, role definitions, the auto-assignment algorithm, integration with the coordinator (R2), and trade-offs versus homogeneous agents.

---

## Motivation

The baseline AgentMill setup runs multiple identical agents against a shared task queue. Each agent reads the same prompt and can do anything: write code, write tests, update docs, review PRs. This causes:

- **Overlap**: two agents independently write tests for the same function.
- **Drift**: documenter work is skipped because every agent prioritises code.
- **Merge noise**: merge gate (R3) has no concept of who is qualified to vote.

Role-based specialization fixes this by giving each agent a focused mandate and routing tasks to the right role via the coordinator (R2).

---

## Prior Art

| System | Role model |
|---|---|
| **CrewAI** | Explicit `role`, `goal`, `backstory` fields per agent. Roles are free-form strings with associated tools. Task routing is done by the crew orchestrator. |
| **AutoGen** | `AssistantAgent`, `UserProxyAgent`, `GroupChat` with a manager that selects the next speaker. Roles implicit in system prompt + tool set. |
| **Devin** | Single agent with planner/executor sub-modules. Not multi-agent but shows value of separating planning from execution. |
| **Carlini C compiler** | 4-agent team: parser, codegen, optimizer, tester — each with independent context. Architect role implicit in the task decomposition prompt. |

Key insight from all of these: **roles are primarily prompt + permission constraints**. The underlying LLM capability is the same; what changes is the system prompt, the task filter, and what actions are allowed.

---

## Role Definitions

| Role | Writes code? | Writes tests? | Writes specs? | Writes docs? | Votes merge gate? |
|---|---|---|---|---|---|
| `architect` | ✗ | ✗ | ✓ | ✗ | ✗ |
| `implementer` | ✓ | ✗ | ✗ | ✗ | ✗ |
| `tester` | ✗ | ✓ | ✗ | ✗ | ✓ |
| `reviewer` | ✗ | ✗ | ✗ | ✓ (review notes) | ✓ |
| `documenter` | ✗ | ✗ | ✗ | ✓ | ✗ |

### Optimal team mix (by size)

| Team size | architect | implementer | tester | reviewer | documenter |
|---|---|---|---|---|---|
| 1 | — | 1 | — | — | — |
| 2 | 1 | 1 | — | — | — |
| 3 | 1 | 2 | — | — | — |
| 4 | 1 | 2 | 1 | — | — |
| 5 | 1 | 2 | 1 | 1 | — |
| 6 | 1 | 2 | 1 | 1 | 1 |
| 7+ | 1 | N-5 | 1 | 1 | 1 |

### Rationale

- **architect** is needed as soon as tasks are complex enough to decompose (team ≥ 2).
- **tester** joins when there's enough code to verify (team ≥ 4); below that, implementers run basic tests themselves.
- **reviewer** is only useful when there's a merge gate (team ≥ 5); code review adds latency for solo/pair work.
- **documenter** is a luxury until the codebase is large enough to need maintained docs (team ≥ 6).

---

## Implementation: `agent_roles.py`

An HTTP service (port 3006) that agents call on startup to receive their role assignment.

### API

```
POST /register          {"agent_id": "...", "preferred_role": "..."}
                         -> {"agent_id": ..., "role": ..., "config": {...}}
GET  /role/<agent_id>   -> {"agent_id": ..., "role": ..., "config": {...}}
POST /request_role      {"agent_id": "...", "role": "..."}
                         -> 200 {"ok": true, "role": ...} | 409 (cap reached)
POST /release/<agent_id> -> 200 {"ok": true}
GET  /status            -> {"agents": [...], "distribution": {...}, "optimal_mix": {...}}
GET  /roles             -> {"roles": [{name, description, prompt_path, ...}]}
```

### Auto-Assignment Algorithm

1. Compute `optimal_mix(team_size)` — the ideal role counts for the current team size.
2. Honour `preferred_role` if it is under its `max_per_team` cap.
3. Otherwise, iterate roles in priority order (`implementer > architect > tester > reviewer > documenter`) and assign the most under-represented role relative to the optimal mix.
4. If all roles are at cap, fall back to `implementer`.

The algorithm runs under a single `threading.Lock`, so concurrent registrations never violate the architect cap (max=1).

### Config Response

Each `register` response includes:

```json
{
  "role": "tester",
  "config": {
    "prompt_path": "prompts/roles/tester.md",
    "permissions": {"write_tests": true, "vote_merge_gate": true, ...},
    "coordinator_role_filter": ["tester"],
    "description": "Writes and runs tests, votes in merge gate."
  }
}
```

The entrypoint uses `prompt_path` to select the agent's system prompt, and `coordinator_role_filter` to request only matching task types from the coordinator.

### Env Var Override

Set `AGENT_ROLE=<role>` to bypass auto-assignment. Useful for Docker Compose service-level pinning:

```yaml
services:
  agent-arch:
    environment:
      AGENT_ROLE: architect
  agent-impl-1:
    environment:
      AGENT_ROLE: implementer
  agent-tester:
    environment:
      AGENT_ROLE: tester
```

The helper `resolve_prompt_file()` checks `AGENT_ROLE` → `PROMPT_FILE` → default, making it easy to integrate into entrypoints.

---

## Role Prompt Templates (`prompts/roles/`)

Each role has a dedicated prompt file:

| File | Purpose |
|---|---|
| `architect.md` | Decompose TASK.md tasks into numbered subtask spec files |
| `implementer.md` | Implement application code from subtask specs |
| `tester.md` | Write tests, run the suite, vote on merge gate |
| `reviewer.md` | Review diffs, check OWASP top 10, cast merge gate votes |
| `documenter.md` | Write `docs/research/`, keep `PROGRESS.md` current |

Prompts are intentionally short (~60 lines) to leave the bulk of the context window for code and task context. They define: **what to do**, **what not to do**, **commit message convention**, and **coordination API calls**.

---

## Integration with Other Components

| Component | Integration point |
|---|---|
| **R2 Coordinator** | `coordinator_role_filter` in config → `POST /assign` filters tasks by role |
| **R3 Merge Gate** | tester + reviewer roles are the designated validators; others are excluded |
| **R4 Message Bus** | roles publish typed events (`task_start`, `task_complete`, `review_complete`) |
| **R5 Lock Manager** | implementer acquires file locks; architect/documenter check before writing specs |

---

## Trade-offs

### Specialization vs. Homogeneity

| Factor | Homogeneous | Role-based |
|---|---|---|
| Setup complexity | Low — one prompt | Higher — 5 prompts + role manager |
| Idle waste | Low — any agent can do anything | Higher — tester idles if no code is ready |
| Quality | Medium — generalists | Higher — each role optimised for its task |
| Throughput (small team) | Higher | Lower (bottlenecks at architect/tester) |
| Throughput (large team) | Diminishing (redundancy) | Scales better with specialization |

**Verdict**: For teams of 1–3 agents, homogeneous is better — the overhead of coordination outweighs the benefits. For 4+ agents, role-based specialization improves quality and reduces duplicated effort. The `AGENT_ROLE` env var fallback and the `resolve_prompt_file()` helper make it zero-cost to run homogeneous when roles aren't needed.

### Hard vs. Soft Caps

`max_per_team` is a **soft recommendation** used for auto-assignment priority, not an absolute hard limit. `request_role` enforces caps (returns 409), but auto-registration can exceed caps if the team is large and all roles are saturated (overflow goes to implementer). This avoids stranding agents with no role when caps are misconfigured.

---

## Verification

```bash
python3 -m unittest tests.test_agent_roles  # 49 tests, OK
python3 -m py_compile agent_roles.py         # syntax check
```
