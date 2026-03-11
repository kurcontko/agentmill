# TASK — Autonomous Agent Coordination Research

## How This Works

Each task is a research+implementation track. The agent picks the highest-priority unblocked task, creates or resumes a branch for it, does research, implements a prototype, commits progress, and moves on. If a task needs clarification, mark it `[NEEDS-CLARIFICATION]` and switch to another.

Branch naming: `research/<short-name>` (e.g. `research/work-stealing-queue`)

## Status Key

- `[ ]` — Not started
- `[~]` — In progress (branch exists, work ongoing)
- `[x]` — Done (merged or ready for review)
- `[?]` — Needs clarification from user
- `[!]` — Blocked

---

## P0 — Core Coordination Alternatives

### [R1] Work-Stealing Queue
- **Branch**: `research/work-stealing-queue`
- **Status**: `[x]`
- **Goal**: Replace file-based task claiming (`current_tasks/`) with an explicit work-stealing queue. Evaluate: shared file queue vs. lightweight HTTP queue vs. Redis-backed queue.
- **Deliverable**: Working prototype where agents dequeue tasks atomically. Compare throughput vs. current git-based claiming. Write findings in `docs/research/work-stealing-queue.md`.
- **Research**: Look at how distributed work-stealing works (Cilk, Go scheduler, Tokio). What's the simplest version that works with Docker containers sharing a volume?

### [R2] Hierarchical / Supervisor-Worker Model
- **Branch**: `research/hierarchical-coordination`
- **Status**: `[x]`
- **Goal**: Implement a coordinator agent that decomposes tasks and assigns them to worker agents. The coordinator doesn't write code — it plans, assigns, reviews, and merges.
- **Deliverable**: A `coordinator.py` or coordinator entrypoint that reads TASK.md, breaks tasks into subtasks, assigns branches to workers, monitors progress, and merges results. Document in `docs/research/hierarchical-coordination.md`.
- **Research**: Study CrewAI, AutoGen, and Devin's orchestration model. What's the minimal viable coordinator?

### [R3] Consensus-Based Merge Gate
- **Branch**: `research/hierarchical-coordination`
- **Status**: `[x]`
- **Goal**: Before a branch merges, other agents review/validate it (run tests, check quality). Implement a lightweight consensus protocol where N-of-M agents must approve.
- **Deliverable**: A merge-gate script or service that blocks merge until validation agents sign off. Could use git notes, a shared approval file, or a simple HTTP endpoint. Document in `docs/research/consensus-merge.md`.
- **Research**: Look at how CI-gated merges work, but with agents as reviewers instead of CI pipelines. How do blockchain consensus models (simple majority, quorum) translate here?

---

## P1 — Communication & Awareness

### [R4] Agent Message Bus
- **Branch**: `research/message-bus`
- **Status**: `[ ]`
- **Goal**: Give agents a way to send messages to each other beyond git commits. Evaluate: shared file mailbox, Unix named pipes, lightweight pub/sub (SSE-based reusing existing server), or a simple SQLite-backed queue.
- **Deliverable**: A messaging module agents can import/source. Agents can broadcast status, request help, or signal task completion. Document in `docs/research/message-bus.md`.
- **Research**: What's the simplest IPC that works across Docker containers with shared volumes? How do ant colonies and bee swarms communicate (stigmergy)?

### [R5] Shared Workspace Awareness
- **Branch**: `research/workspace-awareness`
- **Status**: `[ ]`
- **Goal**: Agents should know what files others are currently editing to avoid conflicts proactively (not just reactively via rebase). Implement file-level locking or advisory locks.
- **Deliverable**: A lock manager that agents check before editing files. Could be `.locks/` directory with agent-ID files, or extend `current_tasks/` with file-level granularity. Document in `docs/research/workspace-awareness.md`.
- **Research**: How do distributed file systems handle advisory locks? Look at NFS locks, etcd leases. What's the Docker-volume-friendly equivalent?

---

## P2 — Scaling & Specialization

### [R6] Role-Based Agent Specialization
- **Branch**: `research/agent-roles`
- **Status**: `[ ]`
- **Goal**: Instead of N identical agents, assign roles: architect, implementer, tester, reviewer, documenter. Each role gets a different prompt and different permissions.
- **Deliverable**: Role-specific prompt templates in `prompts/roles/` and a role-assignment mechanism (env var, config file, or auto-assignment). Document in `docs/research/agent-roles.md`.
- **Research**: Study the Carlini C compiler project's role breakdown. How does CrewAI assign roles? What's the optimal role mix for a 3-5 agent team?

### [R7] Dynamic Agent Scaling
- **Branch**: `research/dynamic-scaling`
- **Status**: `[ ]`
- **Goal**: Automatically spawn/kill agent containers based on workload. If the task queue is deep, scale up. If idle, scale down.
- **Deliverable**: A scaler script that monitors task queue depth and uses `docker compose scale` or direct Docker API to adjust agent count. Document in `docs/research/dynamic-scaling.md`.
- **Research**: How does Kubernetes HPA work? What's the simplest autoscaler for Docker Compose? Look at KEDA for event-driven scaling patterns.

### [R8] Cross-Repo Agent Coordination
- **Branch**: `research/cross-repo`
- **Status**: `[ ]`
- **Goal**: Agents working on different repos that depend on each other (e.g., a library and its consumers). How do they coordinate API changes, version bumps, and integration testing?
- **Deliverable**: A prototype where agent-A changes a library API and agent-B adapts the consumer, coordinated through a shared manifest or event. Document in `docs/research/cross-repo.md`.
- **Research**: How do monorepo tools (Nx, Turborepo, Bazel) handle cross-project dependencies? How do microservice teams coordinate breaking changes?

---

## P3 — Resilience & Recovery

### [R9] Checkpoint & Rollback Protocol
- **Branch**: `research/checkpoint-rollback`
- **Status**: `[ ]`
- **Goal**: Periodically snapshot agent state so that if an agent goes off-track, it can roll back to the last good checkpoint rather than starting over.
- **Deliverable**: A checkpoint mechanism using git tags or branches. An evaluation step after each iteration that decides keep/rollback. Document in `docs/research/checkpoint-rollback.md`.
- **Research**: How do database transaction logs work? How does git bisect find regressions? Can we automate "did this iteration improve or harm the codebase?"

### [R10] Conflict Resolution Strategies
- **Branch**: `research/conflict-resolution`
- **Status**: `[ ]`
- **Goal**: Go beyond simple rebase-retry. Implement smarter conflict resolution: semantic merge, LLM-assisted merge, or split-and-reassign conflicting work.
- **Deliverable**: A conflict resolver that can handle common conflict patterns automatically. Falls back to splitting the conflicting files into separate tasks. Document in `docs/research/conflict-resolution.md`.
- **Research**: Look at semantic merge tools (SemanticMerge, IntelliMerge). Can an LLM resolve merge conflicts better than git's default? What conflict patterns are most common in multi-agent codebases?

---

## Notes for the Research Agent

- **Start with what exists**: Before implementing, check if there's an existing branch with prior work.
- **Prototype first**: Don't over-engineer. Get something working, document findings, iterate.
- **Compare to baseline**: The current git-based coordination is the baseline. Every alternative should justify its added complexity.
- **Keep it stdlib**: Match the project convention — Python 3.11+ stdlib only for core components. Research docs can reference external tools.
- **Create `docs/research/`** directory for all research writeups.
- **Update this file** with status changes as you work.
