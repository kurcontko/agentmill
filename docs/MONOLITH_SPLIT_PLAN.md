# Monolith Split Plan

Date: 2026-05-31.

This plan describes how to split AgentMill's large shell monoliths without a
rewrite, while improving maintainability scores in SonarCloud, ShellCheck,
CodeQL, and human review. The goal is cleaner ownership boundaries, smaller
files, fewer duplicated policy rules, and safer future changes.

## Current Evidence

Current largest files:

| File | Lines | Primary issue |
| --- | ---: | --- |
| `entrypoint-common.sh` | 5041 | Runtime policy, client adapters, events, memory, budgets, completion gates, settings, and helpers share one global namespace. |
| `mill` | 3352 | CLI parsing, Docker Compose orchestration, reporting, doctor checks, patch apply, metrics, MCP, web output, and init logic are co-located. |
| `entrypoint.sh` | 485 | Main headless loop is readable enough, but it depends on many global functions from `entrypoint-common.sh`. |
| `entrypoint-tui.sh` | 395 | TUI flow is still manageable, but uses the same large shared runtime surface. |
| `docker-compose.yml` | 439 | Large env block and repeated per-agent config are manually maintained. |

Current scoring setup:

- `sonar-project.properties` scans shell, Python, YAML, and Dockerfile.
- CI runs ShellCheck, Hadolint, Python tests, shell tests, and Docker build.
- Security workflows include CodeQL, dependency review, Gitleaks, Trivy, Scorecard, and SonarCloud.

The repo already has strong behavioral tests. The main scoring and review
problem is concentrated complexity and duplicated policy/configuration.

## Goals

- Reduce each non-generated shell source file below 1000-1500 lines.
- Keep public commands and container entrypoints backward compatible.
- Keep every extraction behavior-preserving until the old module is empty.
- Preserve `set -euo pipefail` behavior and existing shell tests.
- Move schema-heavy or JSON-heavy transformations to Python where practical.
- Centralize policy and environment schema data so projections cannot drift.
- Improve Sonar maintainability by reducing file size, cognitive complexity,
  duplicated blocks, and long functions.
- Improve review quality by making every high-risk behavior inspectable in a
  small module with focused tests.

## Non-Goals

- Do not rewrite the harness into a new language in one step.
- Do not change runtime defaults while splitting files.
- Do not change the container image layout until module sourcing is stable.
- Do not collapse the shell test suite into broad smoke tests.
- Do not extract code only to satisfy line counts if ownership remains unclear.

## Design Principles

1. Extract by responsibility, not by arbitrary line ranges.
2. Keep the existing public function names during migration.
3. Put dependencies earlier than consumers and make source order explicit.
4. Prefer pure helpers in Python when the logic is structured data parsing,
   schema validation, policy projection, or JSON generation.
5. Add a focused test before or during each extraction.
6. Keep entrypoints thin: they should compose modules and run the loop.
7. Treat security policy as data first, implementation second.

## Target Layout

Recommended shell layout:

```text
lib/agentmill/
  sh/
    core/
      strict.sh              # shell options, common trap helpers if needed
      log.sh                 # log, log_error, log_warn, redaction
      json.sh                # json_escape, json_value, event_payload
      lock.sh                # _lock_acquire, _lock_release
      status.sh              # event_emit, event_emit_kv, status_write
      validate.sh            # truthy and numeric validators
    runtime/
      hooks.sh               # hook payload, hook execution, prompt updates
      high_risk.sh           # high-risk changed-file checks
      workspace.sh           # workspace isolation, write-root enforcement
      git_policy.sh          # branch, remote, merge, push policy helpers
      mcp_manifest.sh        # MCP snapshot and stability lock
      budgets.sh             # log, token, cost usage budgets
      usage.sh               # usage extraction and usage log append
      tool_events.sh         # tool-event extraction and tool policy audits
      models.sh              # model alias resolution and version floors
      clients.sh             # client_select and adapter dispatch
      clients/
        claude.sh
        codex.sh
        opencode.sh
        qwen.sh
        gemini.sh
        fake.sh
      client_home.sh          # client home setup and isolation
      settings.sh             # generated client settings writers
      watchers.sh             # done-file and wall-clock watchers
      memory.sh               # memory topics and task claims
      iteration_logs.sh        # results/convergence TSV helpers
      completion_gates.sh      # coder/research/refactor/done gates
      repo_setup.sh            # git identity and repo setup handoff
    cli/
      common.sh               # usage, load_env, repo/path validation
      compose.sh              # docker compose invocation and network override
      profiles.sh             # profile rendering wrappers
      commands/
        run.sh
        exec.sh
        watch.sh
        multi.sh
        shell.sh
        status.sh
        web.sh
        logs.sh
        stop.sh
        init.sh
        memory.sh
        report.sh
        patches.sh
        history.sh
        cost.sh
        events.sh
        metrics.sh
        mcp.sh
        version.sh
        doctor.sh
```

Recommended Python layout:

```text
agentmill/
  __main__.py
  cli.py                    # optional future Python dispatcher, not phase 1
  env_schema.py             # canonical env var schema
  policy.py                 # canonical policy manifest loader and projection helpers
  profile.py                # TOML profile parsing, replacing scripts/profile-env.py later
  jsonl.py                  # event/result parsing helpers
  doctor.py                 # structured doctor checks that are not shell-specific
```

Recommended generated data layout:

```text
policy/
  defaults.toml             # high-risk paths, shell denies, network denies, tool class policy
schema/
  env.toml                  # env vars, types, defaults, docs, per-agent suffix support
generated/
  docker-compose.env.yml    # optional future generated Compose env block
```

Keep `entrypoint-common.sh` and `mill` as compatibility loaders during the
migration. At the end, they should be short dispatch files, not deleted APIs.

## Dependency Order

Runtime loader source order should be explicit and tested:

1. `core/validate.sh`
2. `core/log.sh`
3. `core/json.sh`
4. `core/lock.sh`
5. `core/status.sh`
6. runtime policy modules that emit events
7. client and settings modules
8. memory, logs, completion gates

Important detail: `event_emit` uses `_lock_acquire`, so `lock.sh` must be
sourced before `status.sh`. The current monolith gets away with defining locks
later because functions are resolved at call time; splitting should not rely on
that implicit ordering.

## Migration Strategy

### Phase 0: Freeze Baseline And Add Guardrails

Objective: make sure every later PR can prove it only moved behavior.

Tasks:

- Add `scripts/monolith-metrics.py` or a small shell test that reports largest
  files and fails only after thresholds are enabled.
- Capture current function inventory for `entrypoint-common.sh` and `mill`.
- Add `tests/test_runtime_modules_source.sh` that sources the future runtime
  loader and asserts key functions exist.
- Add `tests/test_cli_modules_source.sh` that sources the future CLI loader and
  asserts key command functions exist.
- Keep thresholds advisory in this phase.

Proof:

```bash
bash -n mill entrypoint-common.sh entrypoint.sh entrypoint-tui.sh
python3 -m py_compile agentmill/*.py scripts/*.py tests/test_*.py
python3 -m unittest discover -s tests -p 'test_*.py'
for test_script in tests/test_*.sh; do
  [[ "$test_script" == "tests/test_smoke_integration.sh" ]] && continue
  bash "$test_script"
done
```

Expected scoring effect: no immediate score jump, but this prevents regression
while the split starts.

### Phase 1: Introduce Loaders With No Behavior Change

Objective: create the module loading mechanism before moving real behavior.

Tasks:

- Add `lib/agentmill/sh/runtime.sh` that sources runtime modules.
- Add `lib/agentmill/sh/cli.sh` that sources CLI modules.
- Add empty or tiny initial modules only where tests can prove source order.
- Make loaders resolve both container paths and local repository paths.
- Keep `entrypoint-common.sh` and `mill` function bodies in place in this
  phase.
- Do not wire the entrypoints to depend on the new loaders yet, except in
  source-only tests.

Proof:

- Existing tests pass.
- New loader source tests pass.
- Dockerfile can copy `lib/agentmill` into the image without changing runtime
  behavior.

Expected scoring effect: small, but review risk drops because later diffs are
pure moves.

The final compatibility loader shape should only appear after the extracted
modules contain all runtime behavior:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
AGENTMILL_LIB_DIR="${AGENTMILL_LIB_DIR:-/lib/agentmill/sh}"
. "$AGENTMILL_LIB_DIR/runtime.sh"
```

### Phase 2: Extract Core Runtime Utilities

Objective: move low-risk pure helpers first.

Move from `entrypoint-common.sh`:

- `agentmill_truthy`, numeric validators -> `core/validate.sh`
- `redact_text`, `redacted_tee`, `log`, `log_error`, `log_warn` -> `core/log.sh`
- `json_escape`, `json_value`, `event_payload` -> `core/json.sh`
- `_lock_acquire`, `_lock_release` -> `core/lock.sh`
- `event_emit`, `event_emit_kv`, `status_write`, `emit_iteration_failed` -> `core/status.sh`

Rules:

- Preserve function names exactly.
- Do not change call sites.
- During extraction, source modules from `entrypoint-common.sh` after default
  environment initialization and before any moved function can be called.
- Add a direct test for redaction, JSON payload generation, and lock/event
  append behavior if existing coverage is indirect.

Proof:

- `tests/test_events_jsonl.sh`
- `tests/test_log_redaction.sh`
- `tests/test_iteration_failed_events.sh`
- `tests/test_mill_session_logs.sh`
- full fast suite.

Expected scoring effect: lower `entrypoint-common.sh` size by roughly 200-250
lines and reduce cognitive complexity in the top file.

### Phase 3: Extract Hooks And High-Risk Policy

Objective: isolate user-extensible policy execution and high-risk file gates.

Move:

- hook parsing and prompt updates -> `runtime/hooks.sh`
- high-risk changed-file detection and enforcement -> `runtime/high_risk.sh`

Add:

- `tests/test_hooks_module.sh` if existing `tests/test_hooks.sh` does not
  source the new module directly.
- A test proving invalid hook JSON, hook timeout, prompt file path validation,
  and high-risk path denial still produce the same event reasons.

Proof:

- `tests/test_hooks.sh`
- `tests/test_high_risk_policy.sh`
- `tests/test_pretool_policy.sh`
- full fast suite.

Expected scoring effect: separates operator-controlled hook execution from
client adapters, making security review easier.

### Phase 4: Extract Workspace, Git, And Network Policy

Objective: make write boundaries and git egress policy locally auditable.

Move:

- workspace isolation -> `runtime/workspace.sh`
- write-root sandbox helpers -> `runtime/workspace.sh`
- read-only clone artifact export -> `runtime/workspace.sh`
- branch, remote, force-push, merge policy -> `runtime/git_policy.sh`
- compose network override from `mill` -> `cli/compose.sh`

Add:

- One policy manifest compatibility test that compares event reasons before and
  after extraction.
- One container-level fake-client integration lane later, but keep phase 4
  limited to shell behavior.

Proof:

- `tests/test_workspace_isolation.sh`
- `tests/test_filesystem_policy.sh`
- `tests/test_readonly_clone_artifacts.sh`
- `tests/test_git_policy.sh`
- `tests/test_mill_network_policy.sh`
- full fast suite.

Expected scoring effect: major human maintainability gain because branch,
remote, filesystem, and egress checks become reviewable without scanning client
adapter code.

### Phase 5: Extract Budgets, Usage, Tool Events, And Completion Gates

Objective: separate observability and stopping logic from client execution.

Move:

- usage extraction and cost estimation -> `runtime/usage.sh`
- log/token/cost budget enforcement -> `runtime/budgets.sh`
- tool-event extraction and shell/tool class policy audits -> `runtime/tool_events.sh`
- results/convergence TSV helpers -> `runtime/iteration_logs.sh`
- open-question counting and completion gates -> `runtime/completion_gates.sh`

Rules:

- Keep JSON and stream parsing in shell only if the existing code is simple.
- Move complex parsing to `agentmill/jsonl.py` if it requires nested JSON,
  schema normalization, or multi-provider branches.

Proof:

- `tests/test_usage_budget.sh`
- `tests/test_log_budget.sh`
- `tests/test_tool_events.sh`
- `tests/test_shell_policy.sh`
- `tests/test_tool_class_policy.sh`
- `tests/test_completion_gates.sh`
- `tests/test_research_completion_gate.sh`
- `tests/test_ralph_completion_gate.sh`
- `tests/test_convergence_log.sh`
- full fast suite.

Expected scoring effect: high. This removes a dense block of parsing and
policy code from `entrypoint-common.sh`.

### Phase 6: Extract Client Adapters

Objective: make each client adapter independently reviewable and testable.

Move:

- client selection/version/auth dispatch -> `runtime/clients.sh`
- Claude adapter -> `runtime/clients/claude.sh`
- Codex adapter -> `runtime/clients/codex.sh`
- OpenCode adapter -> `runtime/clients/opencode.sh`
- Qwen adapter -> `runtime/clients/qwen.sh`
- Gemini adapter -> `runtime/clients/gemini.sh`
- fake adapter -> `runtime/clients/fake.sh`
- client home isolation -> `runtime/client_home.sh`
- settings generation -> `runtime/settings.sh`
- watchers -> `runtime/watchers.sh`
- model alias resolution -> `runtime/models.sh`

Rules:

- Keep shared adapter helpers in `clients.sh`, not duplicated per client.
- Put provider-specific flags in provider files.
- Do not mix auth checks, home setup, settings generation, and run invocation
  in one file once extracted.
- Preserve current environment variable names.

Proof:

- `tests/test_client_selector.sh`
- `tests/test_codex_adapter.sh`
- `tests/test_opencode_adapter.sh`
- `tests/test_qwen_gemini_adapter.sh`
- `tests/test_client_home_isolation.sh`
- `tests/test_host_config_forwarding.sh`
- `tests/test_profile_settings.sh`
- `tests/test_resolve_model.sh`
- full fast suite.

Expected scoring effect: very high. Client adapter complexity becomes spread
across small files with obvious ownership.

### Phase 7: Extract Memory And Repo Loop Support

Objective: leave `entrypoint-common.sh` with no persistent-state primitives.

Move:

- memory topics, schema, claims -> `runtime/memory.sh`
- iteration context -> `runtime/memory.sh`
- git identity and repo setup handoff -> `runtime/repo_setup.sh`
- push retry helper from `entrypoint.sh` -> `runtime/git_push.sh` if it is used
  by more than the headless entrypoint; otherwise leave it local.

Proof:

- `tests/test_memory_schema.sh`
- `tests/test_memory_concurrent.sh`
- `tests/test_memory_role_filter.sh`
- `tests/test_mill_memory_cli.sh`
- `tests/test_entrypoint_push_retry.sh`
- full fast suite.

Expected scoring effect: moderate score gain and strong ownership clarity.

### Phase 8: Split The `mill` CLI

Objective: make each user-facing command small and self-contained.

Move from `mill`:

- usage/load env/repo validation -> `cli/common.sh`
- Docker Compose helpers -> `cli/compose.sh`
- profile rendering -> `cli/profiles.sh`
- each `cmd_*` implementation -> `cli/commands/<name>.sh`
- doctor helpers and `cmd_doctor` -> `cli/commands/doctor.sh`

Keep `mill` as a dispatcher:

```bash
#!/usr/bin/env bash
set -euo pipefail
MILL_DIR=...
AGENTMILL_LIB_DIR="${AGENTMILL_LIB_DIR:-$MILL_DIR/lib/agentmill/sh}"
. "$AGENTMILL_LIB_DIR/cli.sh"
load_env
dispatch "$@"
```

Command extraction order:

1. Low-risk display commands: `version`, `events`, `history`, `cost`, `metrics`.
2. File/artifact commands: `patches`, `apply`, `memory`, `report`.
3. Compose commands: `ps`, `build`, `logs`, `tail`, `web`, `stop`.
4. Run commands: `run`, `exec`, `watch`, `multi`, `shell`.
5. Initialization and doctor: `init`, `mcp`, `doctor`.

Rules:

- Do not extract all commands in one PR.
- Each command module should own only its argument parsing and command action.
- Shared validators stay in `cli/common.sh`.
- Command modules should not source runtime modules unless truly needed.

Proof:

- Existing command-specific tests.
- Add `tests/test_mill_dispatch.sh` with `mill help`, unknown command, and one
  extracted command smoke.
- Full fast suite after every command group.

Expected scoring effect: very high. `mill` drops from 3352 lines to a small
dispatcher, and command-specific cognitive complexity becomes localized.

### Phase 9: Centralize Policy Data

Objective: stop duplicating security policy constants.

Create `policy/defaults.toml`:

```toml
[paths]
high_risk = [
  { category = "ci-workflow", pattern = "^\\.github/workflows/" },
  { category = "mcp-config", pattern = "(^|/)\\.mcp\\.json$" },
]

[shell]
high_risk_deny = ["sudo:*", "su:*", "rm -rf:*", "chmod:*", "chown:*"]
network_deny = ["curl:*", "wget:*", "nc:*", "scp:*", "rsync:*"]
strict_network_deny = ["git clone:*", "git fetch:*", "git pull:*", "git push:*"]
```

Create `agentmill/policy.py`:

- load the manifest with `tomllib`;
- validate pattern shape;
- emit shell-compatible exports when needed;
- emit JSON policy IR for tests and client settings;
- support semantic comparisons between projections.

Then update:

- `scripts/pretool-policy.py`
- `entrypoint-common.sh` policy projection functions
- session shell/tool audits
- doctor policy checks
- docs/tests that list policy constants

Proof:

- Add `tests/test_policy_manifest.py`.
- Add a shell test that fails if a hard-coded deny list appears outside the
  manifest, allowlist exceptions, and generated fixtures.
- Existing security policy tests pass.

Expected scoring effect: reduces duplication and raises security review
confidence. This is one of the highest-value principal-level changes.

### Phase 10: Centralize Environment Schema

Objective: stop hand-maintaining env vars in Compose, `.env.example`, doctor,
docs, and profile rendering.

Create `schema/env.toml`:

```toml
[[vars]]
name = "AGENTMILL_CLIENT"
type = "enum"
default = "claude"
values = ["claude", "codex", "opencode", "qwen", "gemini"]
per_agent = true
description = "Client executable selected by AgentMill."
```

Create `agentmill/env_schema.py`:

- validate schema;
- render `.env.example` sections;
- render Compose env blocks or a generated include file;
- render doctor known-key checks;
- render README tables if desired.

Migration path:

1. Add schema and validation only.
2. Add drift test that compares schema keys to `.env.example`.
3. Generate `.env.example`.
4. Generate Compose env block or add a generated Compose fragment.
5. Use schema in doctor.

Proof:

- `tests/test_env_schema.py`.
- A drift test fails when a var exists in Compose but not schema, or schema but
  not docs.
- Existing doctor/profile tests pass.

Expected scoring effect: reduces duplication, prevents stale docs, and improves
review reliability.

## Code Scoring Targets

Use these as practical quality gates after the split begins:

| Metric | Target |
| --- | --- |
| Largest non-generated shell file | <= 1500 lines initially, <= 1000 lines later |
| `entrypoint-common.sh` | <= 150 lines loader by the end |
| `mill` | <= 250 lines dispatcher by the end |
| Runtime modules | one responsibility per file, usually <= 600 lines |
| CLI command modules | usually <= 250 lines |
| Duplicated policy constants | zero outside `policy/defaults.toml` and tests |
| Duplicated env var schema | zero outside `schema/env.toml` and generated files |
| ShellCheck | no new warnings |
| Sonar maintainability | no new major/critical maintainability issues |
| CodeQL | no new alerts |
| Tests | full fast suite green after every extraction PR |

## Review And PR Slicing

Suggested PR sequence:

1. Add module loaders and source tests.
2. Extract core runtime utilities.
3. Extract hooks and high-risk policy.
4. Extract workspace/git/network policy.
5. Extract usage, budgets, tool events, and completion gates.
6. Extract client adapters.
7. Extract memory and repo loop support.
8. Split low-risk `mill` commands.
9. Split run/watch/multi `mill` commands.
10. Split doctor/MCP/init commands.
11. Add canonical policy manifest.
12. Add canonical env schema and drift tests.
13. Enable line-count and duplication thresholds in CI.

Each PR should include:

- exact files moved;
- behavior changes, ideally "none";
- focused tests run;
- full fast suite result;
- current largest-file metric.

## Risk Controls

- Keep compatibility loaders until at least two releases after the split.
- Do not rename exported functions until all tests source modules directly.
- Use shell arrays for source lists so ShellCheck can still reason about paths.
- Avoid dynamic `eval` in loaders.
- When moving functions, move tests with them or add direct source tests.
- Do not move `entrypoint.sh` loop logic until runtime modules are stable.
- Do not convert `mill` to Python until shell modules are already small; a
  language migration and decomposition in the same PR would hide regressions.

## Done Criteria

The monolith split is complete when:

- `entrypoint-common.sh` is a compatibility loader only.
- `mill` is a compatibility dispatcher only.
- no runtime source module exceeds 1500 lines.
- no CLI command module exceeds 500 lines without a documented exception.
- policy constants live in one manifest.
- env schema lives in one manifest.
- `.env.example`, Compose env, doctor, and docs are covered by drift tests.
- all existing tests pass.
- an integration lane proves the image still runs a fake-client headless
  iteration in direct and read-only clone mode.
- SonarCloud no longer flags the original monoliths as top maintainability
  risks.
