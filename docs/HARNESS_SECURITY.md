# Safe Harness Standards for Long-Running Agents

Research date: 2026-05-29. Sources were gathered with BrightData MCP search and
scraping. This document turns the current 2025-2026 guidance into concrete
controls for AgentMill's long-running agent harness.

## Executive summary

The recent consensus is clear: long-running agents are not made safe by better
prompts alone. A safe harness must separate the model loop from the execution
environment, keep durable state outside the context window, mediate every tool
call, limit credentials and egress, and maintain an append-only audit trail.

The strongest current pattern is:

1. A planner or initializer creates explicit task state and done criteria.
2. A generator works on one bounded increment.
3. A separate evaluator or judge verifies the increment before it is marked
   complete.
4. The harness writes all material state to files, git, and structured event
   logs.
5. The execution sandbox, credentials, MCP servers, and outbound network are
   policy controlled rather than trusted.

AgentMill already implements part of this shape: fresh Claude invocations,
git-backed progress, container hardening, bounded push retries, shared markdown
memory, and task completion sentinels. The main safety gaps are tool/MCP
scoping, network egress policy, credential isolation, clone-mode isolation for
untrusted repos, structured events, and runtime guardrails around destructive
or externally communicating actions.

## Source set

Primary sources used:

- Anthropic, "Effective harnesses for long-running agents" (Nov 26, 2025):
  initializer agent, feature list, incremental coding sessions, progress file,
  git commits, end-to-end verification.
- Anthropic, "Harness design for long-running application development" (Mar 24,
  2026): planner/generator/evaluator architecture, sprint contracts, external
  evaluation, Playwright-based verification, cost and duration tradeoffs.
- Anthropic, "Long-running Claude for scientific computing" (Mar 23, 2026):
  multi-day scientific coding with persistent files and git as portable memory.
- `anthropics/cwc-long-running-agents`: reference implementation for the Code
  with Claude long-running agent station.
- Addy Osmani, "Long-running Agents" (Apr 28, 2026): brain/hands/session split,
  checkpoint-and-resume, delegated approval, memory-layered context, ambient
  processing, and fleet orchestration.
- Geoffrey Huntley, "Ralph Wiggum as a software engineer" (Jul 14, 2025):
  respawning loop, one item per loop, signs/specs/backpressure, tests as
  mechanical rejection.
- OWASP, "Agentic AI - Threats and Mitigations" (Feb 17, 2025) and "OWASP Top
  10 for Agentic Applications for 2026" (Dec 9, 2025).
- OWASP Top 10 for LLM Applications 2025, especially Prompt Injection,
  Excessive Agency, Sensitive Information Disclosure, Supply Chain, and
  Unbounded Consumption.
- Model Context Protocol security best practices and authorization
  documentation, including confused deputy, token passthrough, SSRF, session
  hijacking, local MCP server compromise, and scope minimization.
- Cloud Security Alliance, "Agentic MCP Security Best Practices Guide": MCP
  threat categories, maturity levels, tool integrity verification, session
  hardening, supply-chain controls, and behavioral monitoring.
- Cloud Security Alliance draft "NIST AI Risk Management Framework: Agentic
  Profile" (Mar 27, 2026) and CSA AI Controls Matrix material.
- NIST AI Agent Standards Initiative (Feb 17, 2026) and NIST AI 600-1,
  "Artificial Intelligence Risk Management Framework: Generative Artificial
  Intelligence Profile" (Jul 2024).
- Google SAIF agent guidance and Google's layered prompt-injection defense post
  (Jun 13, 2025).
- Microsoft, "Protecting against indirect prompt injection attacks in MCP" (Apr
  28, 2025).
- CaMeL, "Defeating Prompt Injections by Design" (arXiv:2503.18813, v2 Jun 24,
  2025).
- "Design Patterns for Securing LLM Agents against Prompt Injections"
  (arXiv:2506.08837, v3 Jun 27, 2025).
- Docker AI Sandboxes security model and Docker Compose/Docker Engine hardening
  references.
- OpenAI Agents SDK guardrails documentation for input, output, and tool-call
  guardrail placement.

## Long-running harness standard

### 1. External state is the agent's real memory

Anthropic's harness work and the Ralph pattern converge on the same rule:
anything needed after a context reset must live outside the model context.
For coding agents that means a task list, progress file, git log, verifier
commands, and short durable summaries. For research agents it means `TASK.md`,
`REPORT.md`, `memory/*.md`, source logs, and citations.

AgentMill implication:

- Keep `TASK.md`, `memory/`, `logs/results.tsv`, and git commits as mandatory
  orientation inputs.
- Add `logs/events.jsonl` so the session history is machine-readable and
  replayable.
- Store completion gate evaluations in a structured file, not only in free-form
  logs. AgentMill writes done-file, research, coder, and refactor gate
  evaluations to `logs/convergence.tsv`.

### 2. Initializer, generator, evaluator

Anthropic's 2025 harness uses an initializer agent plus recurring coding agent.
The 2026 follow-up goes further: planner, generator, and evaluator are separate
roles. The evaluator negotiates a sprint contract before implementation and
then tests the result through a live application, often with browser automation.

AgentMill implication:

- Formalize profiles such as `coder`, `reviewer`, `researcher-breadth`,
  `researcher-depth`, and `researcher-redteam`.
- Support role-specific prompts, models, MCP allowlists, network policy,
  branch policy, and completion gates.
- Treat a self-assessment from the generator as weak evidence. A judge,
  verifier, or explicit test gate must mark completion.

### 3. One bounded increment per run

Ralph and Anthropic both emphasize incremental progress. A long-running agent
fails when it tries to one-shot a large product or silently redefines "done".
The safe shape is one bounded task, one commit, one verifier pass, one durable
handoff.

AgentMill implication:

- `PROMPT.md` should keep "complete exactly one task, then exit" as a hard rule.
- `mill exec` should become the CI-friendly one-shot primitive.
- `MAX_ITERATIONS`, time, token, and cost gates should be first-class stop
  criteria.

### 4. Completion must be mechanical

The modern standard is not "the agent says done". Completion is a structured
predicate: task item done, tests pass, end-to-end checks pass, no open blocking
questions, budget not exceeded, and completion sentinel emitted only after
verification.

AgentMill implication:

- Keep `TASK_COMPLETE`, but pair it with typed convergence events.
- Add per-mode gates:
  - coding: implemented as `coder_verified`; requires the done signal,
    `AGENTMILL_VERIFIER_COMMAND` success, and open questions below threshold;
  - research: implemented as `research_saturation`; requires source
    saturation and open questions below threshold;
  - refactor: implemented as `refactor_verified`; requires the done signal,
    verifier success, and configured LOC-delta thresholds.
- Make "tests removed or weakened" a failure unless a reviewer approves it.

### 5. Append-only event log

The emerging production architecture separates brain, hands, and session. The
session is an append-only event log that can reconstruct tool calls, decisions,
outputs, and failures after a crash or sandbox replacement.

AgentMill implication:

- `logs/events.jsonl` is the highest-leverage next primitive.
- Minimum events:
  - `iteration.started`
  - `orientation.loaded`
  - `tool.invoked` with tool name and redacted args summary
  - `tool.blocked`
  - `commit.created`
  - `push.attempted`, `push.rebased`, `push.failed`
  - `verifier.started`, `verifier.completed`
  - `convergence.evaluated`
  - `iteration.completed` or `iteration.failed`
- Do not log full secrets, full tool outputs, or scraped untrusted content into
  the event log.

## Threat model for AgentMill

Long-running agents combine several dangerous properties:

- private repository and host config access;
- untrusted content from web pages, issues, dependencies, prompts, logs, and
  target repo files;
- shell, git, network, package-manager, and MCP tool access;
- durable memory that can carry poisoned instructions across runs;
- autonomous loops that may continue after the first unsafe action;
- credentials that can push code, read private repos, or call model APIs.

Simon Willison's "lethal trifecta" is the simplest test: if an agent can read
private data, ingest untrusted content, and communicate externally, prompt
injection can become data exfiltration. AgentMill often has all three unless
profiles deliberately split them.

### High-risk assets

- host model credentials and OAuth tokens;
- git remotes and branch permissions;
- local repo contents, `.git/config`, hooks, and CI files;
- host Claude config, skills, agents, commands, and MCP definitions;
- package manager tokens and SSH keys accidentally mounted into the repo;
- `memory/` and `logs/`, because poisoned state can affect future runs;
- Docker daemon or container runtime access if exposed to the agent.

### High-risk operations

- shell commands with broad filesystem or network effects;
- `git push`, branch deletion, force-push, workflow edits;
- package installs and postinstall scripts;
- local MCP server startup commands;
- tools that read private data and tools that send network requests in the same
  run;
- tool definitions changing after approval, including MCP tool poisoning or
  rug-pull behavior;
- writing executable host-side files: `.git/hooks`, `.github/workflows`,
  `Makefile`, package scripts, IDE task configs.

## Safety controls by layer

### 1. Profile-level risk tiers

Add `AGENTMILL_PROFILE_LEVEL=trusted|standard|untrusted`.

| Level | Intended use | Default posture |
| --- | --- | --- |
| `trusted` | Operator-owned repo, low sensitivity, active supervision | current permissive automation, but with logging and budgets |
| `standard` | Normal project work on real repos | MCP allowlist, shell prefix policy, egress allowlist, scoped token, event log |
| `untrusted` | unfamiliar repo, web research, red-team, third-party code | clone mode, deny-by-default network, no host config forwarding except allowlisted MCP, no write to host repo |

The default should move toward `standard`; `trusted` should be explicit.

### 2. Workspace isolation

Docker's AI Sandboxes documentation makes the main tradeoff explicit: direct
mount mode gives the agent immediate write access to the host working tree,
while clone mode keeps the host repo read-only and requires explicit fetch or
merge.

AgentMill should adopt:

- Direct writable bind mounts only for `trusted` profiles.
- Clone mode or per-agent isolated workspaces for `standard` and `untrusted`.
- Branch startup checks for `AGENT_BRANCH` and protected branch names before
  write-capable runs.
- Explicit post-run review of files that can execute on the host:
  `.git/hooks`, `.github/workflows`, `Makefile`, package scripts, and IDE task
  files.
- No host Docker socket mount. If Docker-in-agent is needed, use a nested or
  isolated engine, not the host daemon.

### 3. Container and runtime hardening

Current AgentMill already uses a non-root `agent` user, `no-new-privileges`,
`cap_drop: [ALL]`, memory limits, and process limits. That matches container
hardening guidance, but a safer harness should also add:

- read-only root filesystem where possible, with writable `tmpfs` for `/tmp`;
- explicit durable writable roots only for the mounted repo,
  `/workspace/memory`, and `/workspace/logs`; AgentMill now runs containers
  with read-only root filesystems by default and uses tmpfs for runtime
  scratch/home/workspace staging. Optional `AGENTMILL_WRITE_ROOTS` / profile
  `write_roots` enforce repo-relative durable output roots through Claude
  `PreToolUse`, Codex permission profiles, Bubblewrap filesystem sandboxes for
  OpenCode/Qwen/Gemini native and ACP transports, and standard/untrusted
  auto-commit/push gates. If Bubblewrap cannot create the sandbox, AgentMill
  fails closed instead of running those clients unmediated;
- seccomp/AppArmor defaults or a tighter profile for `standard` and
  `untrusted`;
- `init: true` or equivalent process reaping;
- CPU and wall-clock limits in addition to memory and PID limits;
- rootless Docker or microVM isolation for high-risk runs.

### 4. Network policy

Google, OWASP, MCP, and Docker all converge on egress control. For long-running
agents, network access is not a binary "on/off"; it is a per-role capability.

AgentMill should implement:

- `network: deny|allowlist|allow` in `agents/<role>.toml`.
- Default `standard` allowlist:
  - model provider endpoint;
  - configured git remote host;
  - configured package registries if setup requires them;
  - explicitly allowed MCP servers.
- Default `researcher` allowlist: BrightData MCP and selected source domains,
  not arbitrary shell `curl`.
- Always block link-local, loopback, private, and cloud metadata IP ranges from
  inside the agent unless explicitly needed for local dev.
- Route outbound HTTP(S) through a proxy that can log, redact, and enforce
  policy.

### 5. Credential isolation

Microsoft's MCP guidance and Docker's sandbox guidance both point to the same
principle: do not hand broad ambient secrets to the execution environment.
Current Compose expansion can expose model tokens as environment variables; that
is acceptable for a local prototype but not for `standard` or `untrusted`.

AgentMill should implement:

- short-lived, per-agent credentials rather than broad personal tokens;
- git credentials scoped to the target remote and branch pattern;
- model credentials injected by a host-side proxy where possible, not readable
  as files or environment variables in the sandbox;
- no token passthrough for MCP servers: tokens must be audience-bound to the
  receiving MCP server;
- secret redaction in `mill status`, `docker compose config` guidance, logs,
  and event files;
- revocation instructions in incident response docs.

### 6. MCP and tool policy

MCP expands the tool surface dramatically. The official MCP security guidance
calls out confused deputy attacks, token passthrough, SSRF, session hijacking,
local MCP server compromise, and scope minimization. Microsoft and Invariant
Labs also highlight tool poisoning: malicious instructions in tool descriptions
that may be invisible to the user but visible to the model.

AgentMill should change from "enable all project MCP servers" to:

- per-role MCP allowlists;
- explicit approval before enabling any local MCP startup command;
- exact command display and diff when MCP definitions change;
- tool manifest snapshotting: name, description hash, input schema hash, server
  identity, and scopes;
- warnings or blocks for tool description changes after approval;
- local MCP servers launched in the same sandbox policy as the agent;
- remote MCP servers requiring HTTPS, OAuth 2.1 where applicable, audience-bound
  tokens, and exact redirect URI validation;
- scope minimization and incremental elevation, not omnibus scopes;
- no automatic trust of target repo `.mcp.json` in `standard` or `untrusted`.

### 7. Shell and file mediation

OWASP Excessive Agency maps directly to shell access. A shell tool is an
open-ended extension. It should be treated as dangerous unless bounded by
policy.

AgentMill should implement:

- tokenized command-prefix allow and deny rules using shell parsing, not raw
  string prefixes;
- high-risk deny defaults: `rm -rf`, `sudo`, chmod/chown outside workspace,
  secret-reading paths, host mount writes, force-push, workflow tampering;
- high-impact action approval hooks for:
  - force-push or branch deletion;
  - deleting many files;
  - modifying CI, hooks, package scripts, auth config, or deploy scripts;
  - external network calls from non-research roles;
  - new local MCP server startup commands.
- profile-aware auto-commit defaults so non-trusted TUI sessions do not
  automatically stage the full worktree.
- file write roots per role.

### 8. Prompt-injection defenses

Google and Microsoft both present layered defenses rather than claiming a single
guardrail can solve prompt injection. CaMeL and the design-patterns paper push
the principle further: untrusted data must not be allowed to steer control flow
or unauthorized data flow.

AgentMill should implement the practical version:

- label scraped web content, issue text, dependency docs, and target repo files
  as untrusted observations;
- never let untrusted content directly modify tool policy, credentials, MCP
  configuration, or completion gates;
- keep private data, untrusted content, and external communication split across
  profiles where possible;
- use blocking guardrails before side-effectful tools, not only output
  filtering after the fact;
- sanitize markdown/images/URLs in rendered summaries and logs;
- require human confirmation or reviewer hooks for destructive actions;
- maintain prompt-injection red-team fixtures in tests.

### 9. Memory and state hygiene

Long-running agents are vulnerable to memory poisoning because a malicious or
wrong note can survive many context resets.

AgentMill should implement:

- frontmatter schema for memory topics: type, source, created, last_iteration,
  trust, and provenance;
- separate trusted decisions from untrusted findings;
- red-team review for changes to `memory/decisions.md` and completion criteria;
- dedup and rotation for large memories;
- "poison canary" tests: malicious instructions in findings must not alter
  tool policy or exfiltrate secrets.

### 10. Observability and incident response

Google SAIF and OpenAI's Agents SDK docs both emphasize observability and
guardrail placement. For a long-running harness, auditability is a safety
control, not a convenience feature.

AgentMill should implement:

- append-only `logs/events.jsonl`;
- event correlation IDs for each iteration and tool call;
- redacted args/results for sensitive tools;
- cost and token counters per iteration;
- anomaly signals: unexpected tool, external domain, permission elevation,
  repeated verifier failure, large deletion, memory edit, new MCP tool;
- kill switch: stop container, revoke token, preserve logs, snapshot repo;
- rollback flow: git revert or branch reset from last verified commit.

## Standards crosswalk

| Control family | Key sources | AgentMill implementation target |
| --- | --- | --- |
| Durable state and handoff | Anthropic harness posts, Ralph, Addy Osmani | `TASK.md`, `memory/`, git, `logs/events.jsonl` |
| Planner/generator/evaluator | Anthropic 2026 harness, Addy Osmani survey | role profiles, reviewer/redteam prompts, verifier gates |
| Prompt injection | OWASP LLM01, Google, Microsoft, CaMeL, design-patterns paper | untrusted-content labeling, blocking tool guardrails, profile separation |
| Excessive agency | OWASP LLM06, OWASP Agentic Top 10 | shell/MCP allowlists, approval hooks, least privilege |
| Tool and MCP security | MCP security best practices, CSA MCP guide, Microsoft | MCP allowlists, manifest snapshots, OAuth/audience/scope checks |
| Credential isolation | Docker sandbox docs, MCP auth guidance, Microsoft | host-side credential proxy, short-lived tokens, no broad env secrets |
| Egress control | Docker sandbox docs, MCP SSRF guidance, Google | deny-by-default or allowlist proxy, block private/link-local ranges |
| Runtime isolation | Docker sandbox docs, Docker Compose/Engine, NIST container guidance | non-root, caps dropped, read-only fs, rootless/microVM for untrusted |
| Observability | Google SAIF, OpenAI tracing/guardrails, Anthropic session logs | structured events, cost logs, anomaly alerts |
| Governance | NIST AI RMF, NIST AI 600-1, CSA Agentic Profile, CSA AICM | profile levels, owner/accountability, incident response |

## Recommended AgentMill backlog

The active implementation track is maintained in
[`HARNESS_IMPLEMENTATION_PLAN.md`](HARNESS_IMPLEMENTATION_PLAN.md).

P0 - make unsafe states visible:

- Add `logs/events.jsonl`.
- Redact secrets from logs and documentation examples.
- Baseline `mill doctor` checks are implemented for auth, Docker availability,
  writable repo mode warnings, broad MCP enablement, missing
  standard/untrusted budget gates, hooks, prompts, `.env` schema,
  model-version floors, git state, image freshness, read-only mounts, and
  latest MCP manifest allowlist/reachability state. Docker socket mount checks
  and deeper host config validation remain.
- Add `docs/SECURITY.md` threat model section for untrusted repos, hostile MCP
  servers, leaked auth, and prompt injection.

P1 - policy profiles:

- `agents/<role>.toml` and `AGENTMILL_PROFILE_LEVEL=trusted|standard|untrusted`
  are implemented.
- Basic per-role MCP allowlists, project-MCP filtering, and host skill
  allowlists are implemented.
- Host config forwarding now fails closed outside `trusted` for host
  `allowedTools`, hooks, env, plugins, skills, agents, and commands unless the
  run explicitly opts into the corresponding `AGENTMILL_FORWARD_HOST_*` knob.
  Host skills are additionally filtered by `AGENTMILL_SKILL_ALLOWLIST` outside
  `trusted`. Host settings cannot overwrite safer non-trusted `defaultMode`
  values.
- MCP manifest snapshots are implemented for configured server names, config
  hashes, redacted launch reachability metadata, and best-effort live stdio MCP
  `tools/list` description/schema hashes; the manifest lock now detects
  tool-metadata rug-pulls across iterations when snapshots are available.
- Generated shell/network command denies are implemented in Claude settings for
  standard/untrusted profiles, Codex permission profiles and execpolicy prefix
  rules, and conservative native non-Claude client settings; harness-managed
  git fetch/rebase/push now enforces local-vs-network remote policy plus
  `AGENTMILL_GIT_REMOTE_ALLOWLIST`.
  Claude `PreToolUse` mediation, Codex permission profiles and execpolicy,
  Bubblewrap write-root sandboxes, post-session shell audit, write roots, typed
  completion gates, Docker `network_mode: none`, and the allowlist egress proxy
  are implemented.
  Remaining hardening work is exact
  PreToolUse-equivalent hooks where non-Claude CLIs expose them.
- Continue to keep project MCP disabled outside `trusted` unless a profile
  allowlist or explicit override enables it.

P2 - isolation:

- Clone-mode workflow is implemented for `mill run` and `mill watch`, not only
  multi-agent isolated clones.
- Read-only host repo mode is implemented for standard/untrusted CLI runs; the
  harness exports patch artifacts under `logs/patches/`, and `mill apply`
  provides an explicit merge-back path.
- Support egress proxy settings and private-IP/link-local blocking. Git remote
  allowlisting is implemented for harness-managed git operations, but shell and
  package-manager egress still need a container-level control.
- Move model/git credentials toward host-side injection or short-lived scoped
  tokens.

P3 - guardrails and hooks:

- Hook protocol with JSON decision objects is implemented for iteration,
  completion, and failure hooks. Hooks can be global, profile-scoped, or
  role-scoped, and matching hooks fail closed on the first non-allow decision.
- High-risk file-change gate is implemented for standard/untrusted commit/push
  paths.
- Generated Bash denies cover high-risk and shell-network command patterns.
  Claude runs now install an AgentMill `PreToolUse` hook for disallowed Bash,
  web, MCP, subagent, and write/edit calls; headless session logs are also
  audited with parsed argv-token prefix matching before auto-commit/push.
  Codex runs now get generated permission profiles, execpolicy prefix rules,
  and non-trusted approval gating; Qwen/OpenCode/Gemini get the strongest
  native setting or shell disablement each CLI exposes.
- Add approval hooks for destructive or externally communicating actions.
  Current git remote action policy validates push/rebase refs and denies
  force-push by default, and blocks or allowlists network git origins before
  harness-managed remote side effects; broader high-impact approval hooks
  remain.
- Add prompt-injection regression fixtures.

P4 - governance and operations:

- Add cost/token/time gates. AgentMill now enforces wall-clock, log-size, and
  parsed usage token/USD gates; broader adapter coverage remains.
- Add incident response runbook.
- Extend MCP rug-pull detection beyond stdio servers where client APIs expose
  live tool metadata.
- Add memory schema, dedup, and trust/provenance fields.

## Minimal safe defaults

For a real repository, the default safe profile should be:

```toml
profile_level = "standard"
network = "allowlist"
allow_domains = ["api.anthropic.com", "github.com", "githubusercontent.com"]
mcp_allowlist = []
shell_policy = "allowlist"
write_roots = ["src", "tests", "docs"]
direct_host_mount = false
clone_mode = true
auto_enable_project_mcp = false
max_iterations = 10
max_total_usd = 20
require_verifier_before_complete = true
```

For research mode:

```toml
profile_level = "standard"
network = "allowlist"
mcp_allowlist = ["BrightData"]
allow_domains = ["api.anthropic.com"]
shell_policy = "restricted"
write_roots = ["reports", "notes", "docs"]
external_communication_tools = ["BrightData"]
private_data_tools = []
require_citations = true
completion_gate = "research_saturation"
research_saturation_iterations = 3
research_open_questions_max = 0
```

For coding/refactor roles:

```toml
completion_gate = "coder_verified"      # or "refactor_verified"
verifier_command = "make test"          # project-specific and fail-closed
coder_open_questions_max = 0
refactor_loc_target = -20               # optional signed net line delta
refactor_loc_tolerance = 10
```

For untrusted third-party repos:

```toml
profile_level = "untrusted"
network = "deny"
mcp_allowlist = []
shell_policy = "restricted"
direct_host_mount = false
clone_mode = true
host_config_forwarding = false
credential_injection = "none"
require_human_approval_for_push = true
```

## Practical bottom line

AgentMill should keep the Ralph-style respawning loop because it is aligned with
the best current long-running-agent practice. The safety work is not to remove
autonomy; it is to make autonomy conditional:

- one bounded task at a time;
- limited tools for the role;
- no ambient broad credentials;
- no unmediated egress;
- no direct host writes for untrusted runs;
- structured events for every iteration;
- independent verification before completion.

Those controls are the difference between "a shell script that loops an LLM" and
a harness that can safely run for hours or days.

## References

- Anthropic, "Effective harnesses for long-running agents":
  <https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents>
- Anthropic, "Harness design for long-running application development":
  <https://www.anthropic.com/engineering/harness-design-long-running-apps>
- Anthropic, "Long-running Claude for scientific computing":
  <https://www.anthropic.com/research/long-running-Claude>
- Anthropic reference repo:
  <https://github.com/anthropics/cwc-long-running-agents>
- Addy Osmani, "Long-running Agents":
  <https://addyosmani.com/blog/long-running-agents/>
- Geoffrey Huntley, "Ralph Wiggum as a software engineer":
  <https://ghuntley.com/ralph/>
- OWASP, "Agentic AI - Threats and Mitigations":
  <https://genai.owasp.org/resource/agentic-ai-threats-and-mitigations/>
- OWASP, "Top 10 for Agentic Applications for 2026":
  <https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/>
- OWASP Top 10 for LLM Applications:
  <https://owasp.org/www-project-top-10-for-large-language-model-applications/>
- MCP security best practices:
  <https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices>
- Cloud Security Alliance, "Agentic MCP Security Best Practices Guide":
  <https://labs.cloudsecurityalliance.org/agentic/agentic-mcp-security-best-practices-v1/>
- Cloud Security Alliance, "NIST AI RMF: Agentic Profile":
  <https://labs.cloudsecurityalliance.org/agentic/agentic-nist-ai-rmf-profile-v1/>
- Cloud Security Alliance, "AI Controls Matrix":
  <https://cloudsecurityalliance.org/artifacts/ai-controls-matrix>
- NIST, "AI Agent Standards Initiative":
  <https://www.nist.gov/artificial-intelligence/ai-agent-standards-initiative>
- NIST, "Artificial Intelligence Risk Management Framework: Generative
  Artificial Intelligence Profile":
  <https://www.nist.gov/publications/artificial-intelligence-risk-management-framework-generative-artificial-intelligence>
- Google SAIF, "Components of Generative AI Systems":
  <https://saif.google/focus-on-agents>
- Google, "Mitigating prompt injection attacks with a layered defense strategy":
  <https://blog.google/security/mitigating-prompt-injection-attacks/>
- Microsoft, "Protecting against indirect prompt injection attacks in MCP":
  <https://developer.microsoft.com/blog/protecting-against-indirect-injection-attacks-mcp>
- CaMeL, "Defeating Prompt Injections by Design":
  <https://arxiv.org/abs/2503.18813>
- "Design Patterns for Securing LLM Agents against Prompt Injections":
  <https://arxiv.org/abs/2506.08837>
- Docker AI Sandboxes security model:
  <https://docs.docker.com/ai/sandboxes/security/>
- Docker AI Sandboxes isolation layers:
  <https://docs.docker.com/ai/sandboxes/security/isolation/>
- Docker Engine rootless mode:
  <https://docs.docker.com/engine/security/rootless/>
- Docker Compose service hardening options:
  <https://docs.docker.com/reference/compose-file/services/>
- OpenAI Agents SDK guardrails:
  <https://openai.github.io/openai-agents-python/guardrails/>
