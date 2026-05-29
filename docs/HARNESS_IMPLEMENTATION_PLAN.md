# Harness Implementation Plan

This plan turns the research in `LONG_RUNNING.md`, `HARNESS_SECURITY.md`, and
`SECURITY.md` into an implementation track for making AgentMill a strong
long-running harness.

## Current Target

AgentMill should remain a Ralph-style respawning loop, but the harness should
make each run observable, bounded, policy-aware, and recoverable:

1. Every run has a stable `run_id`, profile, and append-only event stream.
2. Every iteration has durable lifecycle, completion, commit, and push events.
3. Profiles control tool, MCP, credential, network, and workspace authority.
4. Completion is a gate with evidence, not only a model assertion.
5. Long runs have budget, time, and incident-stop controls.

## Phase 0: Event Ledger and Profile Metadata

Status: partially implemented.

Implemented:

- `logs/events.jsonl` is emitted by headless, watch, and interactive runs.
- Events include `version`, `timestamp`, `run_id`, `agent_id`, `profile`,
  `iteration`, `type`, and redacted payload.
- Iteration lifecycle, Claude exit, sentinel-gate evaluation, commit, push, and
  run-completion events are emitted.
- `logs/convergence.tsv` records every current completion-gate evaluation with
  gate, pass/fail result, observed value, threshold, evidence, and hook
  decision.
- Headless JSON usage telemetry is parsed into `usage.recorded` events,
  `logs/usage.tsv`, and `results.tsv` usage columns; `MAX_TOTAL_TOKENS` and
  `MAX_TOTAL_USD` stop the loop after cumulative parsed usage crosses budget.
- Headless JSON tool telemetry is parsed into `tool.invoked`,
  `tool.completed`, `mcp.tool.invoked`, `mcp.tool.completed`, and
  `tool.summary` events without logging full argument or result values.
- `iteration.failed` events are emitted for pre/post hook policy blocks,
  high-risk change denials, nonzero Claude exits, and push failures.
- Headless session logs and shared agent logs are redacted before durable
  writes.
- `mill events` reads or tails the event log.
- `mill run --json` streams matching run events to stdout, redirects Compose
  progress to stderr, and emits a final `mill.run.completed` event.
- `AGENTMILL_PROFILE_LEVEL` is passed through Compose and recorded in events.
- Trusted profile preserves current broad MCP forwarding; standard/untrusted
  suppress host/project MCP forwarding unless `AGENTMILL_FORWARD_HOST_MCP=true`.
- `MAX_WALL_SECONDS` stops headless and respawn loops and is required for
  unbounded standard/untrusted runs.
- `MAX_LOG_BYTES` stops loops when logs exceed the configured byte budget and
  emits `budget.exhausted`.

Remaining:

- Extend parsed tool-call coverage across all supported client adapters.
- Make token/cost payloads default and reliable across supported client
  adapters.
- Add full CI-friendly event coverage for `mill run --json`, especially
  `tool.*`, explicit failure events, and usage/cost payloads.

Verification:

- `bash tests/test_events_jsonl.sh`
- `bash tests/test_convergence_log.sh`
- `bash tests/test_mill_run_json.sh`
- `bash tests/test_iteration_failed_events.sh`
- `bash tests/test_log_redaction.sh`
- `bash tests/test_log_budget.sh`
- `bash tests/test_usage_budget.sh`
- `bash tests/test_tool_events.sh`
- existing push retry and model-resolution tests
- `bash -n` over shell entrypoints and CLI

## Phase 1: Profile Enforcement

Status: partially implemented.

Goal: make `trusted|standard|untrusted` more than metadata.

Implemented:

- Built-in `agents/<role>.toml` profiles for coder, reviewer,
  researcher-breadth, researcher-depth, researcher-redteam, refactor, and
  memory-curator.
- `mill profiles` and `mill profiles <role>` for inspection.
- `mill run <repo> --agent <role>` applies prompt, model, branch pattern,
  max iterations, wall-clock limit, profile level, MCP allowlist, and commit
  mode.
- `mill exec <repo> --agent <role>` applies the same profile and workspace
  policy, forces one iteration, and uses a one-off container for CI-style
  bounded work.
- `mill watch <repo> --agent <role>` applies the same profile defaults.
- `mill multi <repo> --roles A,B,C` maps roles to positional agents and emits
  per-agent env overrides.
- Standard/untrusted profiles can allowlist MCP servers; host/project MCP
  config is filtered to the allowlist.
- Startup enforces the resolved `AGENT_BRANCH` and denies standard/untrusted
  direct writes to configured protected branches unless read-only clone mode or
  `AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES=true` is in effect.
- Headless push/rebase attempts run through a remote-action policy that
  validates branch refs, current-branch agreement, protected-branch rules, and
  default force-push denial before remote side effects. The same policy now
  blocks network `origin` remotes under `AGENTMILL_NETWORK=deny` unless
  `AGENTMILL_ALLOW_GIT_NETWORK=true`, and enforces
  `AGENTMILL_GIT_REMOTE_ALLOWLIST` for harness-managed fetch/rebase/push.
- `mill` applies a Docker Compose `network_mode: none` override to selected
  services when their resolved `AGENTMILL_NETWORK` policy is `deny`, and an
  internal-network HTTP(S) egress proxy override when the policy is
  `allowlist`. The proxy only connects to `AGENTMILL_EGRESS_ALLOWLIST` public
  targets.

Deliverables:

- Per-role prompt/model/branch/default iteration settings. Implemented for
  current headless/watch/multi surfaces.
- Per-profile Claude settings templates. Implemented as generated settings
  from `AGENTMILL_PROFILE_LEVEL` plus `AGENTMILL_MCP_ALLOWLIST`.
- Fail-closed startup checks for malformed profile config.
- Stronger push/merge policy checks for branch patterns.

Acceptance evidence:

- Unit tests for profile parsing and env resolution. Implemented in
  `tests/test_agent_profiles.sh`.
- Settings test showing `standard` does not enable project MCP by default and
  does allow explicit MCP allowlists. Implemented in
  `tests/test_profile_settings.sh`.
- Event log contains selected profile and role.

## Phase 2: Policy Chokepoints

Status: partially implemented.

Goal: prevent high-risk behavior before side effects happen.

Implemented:

- Harness-owned `/hooks` directory is mounted read-only from `./hooks`.
- `pre_iteration`, `post_iteration`, `on_complete`, and `on_failure` hooks are
  supported.
- Hooks receive JSON on stdin and may return `{"decision":"allow|deny|defer",
  "reason":"..."}` on stdout. Empty stdout means allow.
- Allowed `pre_iteration` hooks may also return `additional_context`, which is
  bounded, audited, and prepended to the next prompt in a marked harness
  section.
- Allowed `pre_iteration` hooks may return `prompt_file`; AgentMill constrains
  it to the prompt root, verifies that it exists, emits an audit event, and
  switches the next Claude invocation to that file.
- Hook failures, malformed JSON, timeout, `deny`, and `defer` fail closed for
  commit/push side effects.
- `post_iteration` runs before auto-commit and push, so it can veto publishing
  unsafe changes.
- `on_complete` can reject a completion sentinel before convergence is accepted.
- Hook decisions are emitted as `hook.*`, `policy.allowed`,
  `policy.denied`, or `policy.deferred` events.
- Standard/untrusted runs deny commit/push when high-risk files changed unless
  `AGENTMILL_ALLOW_HIGH_RISK_CHANGES=true`.
- TUI auto-commit is profile-aware: trusted defaults to a WIP safety commit,
  while standard/untrusted default to no automatic `git add -A`.
- MCP config is snapshotted to `logs/mcp-manifest-<run>-<agent>.json` and a
  `mcp.manifest` event records the server count and manifest hash. Snapshots
  include redacted launch metadata so doctor/MCP CLI checks can validate
  allowlisted server presence and stdio command reachability.
- Generated Claude settings for non-trusted profiles deny high-risk Bash
  commands and common shell network clients; `network=deny` adds git and
  package-manager network command denies. Headless session logs are audited
  with parsed argv-token prefixes before auto-commit/push.
- Normalized tool-call streams are audited before auto-commit/push so observed
  web, MCP, and subagent calls still trip profile policy on clients that expose
  JSON telemetry but do not expose Claude-style PreToolUse hooks.
- Optional `AGENTMILL_WRITE_ROOTS` / profile `write_roots` enforce
  repo-relative durable output roots through Claude `PreToolUse`, Codex
  permission profiles, Bubblewrap filesystem sandboxes for OpenCode/Qwen/Gemini
  native and ACP transports, and standard/untrusted auto-commit/push gates.

Deliverables:

- Hook protocol: `pre_iteration`, `post_iteration`, `on_complete`,
  `on_failure`. Implemented.
- JSON decision contract: `allow`, `deny`, `defer`, reason, optional context,
  and optional `prompt_file`. Implemented.
- Bash command policy using parsed argv token prefixes. Implemented as
  generated settings, a Claude `PreToolUse` policy hook, Codex permission
  profiles and execpolicy rules, Bubblewrap write-root sandboxes, conservative
  native non-Claude settings, and headless post-session audit before
  auto-commit/push.
- MCP manifest snapshot: server name, tool names, description/schema hashes.
  Implemented for configured server names, config hashes, redacted launch
  reachability metadata, and best-effort live stdio MCP `tools/list`
  description/input-schema hashes; non-trusted manifest locking denies
  rug-pull drift across iterations.
- High-risk file policy for workflows, hooks, package scripts, auth config, and
  deploy scripts. Implemented as a standard/untrusted commit/push gate.

Acceptance evidence:

- Hook protocol tests. Implemented in `tests/test_hooks.sh`.
- High-risk file gate tests. Implemented in `tests/test_high_risk_policy.sh`.
- Git branch/protected-branch policy tests. Implemented in
  `tests/test_git_policy.sh`.
- MCP manifest snapshot tests. Implemented in `tests/test_mcp_manifest.sh`.
- Regression fixtures for denied commands and denied MCP changes. Command
  settings coverage is implemented in `tests/test_profile_settings.sh`.
- Event log records `policy.allowed` and `policy.denied`.

## Phase 3: Bounded Long Runs

Goal: make unattended loops resistant to runaway spend and completion drift.

Deliverables:

- `MAX_TOTAL_TOKENS`, `MAX_TOTAL_USD`.
- Claude JSON-output usage parser. Implemented for headless session logs.
- `logs/convergence.tsv` or convergence events with gate name, value,
  threshold, evidence, and pass/fail. Implemented for done-file, research,
  coder, and refactor gates.
- Per-mode completion gates for coder, researcher, and refactor. Implemented:
  coder/refactor require a done signal plus verifier evidence, research uses
  source saturation and open-question thresholds.
- Token/USD budget stopping once usage parsing is available. Implemented for
  parsed usage logs.

Acceptance evidence:

- Budget-gate tests for token, cost, wall clock, and max iterations.
- Research saturation and coder/refactor gate fixtures.
- Completion event includes verifier evidence.

## Phase 4: Isolation and Incident Response

Goal: make untrusted runs operationally safe.

Deliverables:

- Clone-mode single-agent runs. Implemented for `mill run` and `mill watch`
  through `headless-clone`/`watch-clone`.
- Read-only host repo mode for standard/untrusted. Implemented as
  `/workspace/upstream:ro` plus patch artifacts in `logs/patches/`.
- Host-side merge-back tooling. Implemented with `mill patches` and
  `mill apply <artifact> [repo] [--branch BR] [--check]`.
- Network modes: `deny`, `allowlist`, `allow`.
- Egress proxy integration point.
- Baseline `mill doctor` checks for Docker availability, image presence, auth,
  repo state, prompt resolution, hooks, `.env` schema, missing
  standard/untrusted budgets, broad MCP forwarding, high-risk overrides, and
  profile/model-version mismatches. It also checks local image freshness and
  latest MCP manifest allowlist/reachability state.
- Incident runbook and kill switch.

Acceptance evidence:

- `mill doctor` fixtures. Implemented in `tests/test_mill_doctor.sh`.
- Read-only clone artifact and policy tests. Implemented in
  `tests/test_readonly_clone_artifacts.sh` and
  `tests/test_workspace_isolation.sh`.
- Patch apply workflow test. Implemented in `tests/test_mill_apply_patches.sh`.
- Compose config tests for profile-specific mounts/env.
- Manual runbook test preserving logs and revoking credentials.

## Operating Rule

Each implementation slice should close one item in `TASK.md`, add or update
tests that prove the control, and emit enough events that a failed run can be
reconstructed without reading the model transcript.
