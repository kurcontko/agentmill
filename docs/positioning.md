# Where AgentMill has to improve to be worth publishing

Competitive assessment as of 2026-08-09, based on a sweep of the ~200 tools in
[awesome-agent-orchestrators](https://github.com/andyrewlee/awesome-agent-orchestrators)
plus the READMEs of the closest ten.

## The honest read

AgentMill currently sells a **mechanism**: "a Docker container that runs Claude
Code in a respawning loop." That mechanism is commoditized. The category
"Autonomous Loop Runners" has a 9.6k★ incumbent
([ralph-claude-code](https://github.com/frankbria/ralph-claude-code)) that
already ships `--sandbox docker` *and* `--sandbox e2b`, rate limiting, circuit
breakers, exit detection, and 784 tests. Shipping "the same loop, but the
container is mandatory" is not a reason for anyone to switch.

Worse, the three features AgentMill leads with in conversation — respawn for
fresh context, multi-agent parallelism, shared memory — are each individually
owned by someone bigger:

| AgentMill feature | Who already owns it |
|---|---|
| Respawn / fresh context per iteration | ralph-claude-code (9.6k), ralphex (1.4k), the whole Ralph category |
| Parallel agents on one repo | claude-squad (8.3k), emdash (5.4k), ~90 worktree tools |
| Shared memory between agents | CORAL (879, COLM 2026 paper), guild, ai-maestro |
| Docker isolation | ralph-claude-code as a flag; agentbox (339); sandbox-agent (1.5k) |

So: not a feature gap. A **positioning** gap.

## The niche where nothing exists

Every tool in the landscape sells *capability* — how much work an agent can get
through, how many run in parallel, how nice the dashboard is. Essentially none
sells **accountability**: proof of what the agent did while you weren't
watching, and proof it didn't fake the result.

That is the gap, and it is the natural extension of what
[`longhorizon-mea.md`](longhorizon-mea.md) already lays out.

The unattended-run trust problem breaks into three questions nobody answers
well together:

1. **Did it actually do the work, or did it write a passing test around a
   stub?** The MEA paper's framing: the executor's self-report is *untrusted*
   state.
2. **What did it do for eight hours while I slept?** Every loop runner focuses
   on *starting* the loop. `results.tsv` + `mill history` is a seed of the
   answer; nobody has a real morning-after report.
3. **What is this going to cost me?** A 200-iteration unattended run is an open
   cheque. Only MartinLoop (44★) caps spend, and fractal bounds cost/time.

Who is nearby, and why none of them closes it:

- **CORAL** (879★) is the closest philosophically and has already made the key
  move — its 2026-06-24 release isolates the agent from the grader (agents run
  unprivileged, `.coral/private/` unreadable even via Bash). That validates the
  threat model. But CORAL grades a **scalar metric** you write a grader for
  (circle packing, GPU kernels, Kaggle), which is autoresearch, not ordinary
  software maintenance. It also explicitly **cannot run inside Docker** itself
  (its Harbor-based graders don't support DinD).
- **kodo, toryo, bernstein, ralphex, MartinLoop, Aperant, loki-mode** all have
  *some* verification — a reviewer agent, tests, quality ratcheting, gates. All
  of it runs in the same trust domain as the executor.
- Nobody treats the executor as adversarial and enforces it structurally.

### The wedge

`longhorizon-mea.md` proposes enforcing the auditor's read-only role with
`--allowedTools "Read Glob Grep Bash(git diff:*) …"`. **A tool allowlist is a
soft boundary.** It is a prompt-adjacent guardrail in the same process, same
filesystem, same trust domain as the thing it is auditing — exactly the failure
the paper's `integrity_status` field exists to catch.

AgentMill is the only project in this category positioned to make that boundary
*structural*, because it is already container-first:

> **Run the auditor in a separate container, with the repo mounted read-only,
> no network, and no access to the executor's credentials or scratch state.**

A host-script competitor cannot make that claim without becoming a container
orchestrator — which is the one thing AgentMill already is. ralph-claude-code
can add another flag; it cannot cheaply add a second isolated trust domain per
iteration. That is a defensible edge rather than a feature race.

This reframes the whole project. Not "a Docker container that runs a loop", but:

> **Unattended agent runs you can actually trust — because the thing that
> checks the work runs in a different container than the thing that did it.**

## What to build, in order

### P0 — required before publishing at all

These are not differentiators; they are the reasons a first-time user churns.

1. **Auditor-gated termination.** Today the loop terminates on iteration count
   or a sentinel the executor touches itself, and `AUTO_COMMIT` will happily
   commit 200 iterations of garbage. This is the single biggest quality gap
   versus every serious competitor. Option A in `longhorizon-mea.md` is the
   right first cut — but gate the sentinel on the audit verdict rather than
   keeping both authorities.
2. **Budgets.** `MAX_COST_USD` and per-role wall-clock caps (`timeout 1800`
   executor, `600` manager/auditor per the paper). Unbounded iteration time
   today. Cost ceilings are the #1 thing that stops people leaving these tools
   running, and the field has almost nothing.
3. **Exit detection in headless mode.** `AUTO_RALPH_COMPLETION_PROMISE` exists
   only for the TUI path; `mill run` has no notion of "done". This is
   ralph-claude-code's headline feature and its absence is conspicuous.

### P1 — the actual wedge

4. **MEA mode with the auditor in its own container.** Not just a separate
   `claude -p` call — a separate compose service, read-only bind mount, no
   network, no auth passthrough beyond what the audit needs. This is the thing
   to lead the README with, and the thing to write a post about. Enforce the
   paper's integrity check: `git status --porcelain` unchanged after audit, or
   `integrity: violation`.
5. **`mill report` — the morning-after artifact.** One page per run: per-round
   audit verdicts (`status` / `integrity`), what was committed, tests at start
   vs. end, total cost, where it got stuck, which rounds the auditor rejected.
   The audit ledger makes this nearly free, and no competitor produces
   anything like it. This is what makes the trust claim *visible* rather than
   architectural trivia.

### P2 — breadth, once the wedge lands

6. **Second provider.** PR #9 (Codex entrypoints) is already open. Everyone is
   going multi-provider; it is table stakes, not a differentiator, so it should
   not jump the queue. It does, however, strengthen the wedge — an auditor
   running a *different model* than the executor is a genuinely stronger
   independence claim, and nobody offers that.

## What NOT to build

Explicitly out, to avoid burning effort in lost categories:

- **A TUI or web dashboard.** ~90 tools, several VC-backed (emdash is YC W26,
  vibe-kanban 27.7k★). Unwinnable, and it fights the premise: AgentMill is for
  work you leave running, not work you watch.
- **Swarm coordination / agent-to-agent messaging.** ruflo is at 67k★.
- **Issue-queue and CI integration.** Anthropic's, OpenAI's and Google's own
  official Actions own this end.
- **Star-count parity with ralph-claude-code.** Different game. The MEA angle
  reaches a smaller audience that cares more.

## Sequencing

P0 items are days, not weeks, and gate everything else — a first-time user who
watches it commit garbage overnight does not come back. P1 item 4 is the post,
the README lede, and the reason to submit anywhere. P1 item 5 is what makes
item 4 legible to someone who will not read an architecture diagram.

Hold the awesome-list submission until 4 and 5 exist. Submitting now spends the
one first impression on a project that reads as the twelfth Ralph loop.
