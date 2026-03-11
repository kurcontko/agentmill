# AgentMill — Research: Respawning Loops & Ephemeral Containers

## Research Summary

This document synthesizes findings from Anthropic's C compiler article, the official Agent SDK docs, Ralph Wiggum patterns, and community implementations for building autonomous, self-respawning Claude agents running in ephemeral containers.

---

## 1. The Core Pattern: Respawning Agent Loop

From Nicholas Carlini's [C compiler article](https://www.anthropic.com/engineering/building-c-compiler), the fundamental pattern is dead simple:

```bash
#!/bin/bash
while true; do
    COMMIT=$(git rev-parse --short=6 HEAD)
    LOGFILE="agent_logs/agent_${COMMIT}.log"

    claude --dangerously-skip-permissions \
           -p "$(cat AGENT_PROMPT.md)" \
           --model claude-opus-4-6 &> "$LOGFILE"
done
```

**Key insight**: Claude doesn't need to be "always on." Each session is a fresh spawn that reads the current state (git history, progress files, READMEs) and picks up where the last session left off. The loop is the persistence mechanism, not the session.

### Why This Works
- Each new Claude session gets a **clean context window** (no pollution from previous runs)
- Progress is persisted through **git commits and files on disk**, not in-memory state
- If Claude crashes, gets confused, or kills itself (`pkill -9 bash` happened!), the loop just restarts
- The agent orients itself each time by reading progress docs and git history

---

## 2. Parallel Agents in Ephemeral Containers

Carlini's approach for running 16 agents in parallel:

```
Architecture:
┌─────────────────────────────────────────┐
│              Bare Git Repo              │
│            (/upstream repo)             │
└──────────┬──────────┬──────────┬────────┘
           │          │          │
    ┌──────▼──┐ ┌─────▼───┐ ┌───▼────────┐
    │ Docker  │ │ Docker  │ │ Docker     │
    │ Agent 1 │ │ Agent 2 │ │ Agent N    │
    │         │ │         │ │            │
    │ /workspace (local clone)           │
    │ /upstream (mounted bare repo)      │
    └─────────┘ └─────────┘ └────────────┘
```

### How it works:
1. A **bare git repo** is created as the shared upstream
2. Each agent gets a **fresh Docker container** with the repo mounted at `/upstream`
3. Each agent **clones locally** to `/workspace`
4. Agents **push/pull** to upstream to synchronize
5. When an agent finishes, the container is destroyed and a **new one is spawned**

### Task Locking (Coordination Without Orchestration)
- Agents claim tasks by writing lock files to `current_tasks/` directory (e.g., `current_tasks/parse_if_statement.txt`)
- Git's own merge mechanism prevents two agents from claiming the same task
- When done, agents remove the lock file and push
- **No orchestrator agent needed** - each agent decides what to work on next

---

## 3. Ralph Wiggum: The Official Plugin Pattern

[Ralph Wiggum](https://github.com/anthropics/claude-code/tree/main/plugins) is Claude Code's official autonomous loop plugin.

### Basic Usage
```bash
/ralph-loop "Migrate all tests from Jest to Vitest" \
  --max-iterations 50 \
  --completion-promise "All tests migrated"
```

### How It Works
- Uses Claude Code's **Stop hook** mechanism
- When Claude thinks it's done, the hook intercepts the exit (exit code 2)
- Re-feeds the original prompt, and Claude continues
- Each iteration sees modified files and git history from previous runs

### Minimal DIY Version (Geoffrey Huntley's original)
```bash
while :; do cat PROMPT.md | claude ; done
```

### When to Use
- Large refactors, framework migrations
- Batch operations (ticket triage, doc generation)
- Test coverage expansion
- Greenfield builds with iterative refinement
- Anything with **clear, programmatic completion criteria**

---

## 4. Agent SDK: Production Hosting Patterns

The [Claude Agent SDK hosting guide](https://platform.claude.com/docs/en/agent-sdk/hosting) defines four deployment patterns:

### Pattern 1: Ephemeral Sessions (Best for respawning agents)
- **New container per task**, destroyed when complete
- Perfect for autonomous coding tasks, bug fixes, processing jobs
- Cheapest (~$0.05/hr per container, tokens are the real cost)

### Pattern 2: Long-Running Sessions
- Persistent containers for proactive agents
- Multiple Claude processes per container
- Good for email agents, monitoring, chat bots

### Pattern 3: Hybrid Sessions (Best for intermittent autonomy)
- Ephemeral containers **hydrated with history/state** from a database
- Uses SDK's **session resumption** features
- Spins down when idle, resumes with full context
- Great for research agents, project managers

### Pattern 4: Single Container Multi-Agent
- Multiple Claude SDK processes in one container
- Agents can collaborate directly
- Must handle file conflicts carefully

### Recommended Sandbox Providers
- **Modal Sandbox** - modal.com
- **Cloudflare Sandboxes** - sandbox-sdk
- **E2B** - e2b.dev
- **Fly Machines** - fly.io
- **Daytona** - daytona.io
- **Vercel Sandbox**

### Resource Requirements per Instance
- 1 GiB RAM, 5 GiB disk, 1 CPU (minimum)
- Outbound HTTPS to `api.anthropic.com`

---

## 5. Designing for Autonomous Success

### Key Lessons from the C Compiler Project

#### Write Tests That Guide the Agent
- The **test verifier must be nearly perfect** - Claude will solve whatever the tests say to solve
- Build CI pipelines with strict enforcement so new commits can't break existing code
- Use a known-good oracle (e.g., GCC) for comparison-based testing

#### Design the Environment for Claude, Not Humans
- **Context window pollution**: Don't print thousands of lines. Print summaries. Log details to files with `ERROR` on the same line as the reason (grep-friendly)
- **Time blindness**: Claude can't tell time. Add incremental progress printing. Include `--fast` flags that run 1-10% random samples
- **Orientation**: Maintain extensive READMEs and progress files. Each fresh agent needs to orient itself quickly
- **Pre-compute summaries**: Don't make Claude count or aggregate - do it in the test harness

#### Make Parallelism Easy
- When there are many distinct failing tests, parallelism is trivial (each agent picks a different test)
- For monolithic tasks (compiling one giant project), use **oracle-based decomposition**: randomly compile most files with a known-good tool, only test a subset with the new tool
- Use **delta debugging** to find interacting failures

#### Specialize Agent Roles
- Dedicated agent for **deduplicating code**
- Dedicated agent for **performance optimization**
- Dedicated agent for **code quality/review**
- Dedicated agent for **documentation**
- Dedicated agent for **the actual task**

---

## 6. Practical Implementation Blueprint

### Minimal Respawning Agent Setup

```bash
# Directory structure
project/
├── AGENT_PROMPT.md          # What the agent should do
├── PROGRESS.md              # Agent-maintained progress tracking
├── current_tasks/           # Lock files for task coordination
├── agent_logs/              # Logs from each session
├── tests/                   # Test suite the agent targets
└── docker-compose.yml       # Container orchestration
```

### Dockerfile for Agent Container
```dockerfile
FROM node:20-slim

RUN npm install -g @anthropic-ai/claude-code
RUN apt-get update && apt-get install -y git bash

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

### entrypoint.sh (Respawning Loop in Container)
```bash
#!/bin/bash
set -e

# Clone from upstream
git clone /upstream /workspace/repo
cd /workspace/repo

# The infinite respawn loop
while true; do
    COMMIT=$(git rev-parse --short=6 HEAD)
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOGFILE="/workspace/logs/agent_${TIMESTAMP}_${COMMIT}.log"

    # Pull latest from other agents
    git pull origin main --rebase || git rebase --abort

    # Run Claude autonomously
    claude --dangerously-skip-permissions \
           -p "$(cat AGENT_PROMPT.md)" \
           --model claude-opus-4-6 \
           2>&1 | tee "$LOGFILE"

    # Push changes if any
    git add -A
    git diff --cached --quiet || {
        git commit -m "Agent auto-commit $(date +%H:%M:%S)"
        git push origin main || {
            git pull --rebase origin main
            git push origin main
        }
    }
done
```

### docker-compose.yml (Multi-Agent)
```yaml
services:
  upstream:
    image: alpine/git
    volumes:
      - upstream-repo:/repo
    command: >
      sh -c "git init --bare /repo || true"

  agent-worker:
    build: .
    deploy:
      replicas: 4  # Number of parallel agents
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
    volumes:
      - upstream-repo:/upstream:ro
      - ./AGENT_PROMPT.md:/workspace/AGENT_PROMPT.md:ro
    restart: always  # Auto-respawn on crash

volumes:
  upstream-repo:
```

### AGENT_PROMPT.md Template
```markdown
# Your Task

You are an autonomous coding agent working on [PROJECT].

## Orientation
1. Read PROGRESS.md to understand current state
2. Read README.md for project architecture
3. Run `./test.sh --fast` to see current test status
4. Check `current_tasks/` to see what other agents are working on

## Working Protocol
1. Pick the NEXT MOST IMPORTANT failing test or task
2. Create a lock file: `current_tasks/your_task_name.txt`
3. Fix the issue with minimal, focused changes
4. Run the full test suite
5. Update PROGRESS.md with what you did
6. Remove your lock file
7. Commit and push

## Rules
- Never break existing passing tests
- Keep changes small and focused
- If stuck for more than 3 attempts, document the issue in PROGRESS.md and move on
- Write ERROR on the same line as error descriptions in logs
```

---

## 7. Cloud-Native Approach (Agent SDK)

For production systems, use the Claude Agent SDK instead of CLI wrapping:

```python
# Python Agent SDK - Ephemeral Container Pattern
from claude_agent_sdk import Agent, Session

async def run_agent_task(task_description: str, repo_path: str):
    agent = Agent(
        model="claude-opus-4-6",
        max_turns=100,
        permissions={"allow_all": True},
        working_directory=repo_path,
    )

    session = await agent.create_session()

    result = await session.send_message(
        f"""You are an autonomous coding agent.
        Current task: {task_description}
        Read PROGRESS.md first, then work on the task."""
    )

    return result
```

### Session Resumption (Hybrid Pattern)
```python
# Save session state
session_id = session.id
await session.save()

# Later, in a new container, resume
session = await agent.resume_session(session_id)
```

---

## 8. Cost & Scale Considerations

From the C compiler project:
- **2,000 Claude Code sessions** over 2 weeks
- **2 billion input tokens, 140 million output tokens**
- **~$20,000 total cost**
- 16 agents running in parallel
- Result: 100,000-line working C compiler

### Cost Optimization Tips
- Use `--fast` test sampling (1-10% random per agent, deterministic per-agent but random across VMs)
- Set `maxTurns` to prevent runaway sessions
- Use cheaper models (Haiku) for specialized agents (docs, code quality) and Opus for core work
- Container cost is negligible (~$0.05/hr) - tokens dominate

---

## 9. Key Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Agents overwrite each other | Git-based locking via `current_tasks/` |
| Context window pollution | Log to files, print summaries only |
| Runaway costs | `--max-iterations`, `maxTurns` limits |
| Breaking existing functionality | CI pipeline, strict test regression checks |
| Agent gets stuck in loops | Document failed approaches, move-on rules |
| Security (arbitrary code exec) | Docker containers, no host access, network restrictions |
| Agent kills itself | `restart: always` in Docker, the loop pattern |

---

## 10. Prompt Engineering — Anthropic's Official Guide

From Anthropic's [Prompt Engineering Interactive Tutorial](https://github.com/anthropics/prompt-eng-interactive-tutorial) (32k stars) and [Courses repo](https://github.com/anthropics/courses) (19k stars). A 9-chapter tutorial with exercises, covering beginner to advanced techniques.

### The 10-Element Complex Prompt Structure

The tutorial's capstone (Chapter 9) defines a reusable blueprint for production prompts:

| # | Element | Purpose | Ordering |
|---|---------|---------|----------|
| 1 | `user` role | Always start with `user` turn | Required first |
| 2 | Task context | Role + overarching goal | Early |
| 3 | Tone context | Desired communication style | Early |
| 4 | Detailed task description + rules | Specific behavior + "outs" | Middle |
| 5 | Examples | Few-shot examples in `<example>` tags | Middle |
| 6 | Input data | Variable content in XML tags | Middle |
| 7 | Immediate task request | Explicit reminder of what to do now | Near end |
| 8 | Precognition | "Think step by step before answering" | Near end |
| 9 | Output formatting | How to format the response | Near end |
| 10 | Prefill | Assistant-turn starter text | Very end |

**Key principle**: Start with all 10 elements, then slim down through iteration.

### Core Techniques by Chapter

#### Ch 1 — Basic Prompt Structure
- Messages API requires: `model`, `max_tokens`, `messages` (alternating user/assistant, must start with user)
- System prompt is separate from messages array — provides persistent context, instructions, guidelines
- Temperature: 0 = deterministic, 1 = creative

#### Ch 2 — Being Clear and Direct
- **Golden Rule**: Show your prompt to a colleague. If they're confused, Claude will be too
- Skip preambles explicitly: `"Skip the preamble; go straight into the poem."`
- Force definitive answers: `"If you absolutely had to pick one, who would it be?"`
- Small details matter — typos and ambiguity degrade output quality

#### Ch 3 — Role Prompting
- Assigning roles changes tone, perspective, and reasoning accuracy
- More detail in role description = better results
- Role prompting **improves logic/math accuracy** (e.g., `"You are a logic bot"` fixes reasoning errors)
- Combine role with audience context for further control

#### Ch 4 — Separating Data from Instructions
- Build **prompt templates** with f-strings; substitute user data at runtime
- **XML tags are critical** — Claude was specifically trained to recognize them as structural delimiters
- Without tags, Claude can mistake data for instructions (e.g., rewriting "Yo Claude" as part of an email)
- No "magic" tag names — use whatever makes semantic sense

#### Ch 5 — Formatting Output & Prefilling
- **XML-tagged output**: Ask Claude to wrap responses in tags for programmatic extraction
- **Response prefilling**: Put text in terminal `assistant` turn to force Claude to continue from that point
  ```python
  messages=[
      {"role": "user", "content": prompt},
      {"role": "assistant", "content": "{"}  # Forces JSON output
  ]
  ```
- **Stop sequences**: Pass a closing XML tag to `stop_sequences` to cut generation — saves tokens

#### Ch 6 — Precognition (Thinking Step by Step)
- Giving Claude thinking time **dramatically improves accuracy** on complex/nuanced tasks
- Thinking must be "out loud" — asking Claude to think silently produces no benefit
- **Argue both sides first**: Use `<positive-argument>` and `<negative-argument>` tags before final answer
- **Ordering sensitivity**: Claude tends to favor the second option. Be aware when designing binary choices
- Use for: sentiment with sarcasm, multi-step reasoning, fact-checking, classification

#### Ch 7 — Few-Shot Examples
- **"Probably the single most effective tool in knowledge work"** (per the tutorial)
- Zero-shot (no examples) → One-shot → Few-shot (generally more = better)
- Best for: tone/style that's hard to describe, complex output formats, edge cases
- Claude can extrapolate format patterns from just a few examples

#### Ch 8 — Avoiding Hallucinations
- **Give Claude an "out"**: `"Only answer if you know with certainty"`
- **Evidence-first pattern**: Extract quotes in `<quotes>` tags before answering; say "I cannot find a direct answer" if no quote matches
- Use `temperature=0` for factual tasks
- Combine with role prompting and thinking steps for maximum accuracy

#### Ch 9 — Complex Prompts from Scratch
- Assemble all 10 elements into a single structured prompt (see table above)
- **Prompt engineering is scientific trial and error** — test on representative inputs, prune what isn't needed

#### Appendix — Prompt Chaining
- Pass Claude's output from one call as input to the next
- Use cases: self-correction ("double-check your work"), iterative refinement, function chaining
- Combine with an "out" to prevent overcorrection: `"If the list is already correct, say so"`

### Techniques Most Relevant to Autonomous Agents

For AGENT_PROMPT.md design, these techniques are highest-value:

1. **XML tags everywhere** — separate task instructions from input data, structure output for parsing
2. **Role prompting** — `"You are an autonomous coding agent specializing in..."` improves reasoning
3. **Precognition** — `"Think step by step about which task to pick next before acting"`
4. **Give an out** — `"If stuck for more than 3 attempts, document and move on"` prevents infinite loops
5. **Evidence-first** — `"Read PROGRESS.md and cite the current state before deciding next steps"`
6. **Few-shot examples** — Show example git commit messages, task-picking decisions, or progress updates
7. **Prompt chaining** — The respawning loop IS prompt chaining: each session's git commits are the "output" fed into the next session's context
8. **10-element structure** — Use as a checklist when writing AGENT_PROMPT.md files

---

## Sources

- [Building a C compiler with a team of parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler) - Nicholas Carlini, Anthropic
- [Hosting the Agent SDK](https://platform.claude.com/docs/en/agent-sdk/hosting) - Anthropic Docs
- [Ralph Wiggum: Autonomous Loops for Claude Code](https://paddo.dev/blog/ralph-wiggum-autonomous-loops/) - paddo.dev
- [ralph-claude-code](https://github.com/frankbria/ralph-claude-code) - GitHub
- [Running Claude Code Agents in Docker Containers](https://medium.com/@dan.avila7/running-claude-code-agents-in-docker-containers-for-complete-isolation-63036a2ef6f4)
- [claude-agent-sdk-container](https://github.com/receipting/claude-agent-sdk-container) - GitHub
- [Netclode: Self-hosted cloud coding agent](https://stanislas.blog/2026/02/netclode-self-hosted-cloud-coding-agent/)
- [Anthropic Prompt Engineering Interactive Tutorial](https://github.com/anthropics/prompt-eng-interactive-tutorial) - GitHub (32k stars)
- [Anthropic Courses](https://github.com/anthropics/courses) - GitHub (19k stars)
