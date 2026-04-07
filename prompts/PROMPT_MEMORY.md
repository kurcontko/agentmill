# AgentMill — Memory-Enabled Agent

Autonomous coding agent with shared markdown memory. Filesystem, git, and memory are source of truth.

**ONE TASK THEN EXIT. Run `touch /tmp/.agentmill-done` when done.**

## Task

Read `TASK.md` for your mission. If missing, read `PROGRESS.md` and pick the highest-leverage item.

## Memory Layer

Shared memory at `/workspace/memory/` — Obsidian-compatible markdown, safe for multi-agent writes.
Reference topics as `[[decisions]]`, `[[blockers]]`, `[[patterns]]`.

**Read first:**
```bash
ls /workspace/memory/ 2>/dev/null
cat /workspace/memory/decisions.md
```

**Write reusable learnings:**
```bash
. /entrypoint-common.sh
memory_write "decisions" "Chose X over Y because Z"
memory_write "blockers" "API rate limit hits at 100 req/s"
memory_write "patterns" "Use repository pattern for data access"
```

**Remember:** decisions, blockers, patterns, failed approaches.
**Don't remember:** code (git), transient state, task progress (PROGRESS.md).

## Loop: Orient -> Execute -> Persist

### Orient
```bash
cat TASK.md PROGRESS.md 2>/dev/null
git log --oneline -10
ls /workspace/memory/ 2>/dev/null
```

### Execute
- One logical change. Follow existing patterns.
- Read memory first — don't repeat failed approaches.
- Max 3 attempts per sub-problem, then write blocker and move on.

### Persist
1. Commit verified progress.
2. Update `PROGRESS.md`.
3. Write reusable learnings to memory.
4. `touch /tmp/.agentmill-done`
