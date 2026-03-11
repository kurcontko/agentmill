# AgentMill — Prompt Patterns for Autonomous Code Agents

## Research & Best Practices Guide

*Compiled March 2026. Sources: Anthropic Engineering, Augment Code, Cursor, Claude Code official docs, community practitioners.*

---

## Table of Contents

1. [Core Principles](#1-core-principles)
2. [System Prompt Architecture](#2-system-prompt-architecture)
3. [The Agent Loop Prompt](#3-the-agent-loop-prompt)
4. [Context Engineering](#4-context-engineering)
5. [Tool Design & Guidance](#5-tool-design--guidance)
6. [Multi-Agent Prompt Strategies](#6-multi-agent-prompt-strategies)
7. [Composable Prompt Patterns](#7-composable-prompt-patterns)
8. [Anti-Patterns to Avoid](#8-anti-patterns-to-avoid)
9. [Prompt Templates](#9-prompt-templates)
10. [Sources](#10-sources)

---

## 1. Core Principles

These principles are consistently validated across Anthropic, Augment Code, Cursor, and community implementations.

### 1.1 Context > Clever Wording

The single most important factor is providing the right context, not finding magic words. As Anthropic puts it: "Context engineering is the art and science of curating what will go into the limited context window from a constantly evolving universe of possible information."

> "Building with language models is becoming less about finding the right words and phrases for your prompts, and more about answering the broader question of: what configuration of context is most likely to generate our model's desired behavior?"
> — Anthropic, *Effective Context Engineering for AI Agents*

### 1.2 Treat Context as a Finite Resource

LLMs have an "attention budget" — every token competes for attention. Context rot is real: as tokens increase, recall accuracy decreases. The goal is always **the smallest set of high-signal tokens that maximize the desired outcome**.

### 1.3 Write for the Agent, Not for Yourself

From Carlini's C compiler project: "I had to constantly remind myself that I was writing this test harness for Claude and not for myself." Design outputs, test results, and error messages with the agent's limitations in mind.

### 1.4 The Model Is (Artificially) Intelligent

From Augment Code: "Prompting a model is closer to talking to a person than programming a computer. The model builds a view of the world solely based on what's in the prompt. The more complete and consistent that view is, the better."

### 1.5 Be Specific, Not Vague

```
BAD:  "Look for security issues"
GOOD: "Check for SQL injection by examining all database queries for parameterization"

BAD:  "Create tests"
GOOD: "Generate test file at test/path/to/file.test.ts covering edge cases X, Y, Z"
```

---

## 2. System Prompt Architecture

### 2.1 Recommended Structure (Anthropic/Claude Code)

From the official Claude Code system-prompt-design reference:

```markdown
You are [specific role] specializing in [specific domain].

**Your Core Responsibilities:**
- [Primary responsibility — the main task]
- [Secondary responsibility — supporting task]

**[Task Name] Process:**
1. [First concrete step]
2. [Second concrete step]
3. [Continue with clear steps]

**Quality Standards:**
- [Standard 1 with specifics]
- [Standard 2 with specifics]

**Output Format:**
Provide results structured as:
- [Component 1]
- [Component 2]

**Edge Cases:**
Handle these situations:
- [Edge case 1]: [Specific handling approach]
- [Edge case 2]: [Specific handling approach]
```

### 2.2 The "Right Altitude" (Anthropic)

System prompts must hit the Goldilocks zone between two failure modes:

| Too Low (Brittle) | Just Right | Too High (Vague) |
|---|---|---|
| Hardcoded if-else logic for every scenario | Specific heuristics with flexibility for judgment | "Be helpful and write good code" |
| Breaks on unexpected inputs | Guides behavior effectively | Agent has no actionable signal |
| High maintenance burden | Balances specificity and autonomy | Assumes shared context that doesn't exist |

### 2.3 Prompt Length Guidelines

From the Claude Code system-prompt-design reference:

| Agent Type | Word Count | Components |
|---|---|---|
| Minimum Viable | ~500 words | Role, 3 responsibilities, 5-step process, output format |
| Standard | ~1,000-2,000 words | Detailed role, 5-8 responsibilities, 8-12 steps, quality standards, edge cases |
| Comprehensive | ~2,000-5,000 words | Full role with background, multi-phase process, multiple output formats, many edge cases, examples |
| **Avoid** | >10,000 words | Diminishing returns |

### 2.4 Present a Complete World View (Augment Code)

Help the agent understand its operating environment. Two lines that "dramatically improved performance" at Augment:

```
You are an AI assistant, with access to the developer's codebase.
You can read from and write to the codebase using the provided tools.
```

Include: current directory, available tools, constraints, what resources exist.

---

## 3. The Agent Loop Prompt

The defining pattern for autonomous agents. The prompt must enable orientation, task selection, execution, and self-assessment in a single context window.

### 3.1 Core Loop Prompt Template

From the C compiler project and Ralph Wiggum patterns:

```markdown
# Your Task
You are an autonomous coding agent working on [PROJECT].

## Orientation (Do This First)
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
- If stuck for more than 3 attempts, document the issue and move on
- Write ERROR on the same line as error descriptions in logs
```

### 3.2 Key Elements That Make Loop Prompts Work

**Self-Orientation**: Each fresh session must be able to pick up where the last left off. Progress files + git history = persistent memory across ephemeral sessions.

**Clear Completion Criteria**: The agent must know what "done" looks like — passing tests, specific file states, documented milestones.

**Escape Hatches**: Rules for when to give up on a subtask prevent infinite loops on unsolvable problems.

**Minimal Output**: Don't pollute the context window with verbose test output. Print summaries, log details to files.

---

## 4. Context Engineering

### 4.1 Just-In-Time Context Retrieval

Rather than loading everything upfront, agents should maintain lightweight references (file paths, queries, links) and load data dynamically using tools. This mirrors human cognition — we don't memorize entire codebases, we know where to look.

**Hybrid Strategy** (recommended): Load critical orientation context upfront (like CLAUDE.md), then let the agent explore and retrieve just-in-time via grep, glob, file reads.

### 4.2 Compaction

When context approaches the limit, summarize and restart with compressed context:

- Preserve: architectural decisions, unresolved bugs, implementation details
- Discard: redundant tool outputs, old messages
- **Low-hanging fruit**: Clear tool call results deep in history — the agent rarely needs raw results from earlier turns

### 4.3 Structured Note-Taking (Agentic Memory)

The agent writes notes to external files that persist outside the context window:

```markdown
# PROGRESS.md (Agent-maintained)
## Completed
- Implemented lexer for C99 tokens (commit abc123)
- Fixed parser edge case for nested structs

## In Progress
- Code generation for switch statements

## Blocked
- ARM backend: SIMD instructions failing, tried 3 approaches (see NOTES.md)

## Next Up
- Optimize register allocation
```

### 4.4 Design Outputs for the Agent

From the C compiler project — critical LLM-specific limitations to design around:

| Limitation | Design Solution |
|---|---|
| **Context window pollution** | Print summaries, log details to files. Use `ERROR reason` on one line for grep-ability |
| **Time blindness** | Print incremental progress infrequently. Add `--fast` flags for 1-10% test sampling |
| **Orientation cost** | Maintain READMEs and progress files. Pre-compute aggregate statistics |
| **Pattern matching bias** | Don't over-index on specific examples; use "what not to do" instructions instead |

### 4.5 Attention Priority Order (Augment Code)

Models pay most attention to:
1. **User message** (most recent turn) — highest priority
2. **Beginning of context** (system prompt) — high priority
3. **Middle of context** — lowest priority

Put critical instructions in the system prompt and/or the most recent user message.

---

## 5. Tool Design & Guidance

### 5.1 Tool Design Principles

From Anthropic's *Effective Context Engineering*:

- Tools should be **self-contained, robust to error, and extremely clear** about intended use
- Input parameters should be **descriptive and unambiguous**
- Minimal overlap between tools — if a human can't say which tool to use, an agent can't either
- Return **token-efficient** outputs

### 5.2 Tool Error Communication

From Augment Code: Don't raise exceptions in your agent code. Return tool results that explain errors:

```
BAD:  Raising an exception when a tool is called incorrectly
GOOD: Returning "Tool was called without required parameter xyz" as the tool result
```

The model will recover and retry.

### 5.3 Consistency Across Prompt Components

All components (system prompt, tool definitions, tool outputs) must be internally consistent:

- If the system prompt says `The current directory is $CWD`, tool default parameters should reflect that
- If a tool promises output of length N, either return that length or explain why not
- Don't include changing state (like timestamps) in the system prompt — tell the model about changes in subsequent messages to avoid cache invalidation

---

## 6. Multi-Agent Prompt Strategies

### 6.1 Specialization by Role

From the C compiler project, dedicate agents to specific roles:

| Agent Role | Prompt Focus |
|---|---|
| **Core builder** | Implement features, fix failing tests |
| **Code deduplicator** | Find and coalesce duplicate implementations |
| **Performance optimizer** | Profile and optimize hot paths |
| **Code quality reviewer** | Structural improvements, Rust idioms |
| **Documentation maintainer** | Keep docs in sync with code |

### 6.2 Parallelism Patterns

**Many distinct tasks** (easy): Each agent picks a different failing test. Prompt includes `current_tasks/` for coordination.

**Monolithic task** (hard): Use oracle-based decomposition. Randomly compile most files with a known-good tool, only test a subset with the agent's output. Each agent works on a different subset.

**Multi-model approach** (Cursor): Run the same prompt across multiple models simultaneously and pick the best result.

### 6.3 Sub-Agent Architecture

Main agent coordinates with a high-level plan while sub-agents handle focused tasks with clean context windows. Each sub-agent:
- Explores extensively (tens of thousands of tokens)
- Returns only a condensed summary (1,000-2,000 tokens)
- Maintains isolation from the main agent's context pollution

---

## 7. Composable Prompt Patterns

From Nick Tune's work on composable Claude Code system prompts.

### 7.1 Prompt Categories

| Category | Purpose | Example |
|---|---|---|
| **Orchestration/Workflow** | State machine for how to carry out work | TDD workflow, code review process |
| **Knowledge** | Domain information to weight heavily | Software design principles, coding standards |
| **Task** | Independent tasks/artifacts | Code analysis, migration scripts |
| **Personality** | Behavioral directives | Direct, challenging, cautious, thorough |

### 7.2 Composition Strategy

Break monolithic prompts into composable skills:

```markdown
## Skills
- @~/.claude/skills/tdd-process/SKILL.md
- @~/.claude/skills/software-design-principles/SKILL.md
- @~/.claude/skills/critical-peer-personality/SKILL.md
```

Combine different skills for different tasks. Any agent can adopt a TDD workflow or switch personality mid-conversation.

### 7.3 Static vs Dynamic Context

| Mechanism | When Loaded | Use Case |
|---|---|---|
| **Rules** (`.cursor/rules/`, `CLAUDE.md`) | Always, every conversation | Commands, code style, workflows |
| **Skills** (dynamic) | When agent decides they're relevant | Domain knowledge, specialized workflows |
| **User message** | Per-turn | Specific task instructions |

---

## 8. Anti-Patterns to Avoid

### 8.1 Vague Responsibilities

```
BAD:
  Your Core Responsibilities:
  - Help the user with their code
  - Provide assistance
  - Be helpful

GOOD:
  Your Core Responsibilities:
  - Analyze TypeScript code for type safety issues
  - Identify missing type annotations and improper 'any' usage
  - Recommend specific type improvements with examples
```

### 8.2 Missing Process Steps

```
BAD:  "Analyze the code and provide feedback."
GOOD:
  Analysis Process:
  1. Read code files using Read tool
  2. Scan for type annotations on all functions
  3. Check for 'any' type usage
  4. Verify generic type parameters
  5. List findings with file:line references
```

### 8.3 Overfitting to Specific Examples

Models are strong pattern matchers and will latch onto details. Providing specific examples is a double-edged sword — the agent may overfit. **Telling the model what NOT to do is safer** than providing narrow positive examples.

### 8.4 Bloated Tool Sets

Too many tools with overlapping functionality create ambiguous decision points. Curate a minimal viable tool set.

### 8.5 Ignoring Prompt Caching

Build prompts that append rather than rewrite during a session. Don't include changing state (timestamps, current file) in the system prompt — use subsequent messages instead.

### 8.6 Printing Too Much Output

The #1 context pollution source. Truncate tool outputs. When truncating command output, **truncate the middle, not the suffix** — errors and stack traces tend to appear at the beginning and end.

---

## 9. Prompt Templates

### 9.1 Autonomous Builder Agent

```markdown
You are an autonomous software engineer working on [PROJECT_NAME].

## Orientation (Always Do First)
1. Read PROGRESS.md for current state and known blockers
2. Read README.md for architecture overview
3. Run `[TEST_COMMAND] --fast` for current test status (1% sample)
4. Check `current_tasks/` for work claimed by other agents
5. Review `git log --oneline -10` for recent changes

## Working Protocol
1. Identify the highest-priority unclaimed task
2. Claim it: write `current_tasks/[task_name].txt` with brief description
3. Implement in small, focused changes
4. Run full test suite — never break existing tests
5. Update PROGRESS.md with what you did and any new findings
6. Remove your lock file
7. Commit with a descriptive message and push

## Constraints
- Changes must be minimal and focused — one logical unit per iteration
- If stuck after 3 attempts, document the blocker and move on
- Log errors with `ERROR` on the same line as the reason
- Do not print more than 20 lines of test output to stdout
- Pre-existing tests must continue to pass

## Quality Standards
- All new code has corresponding tests
- No regressions in existing functionality
- Code follows existing project conventions (check style in surrounding files)
```

### 9.2 Analysis/Review Agent

```markdown
You are an expert code reviewer specializing in [LANGUAGE/FRAMEWORK].

**Your Core Responsibilities:**
- Analyze code changes for bugs, security issues, and design problems
- Categorize findings by severity (critical/major/minor)
- Provide actionable fix recommendations with file:line references

**Analysis Process:**
1. Read all changed files using available tools
2. Identify the intent of the changes from commit messages and PR description
3. Check for: security vulnerabilities, logic errors, race conditions, missing error handling
4. Verify test coverage for changed behavior
5. Assess code style consistency with surrounding code
6. Synthesize findings into prioritized report

**Output Format:**
## Review Summary
[2-3 sentence overview]

## Critical Issues
- `file.ts:42` — [Issue] — [Fix recommendation]

## Major Issues
- `file.ts:100` — [Issue] — [Fix recommendation]

## Minor Issues / Suggestions
- [...]

**Edge Cases:**
- No issues found: provide positive feedback and note what was verified
- Too many issues: group by type, prioritize top 10
- Unclear code intent: flag as needing clarification rather than guessing
```

### 9.3 Test-Driven Development Agent

From Cursor's best practices:

```markdown
You are a TDD-focused developer. Follow this strict workflow:

**Phase 1: Write Tests**
- Write tests based on expected input/output pairs
- Tests should capture the desired behavior, not the implementation
- Do NOT create mock implementations for functionality that doesn't exist yet
- Run tests and confirm they FAIL (red phase)
- Stop and wait for approval before continuing

**Phase 2: Implement**
- Write the minimum code needed to pass the tests
- Do NOT modify the tests
- Keep iterating until all tests pass (green phase)
- Commit the implementation

**Phase 3: Refactor**
- Clean up code while keeping tests green
- Look for duplication, naming issues, structural improvements
- Run tests after every change

**Rules:**
- Tests are the specification — never weaken them to make code pass
- One test file per logical unit
- Use project's existing test patterns (check __tests__/ for examples)
```

### 9.4 Orchestrator Agent (Multi-Phase)

```markdown
You are a project orchestrator coordinating a [complex workflow].

**Orchestration Process:**
1. **Plan**: Understand full workflow and dependencies
2. **Prepare**: Set up prerequisites and verify environment
3. **Execute Phases**:
   - Phase 1: [What] using [tools]
   - Phase 2: [What] using [tools]
   - Phase 3: [What] using [tools]
4. **Monitor**: Track progress and handle failures
5. **Verify**: Confirm successful completion
6. **Report**: Provide comprehensive summary

**Quality Standards:**
- Each phase completes before the next begins
- Errors handled gracefully with retry logic
- Progress reported at each phase transition
- Final state verified against success criteria

**Edge Cases:**
- Phase failure: Attempt retry once, then report and stop
- Missing dependencies: Request from user
- Timeout: Report partial completion with current state
```

---

## 10. Sources

1. **[Building a C compiler with a team of parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler)** — Nicholas Carlini, Anthropic (Feb 2026). The definitive case study on autonomous agent teams. Key insights on test design, context management, parallel coordination, and agent specialization.

2. **[Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)** — Anthropic Applied AI team (Sep 2025). The authoritative guide on context as a finite resource, compaction, structured note-taking, sub-agent architectures, and just-in-time retrieval.

3. **[How to build your agent: 11 prompting techniques for better AI agents](https://www.augmentcode.com/blog/how-to-build-your-agent-11-prompting-techniques-for-better-ai-agents)** — Guy Gur-Ari, Augment Code (May 2025). Field-tested tactics: focus on context, present a complete world view, be thorough, handle tool calling limitations, attention priority order.

4. **[Best practices for coding with agents](https://cursor.com/blog/agent-best-practices)** — Lee Robinson, Cursor (Jan 2026). Planning before coding, TDD workflows, managing context, composable rules/skills, parallel agent execution, debug mode.

5. **[System Prompt Design Patterns](https://github.com/anthropics/claude-code/blob/main/plugins/plugin-dev/skills/agent-development/references/system-prompt-design.md)** — Claude Code official reference. Templates for analysis, generation, validation, and orchestration agents with concrete structure patterns.

6. **[Composable Claude Code System Prompts](https://medium.com/nick-tune-tech-strategy-blog/composable-claude-code-system-prompts-4a39132e8196)** — Nick Tune (Nov 2025). Breaking monolithic prompts into composable skills: orchestration, knowledge, task, and personality categories.

7. **[Claude Prompting Best Practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)** — Anthropic official docs. Comprehensive guide on clarity, examples, XML structuring, thinking, and agentic systems.
