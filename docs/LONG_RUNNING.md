# Long-Running Agents: Pedigree & Design Mapping

AgentMill is a productionized **respawning loop**: each iteration runs Claude
Code in a *fresh* context, reads durable state from the filesystem and git,
makes one increment, commits, and exits — then a supervisor respawns it. This
document records where that pattern comes from and how AgentMill's mechanisms
map to the published recommendations, so the design decisions in
`entrypoint.sh` / `entrypoint-common.sh` are traceable rather than folkloric.
Security and sandboxing are tracked separately in
[`HARNESS_SECURITY.md`](HARNESS_SECURITY.md), which maps recent OWASP, MCP,
CSA/NIST, Google, Microsoft, OpenAI, Anthropic, and Docker guidance into
concrete AgentMill controls.

## Prior art

Three independent lineages converged on the same core insight — **the
filesystem and git history are the agent's memory, not the context window** —
and AgentMill is an implementation of their union.

### 0. BrightData research refresh (May 2026)

The current public guidance has converged on a small set of harness and prompt
rules:

- **Context is finite even when windows are large.** Anthropic's context
  engineering guidance treats context as an attention budget: keep prompts and
  tool results high-signal, retrieve just-in-time with file paths / URLs /
  queries, and persist notes outside the context window.
- **Status must live in structured artifacts.** Anthropic's 2025 harness used
  a JSON feature list with pass/fail fields, progress notes, git commits, and
  an `init.sh` smoke-test entrypoint. The important part is not JSON itself; it
  is that completion state is external, inspectable, and hard to casually
  rewrite.
- **A session needs a contract before implementation.** The 2026
  planner-generator-evaluator harness added sprint contracts: generator and
  evaluator agree on "done" and verification criteria before code is written.
  AgentMill prompts now mirror this as a per-iteration verification contract.
- **Self-grading is weak.** Anthropic's 2026 writeup separates generator and
  evaluator because agents are too generous about their own output. The
  practical rule: positive self-assessment is not evidence; tests, E2E checks,
  reviewer roles, and red-team passes are evidence.
- **Durability is broader than memory.** OpenAI's 2026 Agents SDK update and
  SDK docs emphasize sandbox-aware orchestration, explicit memory strategy,
  `max_turns`, durable workflow integrations, and separating harness state from
  compute so a lost sandbox does not lose the run. Restate frames agent loops
  as distributed systems: tool calls need retries, idempotency, journals,
  suspend/resume, and observability.
- **Ralph-loop practitioners still validate the simple version.** The
  practitioner pattern remains a dumb outer loop over a deterministic prompt,
  plan file, progress file, and tests. The newer platform work mostly
  productionizes the same primitives: plan, progress, verification, event log,
  isolated execution, and restart.

Sources checked with BrightData MCP: Anthropic
[`harness-design-long-running-apps`](https://www.anthropic.com/engineering/harness-design-long-running-apps),
[`effective-harnesses-for-long-running-agents`](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents),
and
[`effective-context-engineering-for-ai-agents`](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents);
OpenAI
[`the-next-evolution-of-the-agents-sdk`](https://openai.com/index/the-next-evolution-of-the-agents-sdk/)
and
[`Running agents`](https://openai.github.io/openai-agents-python/running_agents/);
Addy Osmani's
[`Long-running Agents`](https://addyosmani.com/blog/long-running-agents/);
Restate's
[`Durable AI Loops`](https://restate.dev/blog/durable-ai-loops-fault-tolerance-across-frameworks-and-without-handcuffs/);
and the
[`how-to-ralph-wiggum`](https://github.com/ghuntley/how-to-ralph-wiggum)
playbook.

### 1. The Ralph technique (Geoffrey Huntley, late 2025)

The purest statement of the loop:

```bash
while :; do cat PROMPT.md | claude-code ; done
```

Huntley used it to build CURSED (a complete programming language) over months
of mostly-autonomous operation. The doctrine that matters for AgentMill:

- **Progress lives in files, not context.** Each iteration starts fresh
  (~170k usable tokens). State persists in git commits, spec files, a
  `fix_plan.md`, and the test suite — never in the model's ephemeral memory.
  This is *why* a respawning loop beats one long session: no context rot.
- **"Sit on the loop, not in it."** The operator's job is to engineer the
  environment and add corrective "signs" (prompt additions) from outside —
  observe failure patterns, then guard against them. Don't micromanage each
  step.
- **"Deterministically bad in a non-deterministic world."** The agent makes
  the *same* mistakes given the same inputs. That predictability is a feature:
  failures are debuggable and fixable by refining the prompt once.
- **Backpressure, specs, signs.** Reject bad output mechanically (types,
  tests, linters, scanners run *immediately* after each change); constrain
  generation with written specs; encode each observed failure as a durable
  prompt instruction so the next loop doesn't repeat it.
- **Completion is mechanical:** all tests pass *and* the plan file has no
  remaining items.

Sources: <https://ghuntley.com/ralph/> ·
<https://github.com/ghuntley/how-to-ralph-wiggum> ·
"A Brief History of Ralph" (HumanLayer) —
<https://www.humanlayer.dev/blog/brief-history-of-ralph>

### 2. Anthropic's long-running-agent harness research (Nov 2025 → Mar 2026)

Anthropic published the harness design behind the "Long-Running Agents"
station at Code with Claude 2026, with a reference harness at
[`anthropics/cwc-long-running-agents`](https://github.com/anthropics/cwc-long-running-agents).
Their recommendations:

- **Initializer vs. coding agent split.** A specialized first-run agent sets
  up the environment, git repo, and progress docs; every subsequent session
  is a coding agent that makes *one* incremental, mergeable change. This stops
  agents from trying to one-shot the whole application.
- **Durable orientation artifacts.** A progress file (`claude-progress.txt`),
  descriptive git commits, and a **JSON feature list** with pass/fail status.
  JSON is chosen deliberately: the model is less likely to inappropriately
  rewrite structured data than prose.
- **A fixed session-init protocol** — `pwd`, read progress file + recent git
  log, pick the highest-priority incomplete item, launch the dev server via
  `init.sh`, run an end-to-end smoke check *before* writing new code. Saves
  tokens every session and catches a broken tree before it compounds.
- **Anti-premature-declaration.** Strongly-worded constraints against marking
  work done or deleting tests; features are only "complete" after rigorous
  end-to-end (often browser-automation) verification.
- **Git history as a safety net** — discrete commits enable reverting broken
  code and recovering a stable state.

The Mar 2026 follow-up — "Harness design for long-running application
development" (Prithvi Rajasekaran, Anthropic Labs) — sharpens two points that
matter directly for AgentMill:

- **Context resets, not compaction.** Anthropic distinguishes *clearing the
  context window entirely and starting a fresh agent* (with a structured
  handoff carrying prior state + next steps) from compaction (summarizing
  earlier turns in place so the *same* agent continues). Resets give a genuine
  clean slate; compaction does not. They found Sonnet 4.5 exhibited "context
  anxiety" (wrapping up work prematurely as it neared its perceived limit)
  strongly enough that compaction alone was insufficient — **context resets
  became essential** to long-task performance. AgentMill's respawning loop *is*
  a context reset between every iteration: this is the single most direct
  published endorsement of the design. (Opus 4.5 later reduced the anxiety
  enough that Anthropic could drop resets in their newest harness — so the
  discipline matters most when running smaller/older models in the loop.)
- **Generator/evaluator separation (GAN-inspired).** A skeptical *evaluator*
  agent, separate from the *generator*, is a strong lever: models reliably
  over-praise their own output, and tuning a standalone evaluator to be
  critical is far more tractable than making a generator self-critical. Their
  three-agent build (planner → generator → evaluator, evaluator driving a
  live Playwright MCP for end-to-end checks, communicating via files) maps
  onto AgentMill's latent `reviewer` role (TASK.md §2) and the file-based
  `memory/` coordination plane.

The 2026 "infinite context" stack (1M-token window, flat pricing across the
window, server-side compaction, per-turn context editing) reduces — but does
not eliminate — the context pressure these harnesses were built to manage. The
respawn-on-fresh-context discipline still pays off for cost, reproducibility,
and failure isolation.

Sources (all verified via Brightdata MCP `search_engine` + `scrape_as_markdown`):
<https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents>
(Nov 26, 2025) ·
<https://www.anthropic.com/engineering/harness-design-long-running-apps>
(Mar 24, 2026) ·
<https://github.com/anthropics/cwc-long-running-agents> ·
<https://www.anthropic.com/research/long-running-Claude> (scientific-computing
variant)

### 3. The autoresearch / `clax` lineage (filesystem-as-truth in practice)

[`smsharma/clax`](https://github.com/smsharma/clax) — a differentiable CLASS
Boltzmann solver in JAX — was written **entirely by Claude Code**, with the
process documented in `CHANGELOG.md` (the progress log) and a tightly-scoped
`CLAUDE.md` (the disciplines: never scan broad paths, run verifiers directly,
read the design doc first). It is a real-world existence proof of the pattern
on a hard scientific-computing codebase, and the source of several of
AgentMill's loop disciplines (commit `862ae95`). The `logs/results.tsv`
iteration log follows the same Karpathy-style autoresearch pattern (cf.
[`drivelineresearch/autoresearch-claude-code`](https://github.com/drivelineresearch/autoresearch-claude-code)).

## How AgentMill maps to the recommendations

| Recommendation (source)                          | AgentMill mechanism                                                                 |
| ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| Fresh context per iteration (Ralph, Anthropic)   | Respawning loop in `entrypoint.sh`; each iteration is a new `claude` invocation     |
| Progress lives in files/git, not context (all)   | `memory/` (flock-guarded markdown), git history, `logs/results.tsv`                 |
| Durable orientation artifacts (Anthropic)        | `TASK.md` / `PROGRESS.md` read at session start; `mill history`, `mill diff`        |
| Fixed session-init / orient protocol (Anthropic) | `prompts/PROMPT.md` §"Loop: Orient → Claim → Execute → Persist"                      |
| Pre-implementation done contract (Anthropic 2026) | `prompts/PROMPT.md` requires a per-session verification contract before code edits    |
| Initializer vs. coding agent split (Anthropic)   | `setup-repo-env.sh` bootstraps once; coding iterations make one increment each      |
| Backpressure: tests/types/linters (Ralph)        | Repo verifiers + `shellcheck`; `setup-repo-env.sh` installs the toolchain           |
| Evaluator separate from generator (Anthropic)    | Research prompts split breadth/depth/red-team; TASK.md tracks reviewer role work    |
| Mechanical completion signal (Ralph, Anthropic)  | `TASK_COMPLETE` sentinel **+** numeric completion gate (commit `740deff`)           |
| Anti-premature-declaration (Anthropic)           | "Complete exactly ONE task, then EXIT" + completion-gate disciplines in `PROMPT.md` |
| "Sit on the loop, not in it" (Ralph)             | Operator edits `PROMPT.md`/`CLAUDE.md` between runs; agent re-reads them each loop   |
| Encode failures as durable signs (Ralph)         | `failed_approaches` + greppable error logs (commit `de577af`); shared `memory/`     |
| Git history as safety net (Anthropic)            | Per-agent branches (`agent-N`), rebase-on-conflict (max 3), graceful-shutdown WIP   |
| Multi-agent coordination (open question, both)   | Agents push to isolated branches; shared `memory/` as the coordination plane        |
| Durable session/event log (OpenAI, Restate)      | `logs/events.jsonl`, status JSON, and `logs/results.tsv` make runs reconstructable  |

## Gaps vs. the published harnesses

Tracked in `TASK.md`; the ones that map directly to a published
recommendation we don't yet fully satisfy:

- **Structured event completeness** (`logs/events.jsonl`, TASK.md §4) — the
  machine-readable audit stream now exists for iteration, commit, push, and
  convergence events, but it still lacks tool-call counts and token/cost
  payloads.
- **Per-mode convergence gates** (§3) — research has a `research_saturation`
  gate for "no-new-sources-for-N" plus no unresolved open questions. Coder and
  refactor profiles now use typed gates that require a done signal, verifier
  evidence, and mode-specific thresholds.
- **Cost / token / time / log budget gates** (§3, §12) — stop on cumulative
  spend, wall-clock deadline, or log-size budget; capture per-iteration token
  usage from Claude Code's `--output-format=json`.
- **End-to-end verification before completion** (§13 smoke test) — Anthropic
  stresses browser/E2E checks before marking features done; AgentMill relies
  on whatever verifier the target repo provides.
- **Safe-harness policy surface** (§6, §7, §12) — recent OWASP/MCP/CSA/Google
  guidance treats agent tool use, credentials, memory, and egress as the real
  security boundary. AgentMill still needs per-role MCP allowlists, network
  policy, credential isolation, shell mediation, structured audit events, and
  untrusted-repo clone mode as documented in
  [`HARNESS_SECURITY.md`](HARNESS_SECURITY.md).

## See also

- [`RESEARCHER_AGENT.md`](RESEARCHER_AGENT.md) — the research-mode application
  of the same loop (iterate until source saturation, then stop).
- [`HARNESS_SECURITY.md`](HARNESS_SECURITY.md) — recent standards and safe
  harness controls for running long-lived agents against real repositories.
- [`HARNESS_IMPLEMENTATION_PLAN.md`](HARNESS_IMPLEMENTATION_PLAN.md) — phased
  implementation track for the event ledger, profiles, policy chokepoints,
  budgets, isolation, and incident response.
- `prompts/PROMPT.md` — the operative loop disciplines.
- `CLAUDE.md` §"Key Patterns" — the one-paragraph summary this document backs.
