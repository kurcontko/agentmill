# Implementing LongHorizon-Harness (Manage-Execute-Audit) in AgentMill

Assessment of how to bring the Manage-Execute-Audit (MEA) flow from
[*LongHorizon-Harness: Advancing Long-Horizon Agents for Real-World Tasks*](https://arxiv.org/abs/2608.01964)
(arXiv:2608.01964) into AgentMill, and whether the Claude Agent SDK is a better
vehicle. Based on the paper plus its reference implementation at
[AMAP-ML/LongHorizon-Harness](https://github.com/AMAP-ML/LongHorizon-Harness)
(pip-installable as `lh-harness`).

## TLDR

AgentMill already implements about half of the paper — the executor half. What
it's missing is the two trusted roles around it: a **manager** that plans from
report history without touching the environment, and an **auditor** that
verifies the environment without trusting the executor's self-report.

Recommended sequence:

1. **Option A** — add an MEA mode to the existing bash loop (small delta: two
   extra headless `claude` calls per iteration with tool restrictions).
2. **Option B** — move orchestration to the Claude Agent SDK as the v2 path if
   the bash version starts accumulating parsing/repair hacks.
3. **Option C** — trial their published harness inside the AgentMill container
   first; it drives Claude Code with nearly the same invocation AgentMill
   already uses, and its role prompts are worth studying regardless.

## The paper in one paragraph

The paper's core claim is that long-horizon agent failure is a
*state-management* problem: harnesses keep task execution, task state, and
completion assessment in one growing context, so errors compound and progress
tracking degrades. Their fix splits each round into three fresh-context roles —
Manage (state machine; sees all reports, never the environment), Execute
(state-changing action; sees only the current subtask contract plus explicitly
referenced reports, never full history), Audit (read-only state capture in a
clean context, independent from the executor) — with an append-only ledger of
audit reports `V_1..V_n` as the *only* trusted state representation. Reported
gains: 5–30 percentage points across benchmarks and models.

## What AgentMill already has vs. the paper

Already present (the "Execute" box plus external memory):

- Fresh context per iteration — the respawning loop.
- External state memory — `PROGRESS.md`, `logs/results.tsv`, `memory/`, the
  failed-approaches log.
- Iteration bounding (`MAX_ITERATIONS`) and a completion sentinel.

Missing, in the paper's terms:

1. **No manager.** The executor picks its own next task from
   `TASK.md`/`PROGRESS.md` inside the same session that does the work. The
   paper separates these: the manager reads *all* prior audit reports (never
   the environment), emits a subtask contract — goal, acceptance criteria,
   boundary constraints, references to related reports — and the executor sees
   *only* that contract plus the referenced reports.
2. **No auditor.** `results.tsv` status is derived from git metrics plus the
   executor's self-touched `/tmp/.agentmill-done`. In the paper's framing that
   state is *untrusted* — a report only becomes authoritative because an
   independent, read-only, fresh-context agent wrote it after inspecting the
   environment. Their `AuditReport` type carries
   `status: complete|incomplete|blocked` plus
   `integrity_status: clean|suspect|violation` — catching e.g. the executor
   gaming the verifier, the same failure PROMPT.md's "no fudge factors" rule
   tries to prompt away, but enforced structurally.
3. **Trusted termination.** They terminate only when the auditor says
   `complete` AND `clean`. AgentMill terminates on iteration count or the
   agent's own say-so.
4. **Hard per-role budgets.** Executor 1800 s, manager/auditor 600 s, default 4
   rounds (`max_total_episodes`). AgentMill iterations are unbounded in time.

Reference-implementation details worth knowing:

- State layout: `.harness/management/rounds/round_NNN/round.json` per round,
  plus an append-only `rounds.jsonl` ledger — same pattern as `results.tsv`.
- `auditor_agent.py` includes a "format repair" retry pass for when the
  auditor's structured report doesn't parse — structured output from headless
  agents is the fiddly part.
- Workspace mutation detection: the audit must not change the environment; a
  mutated workspace after audit is an integrity violation.
- Human-in-the-loop: the manager can route to `ask` instead of `gui`/`cli`;
  the answer is injected into global state.
- `ClaudeCodeAdapter` invokes
  `claude --print --output-format stream-json --verbose --dangerously-skip-permissions --model …`
  — nearly identical to `entrypoint.sh`'s invocation.

## Option A — MEA mode in the existing bash loop (recommended first step)

Each iteration of `entrypoint.sh` becomes three headless calls instead of one:

- **Manage** — `claude -p` with `--allowedTools "Read Glob Grep"` (no
  Write/Edit/Bash; drop `--dangerously-skip-permissions` for this role — the
  tool allowlist *is* the enforcement mechanism). Prompt =
  `prompts/ROLE_MANAGER.md` + task + all prior reports from
  `logs/rounds/*/report.md`. Output saved as
  `logs/rounds/round_N/contract.md`. An `ASK:` line in the output pauses the
  loop for the operator instead of respawning.
- **Execute** — the existing call, unchanged mechanics, but the prompt is the
  contract + referenced reports rather than the full `PROMPT.md`
  orient-and-claim dance. Wrap in `timeout 1800`.
- **Audit** — fresh `claude -p` with
  `--allowedTools "Read Glob Grep Bash(git diff:*) Bash(git log:*) Bash(git status:*)"`.
  It writes nothing itself — the harness captures stdout to
  `logs/rounds/round_N/report.md` and appends a line to `results.tsv`.
  `git status --porcelain` must be unchanged after the audit run, else
  `integrity: violation`.
- **Terminate** when the harness greps `status: complete` +
  `integrity: clean` from the report — replacing the self-touched sentinel as
  the authority (or keep the sentinel but auditor-gated).

Why this fits: shell + flock'd files under `logs/`, prompts in `prompts/`,
`results.tsv` already mirrors their `rounds.jsonl` ledger, and it composes with
multi-agent branches as-is.

The one genuinely annoying part in bash is parsing structured output (hence
their format-repair pass). Mitigation: keep reports as markdown with a few
greppable header lines (`status:`, `integrity:`) instead of JSON.

Suggested surface: `ENTRYPOINT_MODE=mea` env var or `./mill run --mea`, two new
role prompt files, one small module under `lib/agentmill/sh/runtime/`.

## Option B — Claude Agent SDK orchestrator (v2 path)

Replace the inner loop with a Python orchestrator: one `query()` per role, each
with its own `ClaudeAgentOptions`:

- per-role `allowed_tools` / `permission_mode`;
- `max_turns` — a real turn budget (the paper's figure specifies 20 turns for
  the executor; bash can only enforce wall-clock via `timeout`);
- hooks that hard-block writes for the auditor;
- structured JSON output without grep-and-pray.

Each `query()` is naturally a fresh session, so the isolation model maps
one-to-one onto MEA.

Trade-offs:

- Better long-term architecture if MEA becomes AgentMill's main mode.
- Breaks the stated "Python 3.11+, stdlib only" convention for the framework
  (the SDK is a third-party dep) — could be confined to the container image.
- Replaces the part of AgentMill that is simplest today, while all the
  docker/git/multi-agent plumbing (which the SDK doesn't do) stays in bash
  anyway.

Sequence it second: prove the flow in bash, migrate when the bash version
starts accumulating parsing/repair hacks like the reference implementation did.

## Option C — Run their harness inside the AgentMill container

```bash
uv tool install lh-harness
lh-harness run --task "$(cat TASK.md)"
```

Config precedence: CLI args → `./.lh-harness/config.toml` (from
`lh-harness init`) → defaults. `lh-harness doctor` checks the install and
available agent CLIs. A dashboard shows the Manager → Executor → Auditor
workflow live.

Since its Claude Code invocation matches `entrypoint.sh`'s, it would work
inside the container today as a `./mill mea` mode, giving the full paper flow
(contract/report schemas, format repair, human-in-the-loop gate, dashboard)
for free.

Downsides: oriented toward single long tasks rather than an endless
multi-agent respawn loop; manages its own state under `.harness/`; AgentMill's
git-branch sync would sit outside it.

Worth an hour of trialing before writing anything — if only to study
`role_prompts.py` (579 lines of battle-tested manager/executor/auditor
prompts) for Option A. Check their LICENSE before vendoring any of it.
