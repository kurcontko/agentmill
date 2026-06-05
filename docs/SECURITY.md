# AgentMill Security Threat Model

This document captures the security baseline for long-running AgentMill runs.
It is scoped to the current architecture: a selected AI coding client runs in a
Docker container, with Claude Code as the default client and additional
adapters for Codex, OpenCode, Qwen Code, Gemini CLI, ACP, and the fake test
client. Runs have mounted or read-only-clone repo access, shared `memory/` and
`logs/`, optional host config forwarding, MCP/tool access, and optional
multi-agent branches.

The design goal is not to make the model trusted. The design goal is to keep
untrusted model output, untrusted repository content, untrusted web content,
and untrusted MCP/tool metadata inside enforceable boundaries.

## Current Standards Baseline

As of May 2026, the most relevant public guidance converges on these controls:

- NIST AI RMF and the Generative AI Profile (`NIST AI 600-1`) use the
  Govern/Map/Measure/Manage loop and call out information security, information
  integrity, data privacy, provenance, monitoring, and value-chain/component
  risks for generative AI systems.
- NIST CAISI's 2026 AI Agent Standards Initiative specifically focuses on
  agent authentication, identity infrastructure, secure human-agent and
  multi-agent interactions, and security considerations for agent systems.
- NIST NCCoE's 2026 concept paper on software and AI agent identity and
  authorization highlights agent identity, delegated authority, logging,
  transparency, prompts, data-input provenance, and policy-based authorization.
- OWASP LLM01:2025 treats direct and indirect prompt injection as unavoidable
  enough that mitigations must include least privilege, external-content
  segregation, deterministic output validation, human approval for high-risk
  actions, and adversarial testing.
- OWASP LLM06:2025 Excessive Agency decomposes agent failures into excessive
  functionality, excessive permissions, and excessive autonomy. Its mitigation
  direction maps directly to tool minimization, scoped credentials, complete
  mediation outside the model, and approval gates.
- OWASP LLM10:2025 Unbounded Consumption maps to AgentMill's long-running risk:
  denial of wallet, resource exhaustion, rate limits, timeouts, budgets,
  monitoring, and graceful shutdown.
- OWASP Agentic AI Threats and Mitigations plus the Multi-Agentic System Threat
  Modeling Guide extend those risks to autonomous and multi-agent topologies.
- Google's secure-agent framework reduces agent safety to three core control
  planes: every agent needs a human controller, powers must be carefully
  limited, and actions/plans must be observable.
- Google's SAIF agent map calls out trusted command vs. untrusted context
  separation, agent memory poisoning, least-privilege tools, deceptive tool
  descriptions, and orchestration risks.
- Microsoft guidance for MCP prompt injection identifies indirect prompt
  injection and tool poisoning as MCP-specific risks, especially when tool
  metadata can change after approval. It recommends prompt shields, delimiters
  or data marking, supply-chain controls, and normal security hygiene.
- GitHub Copilot cloud agent documentation and changelogs emphasize an agent
  firewall for limiting internet access and reducing prompt-injection-driven
  data exfiltration. GitHub also exposes cloud-agent MCP, tool, workflow, and
  firewall configuration for audit.
- Anthropic and OpenAI long-running harness writeups converge on repo-local
  structured state, short incremental work units, git history, explicit
  verification, observable logs/metrics, and mechanical completion criteria.
- Cloud Security Alliance agentic AI guidance is not a formal standard, but it
  is useful implementation guidance: autonomy tiers, tool risk classification,
  behavioral telemetry, delegation-chain monitoring, agent compromise response,
  kill switches, tool-gateway chokepoints, and verifiable non-human identity.

Primary references:

- https://www.nist.gov/itl/ai-risk-management-framework
- https://nvlpubs.nist.gov/nistpubs/ai/NIST.AI.600-1.pdf
- https://www.nist.gov/caisi/ai-agent-standards-initiative
- https://www.nccoe.nist.gov/sites/default/files/2026-02/accelerating-the-adoption-of-software-and-ai-agent-identity-and-authorization-concept-paper.pdf
- https://genai.owasp.org/llmrisk/llm01-prompt-injection/
- https://genai.owasp.org/llmrisk/llm062025-excessive-agency/
- https://genai.owasp.org/llmrisk/llm102025-unbounded-consumption/
- https://genai.owasp.org/resource/agentic-ai-threats-and-mitigations/
- https://genai.owasp.org/resource/multi-agentic-system-threat-modeling-guide-v1-0/
- https://research.google/pubs/an-introduction-to-googles-approach-for-secure-ai-agents/
- https://saif.google/focus-on-agents
- https://developer.microsoft.com/blog/protecting-against-indirect-injection-attacks-mcp
- https://docs.github.com/en/copilot/responsible-use/copilot-cloud-agent
- https://docs.github.com/copilot/how-tos/use-copilot-agents/cloud-agent/customize-the-agent-firewall
- https://github.blog/changelog/2026-04-03-organization-firewall-settings-for-copilot-cloud-agent/
- https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- https://www.anthropic.com/engineering/harness-design-long-running-apps
- https://openai.com/index/harness-engineering/
- https://labs.cloudsecurityalliance.org/agentic/agentic-nist-ai-rmf-profile-v1/
- https://labs.cloudsecurityalliance.org/agentic/agentic-mcp-security-best-practices-v1/

## Trust Boundaries

AgentMill has seven security-relevant boundaries:

1. **Operator to agent.** The operator provides the task, repo, env, auth, and
   profile. The agent must not be able to silently expand those authorities.
2. **Agent to target repo.** The target repo is untrusted input. Its source,
   tests, docs, hooks, package scripts, MCP config, and prompt-like files can
   contain adversarial instructions.
3. **Agent to host.** The container should not write outside mounted work roots,
   read host secrets, access Docker, or mutate host Claude config.
4. **Agent to credentials.** API keys, OAuth tokens, Git credentials, and MCP
   credentials must be scoped, short lived where possible, and absent from logs.
5. **Agent to tools.** Bash, web, MCP, skills, plugins, hooks, and git are
   capability grants. Their policy must be enforced by the harness, not by the
   model's promise to behave.
6. **Agent to network.** Internet access is a data-exfiltration path. If an
   agent has secrets and repo contents, outbound traffic needs policy.
7. **Agent to memory/logs.** `memory/`, `logs/results.tsv`, future
   `logs/events.jsonl`, and session logs are durable context. Treat them as
   untrusted inputs on read and sensitive outputs on write.

## Threats

### Prompt Injection and Context Poisoning

Sources: repo docs, issue text, web pages, scraped markdown, package READMEs,
MCP tool descriptions, memory files, logs, generated prompts, and agent-to-agent
messages. Direct and indirect prompt injection can make the model call tools,
leak secrets, corrupt memory, or mark work complete too early.

Required controls:

- Mark external content and memory as untrusted in prompts and docs.
- Keep source URLs/provenance for research findings and agent decisions.
- Validate structured outputs with deterministic code.
- Never rely on prompt text as the only authorization boundary.

### Excessive Agency

Current risk: the `trusted` profile allows broad tool categories including
`Bash`, `WebFetch`, `WebSearch`, `Agent`, `NotebookEdit`, and `mcp__*`, while
the CLI runs Claude with `--dangerously-skip-permissions`. `standard` and
`untrusted` now generate narrower Claude settings, but those settings are not
yet a complete side-effect boundary without hook/policy enforcement.

Required controls:

- Add per-profile tool allowlists and denylists.
- Add a Bash command prefix policy using parsed argv tokens, not string prefix
  checks.
- Add MCP and skill allowlists per role/profile.
- Put complete mediation in the entrypoint/hook layer, not in model text.
- Require human approval or a hook veto path for destructive, credential,
  publish, deploy, or external-network actions.

### Credential and Data Exfiltration

Secrets can leak through shell commands, git remotes, web requests, MCP calls,
logs, memory, commits, PR text, package-manager scripts, or agent-created files.

Required controls:

- Prefer short-lived scoped credentials over user-level tokens.
- Separate "has secrets" from "has arbitrary internet" where practical.
- Redact known secret patterns before writing session logs, events, memory, or
  results.
- Deny or gate `curl`, `wget`, arbitrary network clients, and broad MCP tools
  in standard/untrusted profiles.
- Add egress allowlists for package registries and approved web fetchers. Git
  remote allowlisting is implemented for harness-managed fetch/rebase/push.

### MCP, Skill, and Plugin Supply Chain

Current risk: host MCP servers, plugins, skills, agents, commands, and project
`.mcp.json` can be forwarded or enabled broadly. MCP tool metadata can itself
be prompt-injection payload. Remote MCP servers can change behavior after a
user previously approved them.

Required controls:

- Disable "enable all project MCP servers" for untrusted and standard profiles.
- Make MCP availability explicit in `agents/<role>.toml`.
- Record MCP server names, tool names, and config fingerprints in
  `logs/events.jsonl`.
- Fail closed when an MCP server appears that the profile did not allow.
- Treat MCP tool descriptions as untrusted text and keep them out of durable
  memory unless explicitly quoted as evidence.

### Unbounded Consumption

Long-running loops can burn model spend, package-manager time, network
quota, disk, logs, and CI minutes. Infinite `MAX_ITERATIONS=0` is a deliberate
mode, but it needs a budget envelope.

Required controls:

- Add `MAX_TOTAL_TOKENS`, `MAX_TOTAL_USD`, and wall-clock deadline gates.
- Parse Claude JSON output for token/cost telemetry.
- Emit per-iteration usage to `logs/events.jsonl` and `logs/results.tsv`.
- Add loop-level rate limits and max tool-call counters per iteration.
- Make infinite runs opt-in for standard/untrusted profiles.

### Multi-Agent Delegation and Memory Poisoning

Shared memory and branches coordinate agents, but they are also cross-agent
attack surfaces. A compromised agent can poison `memory/`, claim tasks forever,
or push misleading commits that other agents trust.

Required controls:

- Add `run_id`, `agent_id`, `profile`, and branch to every event and memory
  entry.
- Add typed memory frontmatter and source/provenance fields.
- Treat memory as claims requiring verification, not as authority.
- Add stale-claim cleanup and claim TTLs.
- Add multi-agent policy checks for cross-branch pushes and unexpected remotes.

### Completion Drift

AgentMill already has a sentinel and numeric completion gate, but long-running
agents still tend to declare completion early unless the harness requires
evidence.

Required controls:

- Keep completion criteria in structured files where possible.
- Require verifier evidence before completion events.
- Emit `convergence.evaluated` events with gate name, value, threshold, and
  pass/fail.
- Keep research saturation separate from coding completion.

## Recommended Profile Levels

### `untrusted`

For unfamiliar repos, red-team inputs, external issue text, and research over
untrusted web pages.

- Network: deny by default; allow BrightData or explicit domains only.
- Tools: `Read`, `Grep`, `Glob`, `Edit`, `Write`; Bash only through prefix
  policy; no broad `mcp__*`.
- Host config: do not forward host plugins, skills, agents, or project MCP
  servers unless explicitly enabled; host skills and MCP servers must also be
  named in allowlists outside `trusted`.
- Project-local `.claude/skills` and `.claude/agents` remain separate from
  host-copied extensions and are the preferred repo-scoped override surface.
- Git: local commits allowed; push disabled unless explicitly enabled.
- Budgets: finite iterations, finite time, finite token/USD limit required.

### `standard`

For normal coding in repos the operator controls.

- Network: allow package registries and configured git remotes; deny arbitrary
  exfiltration paths by default.
- Tools: coding tools plus explicitly allowlisted MCP servers.
- Git: push to agent branches allowed; main branch protected by policy.
- Hooks: pre/post iteration hooks may veto commits, pushes, and high-risk tool
  actions.
- Budgets: finite default, infinite requires explicit env override.

### `trusted`

For local, fully trusted repos and operator-supervised automation.

- Network: allowed.
- Tools: current broad toolset can remain available.
- Git: push behavior as today.
- Audit: still emit events and cost telemetry.
- This profile is the only one that should resemble current
  `bypassPermissions` defaults.

## Implementation Order

The security work should move earlier than general sandbox polish. A practical
order for AgentMill is:

1. **Structured events.** Add append-only `logs/events.jsonl` with
   `version`, `run_id`, `agent_id`, `profile`, `iteration`, `timestamp`,
   `type`, and redacted event payloads. Start with iteration lifecycle,
   commit, push, convergence, budget, and policy decisions. Lifecycle, commit,
   push, and sentinel convergence events are implemented for headless,
   watch, and interactive runs; headless session logs and agent logs are
   redacted before durable writes. `logs/convergence.tsv` records current
   gate evaluations. Explicit `iteration.failed` events cover policy blocks,
   nonzero Claude exits, and push failures. Parsed headless JSON logs now emit
   tool and usage events; broader adapter coverage remains.
2. **Profile-aware settings.** Add `AGENTMILL_PROFILE_LEVEL` and generate
   settings from `trusted|standard|untrusted`. Keep the current permissive
   settings only for `trusted`. Built-in role profiles now select profile
   level, prompt, model, branch pattern, budget defaults, and MCP allowlists.
3. **MCP and skill allowlists.** Stop enabling all project MCP servers by
   default. Make `agents/<role>.toml` the source of truth. MCP allowlist
   filtering, manifest snapshots, live stdio tool metadata hashes, and host
   skill allowlists are implemented. Host config forwarding now fails closed
   outside `trusted` for host tools, hooks, env, plugins, skills, agents, and
   commands unless the corresponding `AGENTMILL_FORWARD_HOST_*` knob is
   explicitly set.
4. **Bash prefix policy.** Non-trusted generated settings now deny common
   shell network clients and high-risk host/system commands through
   `Bash(...)` permission patterns. Claude runs also install an AgentMill
   `PreToolUse` hook that denies disallowed Bash, web, MCP, subagent, and
   write/edit tool calls before execution. Codex runs get generated permission
   profiles, execpolicy prefix rules, and non-trusted `untrusted` approval
   defaults; other clients get conservative native settings or shell
   disablement when prefixes cannot be represented. Headless session logs are
   audited with parsed argv-token prefix matching before auto-commit/push as a
   backstop.
5. **Network policy.** `network=allowlist|deny` now projects into WebFetch,
   WebSearch, shell network-client, git, and package-manager denies. Harness
   git fetch/rebase/push also enforces local-vs-network origin policy and
   `AGENTMILL_GIT_REMOTE_ALLOWLIST`. `mill` applies Docker `network_mode: none`
   for `deny` and an internal-network HTTP(S) egress proxy for
   `allowlist`; the proxy only connects to `AGENTMILL_EGRESS_ALLOWLIST` public
   targets.
6. **Budget gates.** Add token, cost, wall-clock, and disk/log size limits.
   `MAX_WALL_SECONDS` now covers wall-clock stopping and prevents unbounded
   standard/untrusted loops; `MAX_LOG_BYTES` covers log-size stopping;
   `MAX_TOTAL_TOKENS` and `MAX_TOTAL_USD` stop after cumulative parsed usage
   telemetry crosses budget. Disk limits remain.
7. **Hook protocol.** Add timeout-bounded JSON hooks for pre/post iteration,
   completion, failure, and high-risk actions. Pre/post iteration,
   completion, and failure hooks are implemented with fail-closed JSON
   decisions and global/profile/role scoping; high-risk action-specific hooks
   remain.
8. **High-risk file gate.** Standard/untrusted runs now block commit/push for
   CI workflows, MCP/Claude/Codex config, env files, package scripts,
   Makefiles, container config, deploy/release scripts, and auth/secret paths
   unless explicitly allowed.
9. **Read-only clone mode.** Standard/untrusted `mill run` and `mill watch`
   now use a read-only host repo mount by default and export patch artifacts
   from a container-local clone.
9a. **Read-only root filesystem.** Containers now run with read-only rootfs by
   default. Runtime scratch paths use tmpfs, and intended durable host writes
   are limited to the mounted repo, `logs/`, and `memory/`. Optional
   `AGENTMILL_WRITE_ROOTS` / profile `write_roots` scope Claude write/edit
   tools, Codex permission-profile workspace writes, and Bubblewrap
   filesystem sandboxes for OpenCode/Qwen/Gemini native and ACP transports. If
   Bubblewrap is unavailable, AgentMill fails closed rather than running those
   clients unmediated. Standard/untrusted auto-commit or push is also denied
   when changed repo files fall outside configured roots.
10. **Git branch policy.** Startup now rejects a checked-out branch that does
   not match `AGENT_BRANCH`, protects configured branches from
   standard/untrusted direct writes unless explicitly overridden, and makes TUI
   auto-commit default to off for non-trusted profiles. Push/rebase attempts
   validate refs, branch agreement, protected branches, and force-push denial
   before remote side effects, and harness-managed network `origin` remotes are
   gated by `AGENTMILL_NETWORK`, `AGENTMILL_ALLOW_GIT_NETWORK`, and
   `AGENTMILL_GIT_REMOTE_ALLOWLIST`. `mill` also applies Docker
   `network_mode: none` for selected services when `AGENTMILL_NETWORK=deny`,
   or an internal proxy network when `AGENTMILL_NETWORK=allowlist`.
   New merge commits are denied for standard/untrusted iterations unless
   explicitly overridden.
11. **Doctor preflight.** Baseline `mill doctor` validates auth, Docker, repo,
   prompt, hooks, budgets, broad MCP forwarding, high-risk overrides, profile,
   `.env` schema, model-version floors, git state, image freshness, readonly
   mounts, and latest MCP manifest allowlist/reachability state before
   long-running work.
12. **Memory hardening.** Add typed frontmatter, provenance, TTL cleanup, and
   secret redaction before durable writes.
13. **Incident response.** Add `mill kill`, automatic stop-on-policy-violation,
   and a short incident runbook for credential exposure, hostile MCP, runaway
   spend, and poisoned memory.

## Minimum Bar Before Routine Long Runs

Before AgentMill is treated as safe for routine overnight or multi-day runs:

- Standard/untrusted `MAX_ITERATIONS=0` runs must require `MAX_WALL_SECONDS`
  until token/USD gates are implemented.
- Every run must have a `run_id` and an event log.
- The selected profile and enabled MCP/tool set must be printed at startup and
  recorded in the event log.
- Session logs and memory writes must redact common API key/token patterns.
- Standard profile must not enable every host/project MCP server.
- Research profile must prefer BrightData and record fetched URLs before
  citation.
- Pushes must remain branch-scoped and retry-bounded.
- Completion must be a gate event with evidence, not only a model assertion.
