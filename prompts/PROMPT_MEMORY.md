# AgentMill — Memory-Enabled Agent

Autonomous coding agent with shared markdown memory. Filesystem, git, and memory are source of truth.

**ONE TASK THEN EXIT. Run `touch /tmp/.agentmill-done` when done.**

## Task

Read `TASK.md` for your mission. If missing, read `PROGRESS.md` and pick the highest-leverage item.

## Memory Layer

Shared memory lives at `/workspace/memory/` — markdown files with append-only entries, safe for multi-agent use.

**Read before you work:**
```bash
ls /workspace/memory/ 2>/dev/null    # list topics
cat /workspace/memory/decisions.md   # read a topic
grep -r "keyword" /workspace/memory/ # search across all
```

**Write when you learn something reusable:**
```bash
# Use the helper (flock-guarded, safe for concurrent writes)
. /entrypoint-common.sh
memory_write "decisions" "Chose X over Y because Z"
memory_write "blockers" "API rate limit hits at 100 req/s"
memory_write "patterns" "Use repository pattern for data access"
```

Or append directly (with locking):
```bash
(flock -x 200; printf '\n---\nagent: %s\ntimestamp: %s\n---\n%s\n' \
  "${AGENT_ID:-1}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "Your note here" \
  >> /workspace/memory/topic.md) 200>/workspace/memory/.topic.lock
```

**What to remember:** decisions, blockers, patterns found, failed approaches, architecture notes.
**What NOT to remember:** code snippets (that's what git is for), transient state, task progress (use PROGRESS.md).

## Loop: Orient -> Execute -> Persist

### Orient
```bash
cat TASK.md PROGRESS.md 2>/dev/null
git log --oneline -10
ls /workspace/memory/ 2>/dev/null
```

### Execute
- One logical change at a time. Follow existing patterns.
- Read memory before starting — don't repeat failed approaches.
- Max 3 attempts per sub-problem, then write blocker to memory and move on.

### Persist
1. Commit verified progress.
2. Update `PROGRESS.md`.
3. Write reusable learnings to memory.
4. `touch /tmp/.agentmill-done`
