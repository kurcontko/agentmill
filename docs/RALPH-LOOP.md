# Ralph Loop — Research Notes

## Overview

**Ralph Loop** is a technique for running AI coding agents (Claude Code, Codex CLI, Amp, etc.) in a continuous autonomous loop until all tasks in a PRD (Product Requirements Document) are complete. Originally coined by **Geoffrey Huntley**, popularized by **Ryan Carson** ([snarktank/ralph](https://github.com/snarktank/ralph) — 12.4k stars).

## Core Concept

Each iteration spawns a **fresh AI instance with clean context**. Memory persists between iterations only via:
- **Git history** (commits from previous iterations)
- **`progress.txt`** (append-only learnings file)
- **`prd.json`** (task list with `passes: true/false` status)

The loop:
1. Reads the PRD and progress file
2. Picks the highest-priority incomplete task
3. Implements it
4. Runs quality checks (typecheck, tests)
5. Commits if checks pass
6. Updates `prd.json` and `progress.txt`
7. Repeats until all stories pass or max iterations hit

## Ralph Wiggum — Claude Code Plugin (TUI)

An **official plugin** in the Anthropic Claude Code plugin marketplace that runs Ralph loops **directly inside the Claude Code TUI**.

Source: https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum

### Installation

```
/plugin marketplace add anthropics/claude-code
/plugin install ralph-wiggum@anthropics-claude-code
```

Then start a **new session**.

### Usage

```
/ralph-wiggum:ralph-loop "your instructions here" --completion-promise "criteria for stopping" --max-iterations 10
```

| Flag | Purpose |
|---|---|
| `"instructions"` | What Claude should work on |
| `--completion-promise` | Condition that ends the loop |
| `--max-iterations` | Safety cap on iterations |

### Plugin vs Bash Ralph

| | Plugin (TUI) | Bash Ralph |
|---|---|---|
| Context | Single window (accumulates) | Fresh context each iteration |
| Memory | Full conversation history | Only git + progress.txt + prd.json |
| Setup | One slash command | External script + file structure |
| Context rot risk | Higher (degrades ~40%+ utilization) | None (clean slate each time) |

## Running on Codex CLI

Ralph loops work on Codex CLI by swapping `claude -p` for `codex exec` and adjusting model names. A working gist exists at `github.com/DMontgomery40/08c1bdede08ca1cee8800db7da1cda25`. Key notes:
- Enable **web search** in Codex for catching recent deprecations
- OpenAI Pro has more generous rate limits than Anthropic Pro Max
- Can exploit 2x rate limits via Codex Desktop app env var

## Key Repos & Variants

| Project | Description |
|---|---|
| [snarktank/ralph](https://github.com/snarktank/ralph) | Main repo — bash script + prompt templates for Amp & Claude Code |
| [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) | Claude Code-specific implementation |
| [Th0rgal/open-ralph-wiggum](https://github.com/Th0rgal/open-ralph-wiggum) | Supports Open Code, Claude Code, and Codex |
| [iannuttall/ralph](https://github.com/iannuttall/ralph) | Minimal file-based agent loop supporting multiple CLIs |
| [subsy/ralph-tui](https://github.com/subsy/ralph-tui) | Terminal UI for orchestrating AI coding agents |
| [ClaytonFarr/ralph-playbook](https://github.com/ClaytonFarr/ralph-playbook) | Full methodology playbook |
| [ghuntley/how-to-ralph-wiggum](https://github.com/ghuntley/how-to-ralph-wiggum) | Geoffrey Huntley's fork of the playbook |
| [roboco-io/ralph-mem](https://github.com/roboco-io/ralph-mem) | Claude Code plugin for persistent context management |

## Three-Phase Workflow (Clayton Farr Playbook)

### Phase 1: Requirements
Human + LLM conversation. Break features into topics of concern. Create a spec file for each topic in `specs/`. No code yet.

### Phase 2: Planning
Agent reads specs, examines code, generates `IMPLEMENTATION_PLAN.md` — a prioritized task list with no implementation. Pure gap analysis.

### Phase 3: Building
Agent picks the top task, implements it, runs validation, updates the plan, commits, exits. Fresh context for next iteration.

### File Structure

```
project/
├── loop.sh                    # Bash orchestrator
├── PROMPT_plan.md             # Planning mode instructions
├── PROMPT_build.md            # Building mode instructions
├── AGENTS.md                  # Build/test/lint commands (~60 lines)
├── IMPLEMENTATION_PLAN.md     # Shared state between iterations
└── specs/
    └── *.md                   # One file per topic of concern
```

## Critical Best Practices

- **Small tasks**: Each PRD item must fit in one context window. "Add a DB column" good; "Build the entire dashboard" too big.
- **Feedback loops are mandatory**: typecheck, tests, CI must exist or the loop produces compounding broken code.
- **AGENTS.md / CLAUDE.md updates**: The loop writes learnings so future iterations benefit.
- **Sandboxing recommended**: Docker Desktop sandboxes prevent the AI from touching your local machine.
- **Cap iterations**: Always set a max (e.g., 20) to prevent runaway costs.
- **Backpressure beats direction**: Instead of telling the agent what to do, engineer an environment where wrong outputs get rejected automatically (tests, linting, type-checking).
- **Plans are disposable**: Regenerating a stale plan is cheaper than fighting it.

## Minimal Bash Script (Claude Code)

```bash
#!/bin/bash
for ((i=1; i<=$1; i++)); do
  result=$(claude -p "@PRD.md @progress.txt \
    1. Find the highest-priority incomplete task. \
    2. Implement it. Run tests. \
    3. Update progress.txt. Commit. \
    ONLY DO ONE TASK. \
    If done, output COMPLETE.")
  echo "$result"
  [[ "$result" == *"COMPLETE"* ]] && echo "Done after $i iterations." && exit 0
done
```

## Recommended Workflow (Practitioners)

1. Write a detailed spec file
2. Use an `/interview` slash command to have Claude refine the spec with deep questions
3. Run `/clear` to start fresh
4. Run `/ralph-wiggum:ralph-loop` with the spec (Opus model recommended)
5. Optionally use sub-agents as orchestrators with changelogs for cross-agent awareness

## Current Status (March 2026)

- Claude Code shipped **`/loop`** — built-in cron-based task scheduler absorbing some Ralph use cases
- **Agent Teams** handle parallel multi-agent workflows natively
- Ralph plugin still works as the **lowest-friction entry point**
- Bash-based Ralph remains preferred for serious autonomous work (fresh context per iteration)
- The ecosystem is converging on: bash Ralph for heavy lifting, `/loop` for simple recurring tasks, Agent Teams for parallel workflows

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Clayton Farr's Ralph Playbook](https://claytonfarr.github.io/ralph-playbook/)
- [Matt Pocock — Getting Started With Ralph](https://www.aihero.dev/getting-started-with-ralph)
- [paddo.dev — The Ralph Wiggum Playbook](https://paddo.dev/blog/ralph-wiggum-playbook/)
- [paddo.dev — From Ralph Wiggum to /loop](https://paddo.dev/blog/claude-code-loop-ralph-wiggum-evolution/)
- [LogRocket — How Ralph makes Claude Code actually finish tasks](https://blog.logrocket.com/ralph-claude-code/)
