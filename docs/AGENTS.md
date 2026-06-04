# Agent Patterns

AgentMill should borrow OpenClaw's agent discipline, not its scale. OpenClaw
uses many `.agents/skills`, scoped `AGENTS.md` files, and Codex prompt files to
give each agent a narrow job, hard limits, and a proof path. AgentMill maps that
idea to a smaller surface: role profiles in `agents/*.toml`, prompt files under
`prompts/`, `mill doctor`, and structured run logs.

## Patterns Worth Keeping

### Role Contracts

OpenClaw skills start with a named role and a clear trigger. AgentMill's
equivalent is an `agents/<role>.toml` profile:

- `description` says when the role should be used.
- `prompt_file` owns the role's operating loop.
- `model`, `max_iterations`, `max_wall_seconds`, and `max_log_bytes` bound the
  run.
- `network`, `mcp_allowlist`, `skill_allowlist`, and forwarding flags define
  capabilities.
- `branch_pattern` and `auto_commit_mode` define write behavior.
- `completion_gate` defines how the harness decides the role is done.

If a new role cannot fill those fields concretely, it is probably a prompt
variant, not a profile.

### Hard Limits

OpenClaw's best agent prompts say what must not happen: no broad refactors, no
publishing during review, no skipped tests, no dependency guesses, no unrelated
scope expansion. AgentMill prompts should keep the same shape:

- one bounded task per iteration;
- exact files or surface claimed before edit;
- no silent scope expansion;
- no test weakening to make a check pass;
- no nested agent/container/session spawning unless the operator asked;
- stop and write a blocker when evidence is not improving.

These limits belong in prompts and docs, while enforcement belongs in the
harness where practical: profile budgets, branch policy, high-risk gates, MCP
manifest lock, shell/tool policy, and workspace isolation.

### Evidence Before Completion

OpenClaw's maintainer and testing skills repeatedly separate assertions from
proof. AgentMill should preserve that separation:

- coder roles use `coder_verified`, not a plain done file, when the task needs
  test or verifier evidence;
- refactor roles use `refactor_verified` for LOC and verifier bounds;
- research roles use `research_saturation` instead of a self-declared finish;
- reviewer roles default to no auto-commit and should leave findings as review
  evidence, not silently alter code.

The agent's final message is not proof. The proof is the verifier command,
status file, event log, results row, commit, or report artifact.

### Scoped Instructions

OpenClaw uses scoped `AGENTS.md` files near expensive or risky surfaces, such as
agent runtime, agent tools, and scripts. AgentMill can keep this lighter:

- repo-wide contributor guidance stays in `CLAUDE.md`;
- role behavior stays in `prompts/*.md`;
- profile mechanics stay in `docs/PROFILES.md`;
- harness safety controls stay in `docs/SECURITY.md` and
  `docs/HARNESS_SECURITY.md`;
- CI and workflow ownership stay in `docs/CI.md`.

Add a scoped instruction file only when a subtree develops rules that are too
specific for these docs.

### Smallest Meaningful Gate

OpenClaw testing guidance avoids full-suite reflexes. AgentMill should do the
same:

- use focused shell tests for shell CLI or entrypoint changes;
- use Python unit tests for Python wrapper or helper changes;
- use `mill doctor` and profile tests for profile/policy changes;
- use Docker build or smoke integration only for container/runtime changes.

Record which gate proves the change. Do not present a narrow gate as proof of a
broader surface.

## Patterns Not Worth Copying

- A large `.agents/skills` tree. AgentMill has generic roles; project-specific
  GitHub triage, release, mobile, and plugin workflows belong in the target
  repository, not in the harness.
- GitHub maintainer automation such as assignment, labeling, issue closure, and
  merge/automerge commands. AgentMill should create auditable changes; humans or
  repo-specific bots should own publication policy.
- Testbox, Crabbox, release umbrella, and live-provider orchestration. Those are
  large-project proof systems. AgentMill's base proof path should stay local and
  explicit.
- Dozens of narrow channel/plugin prompts. AgentMill's built-in roles should
  stay stable: coder, reviewer, researcher breadth/depth/redteam, refactor, and
  memory curator.
- Nested subagent workflows by default. The harness already provides iteration
  and parallelism; agents should not spawn their own untracked agent loops.

## Current Role Map

| AgentMill role | OpenClaw pattern adapted | Completion style |
| --- | --- | --- |
| `coder` | small high-confidence bugfix/change worker | `coder_verified` |
| `reviewer` | skeptical closeout/review pass | `done_file`, no auto-commit |
| `researcher-breadth` | source discovery lane | `research_saturation` |
| `researcher-depth` | evidence extraction and synthesis lane | `research_saturation` |
| `researcher-redteam` | citation and claim audit lane | `research_saturation` |
| `refactor` | bounded cleanup with measurable target | `refactor_verified` |
| `memory-curator` | durable handoff and failed-approach hygiene | `done_file` |

## Adding A Role

1. Decide whether the role is truly distinct from an existing prompt variant.
2. Add `agents/<role>.toml` with budget, branch, network, and completion fields.
3. Add or reuse a prompt under `prompts/`.
4. Add profile rendering coverage in `tests/test_agent_profiles.sh`.
5. Run:

```bash
python3 scripts/profile-env.py agents/<role>.toml --role <role> --agent-id 1
./mill profiles <role>
bash tests/test_agent_profiles.sh
```

For roles that can write code, also run the smallest test that proves the
prompt/profile interaction you changed.
