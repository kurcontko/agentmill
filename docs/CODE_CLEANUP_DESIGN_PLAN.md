# Code Cleanup Design Plan

Date: 2026-06-01.

This plan describes how to simplify AgentMill's codebase without changing the
public CLI, container entrypoints, safety defaults, or existing workflow
contracts. It complements `docs/MONOLITH_SPLIT_PLAN.md`: that document gives
the detailed extraction order for the two largest shell files; this one covers
the broader cleanup program around source layout, schema ownership, generated
artifacts, tests, and review gates.

## Current Evidence

The current tree is functional and well covered by tests, but the
maintainability risks are concentrated in a few repeating patterns.

| Area | Evidence | Cleanup pressure |
| --- | --- | --- |
| Runtime shell monolith | `entrypoint-common.sh` is 5054 lines with about 145 shell functions. | Runtime policy, client adapters, event parsing, memory, settings, and completion logic share one global namespace. |
| CLI monolith | `mill` is 3382 lines with 29 `cmd_*` commands and about 79 shell functions. | User-facing argument parsing, Docker Compose orchestration, reporting, doctor checks, web output, metrics, and patch handling are coupled. |
| Embedded Python | `mill` has 24 inline Python blocks; `entrypoint-common.sh` has 37. | Structured parsing is hard to test directly, and shell files carry logic that belongs in Python stdlib modules. |
| Config schema drift | `.env.example`, `docker-compose.yml`, `mill doctor`, profile rendering, README tables, and docs each know about many of the same env vars. | Adding or renaming env vars is error-prone because there is no canonical schema. |
| Policy duplication | Security policy appears in `scripts/pretool-policy.py`, `entrypoint-common.sh`, generated client settings, session audits, doctor checks, and docs. | A rule can be enforced in one projection and missed in another. |
| Compose repetition | `docker-compose.yml` is 440 lines, mostly common env, per-agent env variants, mounts, and service repetition. | Manual changes are easy to miss across `headless`, `watch`, clone variants, and agent services. |
| Repo hygiene | `agentmill/__pycache__`, `scripts/__pycache__`, and `tests/__pycache__` are present but `.gitignore` does not ignore `__pycache__/` or `*.pyc`. | Generated local artifacts add noise to status and reviews. |
| Documentation sprawl | `TASK.md` and several design docs overlap with implementation plans. | Useful context exists, but it is hard to tell which plan controls cleanup sequencing. |

## Goals

- Make the codebase easier to review by giving every high-risk behavior a
  small owner module and direct tests.
- Reduce the largest hand-written shell files to thin loaders or dispatchers.
- Move structured parsing, schema validation, and projection logic into
  importable Python stdlib modules.
- Centralize policy constants and environment variable schema data.
- Keep all user-facing commands, env vars, container services, and log formats
  backward compatible during the cleanup.
- Add drift tests and size checks so the code does not slowly return to the
  current shape.
- Make generated and local-cache files invisible to normal development status.

## Non-Goals

- Do not rewrite AgentMill into a Python application in one step.
- Do not change trusted, standard, or untrusted runtime defaults as part of
  cleanup-only PRs.
- Do not rename public env vars, commands, services, or log/event fields unless
  a compatibility alias and migration note are included.
- Do not replace focused shell tests with broad smoke tests.
- Do not extract code by arbitrary line count when ownership would remain
  unclear.

## Target Architecture

The end state should keep Bash as the process orchestration layer, but remove
data-heavy and policy-heavy logic from shell.

```text
agentmill/
  __init__.py
  __main__.py
  env_schema.py          # canonical env var schema validation and projections
  jsonl.py               # event, result, usage, and session parsing helpers
  policy.py              # canonical security policy loader and projections
  profiles.py            # TOML profile parsing, replacing scripts/profile-env.py
  doctor.py              # structured doctor checks that are not shell-specific

lib/agentmill/sh/
  runtime.sh             # sources runtime modules in explicit order
  cli.sh                 # sources CLI modules and dispatches commands
  core/
    validate.sh
    log.sh
    json.sh
    lock.sh
    status.sh
  runtime/
    hooks.sh
    workspace.sh
    git_policy.sh
    budgets.sh
    usage.sh
    tool_events.sh
    models.sh
    clients.sh
    clients/
      claude.sh
      codex.sh
      opencode.sh
      qwen.sh
      gemini.sh
      fake.sh
    settings.sh
    memory.sh
    completion_gates.sh
  cli/
    common.sh
    compose.sh
    profiles.sh
    commands/
      run.sh
      exec.sh
      watch.sh
      multi.sh
      doctor.sh
      status.sh
      history.sh
      cost.sh
      metrics.sh
      mcp.sh

policy/
  defaults.toml          # high-risk paths, shell rules, network rules, MCP defaults

schema/
  env.toml               # env var names, types, defaults, docs, per-agent support

generated/
  docker-compose.env.yml # optional generated env projection
```

`entrypoint-common.sh` and `mill` should remain as compatibility files. At the
end, `entrypoint-common.sh` should source `lib/agentmill/sh/runtime.sh`, and
`mill` should source `lib/agentmill/sh/cli.sh` and dispatch.

## Workstreams

### 1. Hygiene And Baseline Guardrails

Start with changes that reduce review noise and make progress measurable.

- Add `__pycache__/`, `*.py[cod]`, and `.pytest_cache/` to `.gitignore`.
- Remove committed or untracked local bytecode artifacts from the working tree
  in a cleanup PR.
- Add a small metrics script that reports largest files, function counts, and
  inline Python block counts.
- Keep size thresholds advisory at first; turn them into CI limits only after
  the split begins.
- Add source-load tests for the future runtime and CLI loaders before moving
  behavior.

Proof:

```bash
bash -n mill entrypoint-common.sh entrypoint.sh entrypoint-tui.sh
python3 -m py_compile agentmill/*.py scripts/*.py tests/test_*.py
python3 -m unittest discover -s tests -p 'test_*.py'
```

### 2. Shell Module Extraction

Follow `docs/MONOLITH_SPLIT_PLAN.md` for detailed ordering. The important
repo-wide rule is that extraction PRs should be behavior-preserving moves with
small tests around each new module boundary.

Recommended extraction sequence:

1. Core runtime utilities: validation, logging, JSON, locks, status/events.
2. Hooks and high-risk file policy.
3. Workspace, write-root, git, and network policy.
4. Usage, budgets, tool events, and completion gates.
5. Client adapters and generated settings.
6. Memory and repo loop support.
7. CLI commands, starting with low-risk display/reporting commands.

Each module should keep existing public function names until callers and tests
are migrated.

### 3. Pythonize Structured Data Logic

Inline Python blocks are useful during prototyping, but they should not remain
embedded in long shell files once their contracts are stable.

Move these categories first:

- JSONL event streaming and filtering from `mill`.
- `results.tsv`, `usage.tsv`, and report parsing.
- MCP manifest parsing and reachability checks.
- Model/version floor comparison.
- Client policy IR generation and client setting projections.
- Memory frontmatter and open-question counting.

Use importable functions with CLI wrappers where shell still needs subprocess
calls. That gives shell scripts stable text interfaces while Python tests cover
edge cases directly.

### 4. Canonical Policy Manifest

Create `policy/defaults.toml` and make every projection consume it.

The manifest should own:

- high-risk path categories;
- default high-risk shell deny patterns;
- network-sensitive shell deny patterns;
- strict untrusted shell defaults;
- MCP default behavior;
- client projection exceptions that are intentional and documented.

`agentmill/policy.py` should validate the manifest and emit projections for:

- Claude PreToolUse policy;
- Codex permission profiles and execpolicy rules;
- OpenCode, Qwen, and Gemini settings;
- session-log shell audits;
- tool-class audits;
- `mill doctor`;
- docs or generated reference output.

Add a drift test that fails when a policy constant appears in one projection
but not in the manifest or documented exceptions.

### 5. Canonical Environment Schema

Create `schema/env.toml` and `agentmill/env_schema.py` so env var ownership is
data-first.

The schema should capture:

- name;
- type;
- default;
- allowed enum values;
- whether the var supports `_1`, `_2`, `_3` per-agent suffixes;
- whether it is secret, path-like, command-like, or network-related;
- short docs text for `.env.example` and README generation.

Migration path:

1. Add schema and validation without generating files.
2. Add drift tests comparing schema keys to `.env.example`, Compose env, and
   doctor known-key lists.
3. Generate `.env.example` from the schema.
4. Generate Compose env blocks or a Compose include file.
5. Replace doctor's hard-coded key list with schema validation.

### 6. CLI Simplification

Split `mill` by command ownership and keep shared parsing helpers small.

Rules:

- Command modules own only argument parsing and command action.
- Shared validators live in `cli/common.sh`.
- Docker Compose behavior lives in `cli/compose.sh`.
- Reporting commands use `agentmill/jsonl.py` or small Python CLIs instead of
  embedded Python heredocs.
- Run/watch/multi extraction should happen after lower-risk commands prove the
  dispatcher pattern.

Initial command groups:

1. `version`, `events`, `history`, `cost`, `metrics`.
2. `patches`, `apply`, `memory`, `report`.
3. `ps`, `build`, `logs`, `tail`, `web`, `stop`.
4. `run`, `exec`, `watch`, `multi`, `shell`.
5. `init`, `mcp`, `doctor`.

### 7. Docker Compose And Generated Config

After env schema drift tests exist, reduce `docker-compose.yml` repetition.

Options, in order of risk:

- keep current YAML anchors but generate the large common env mapping;
- generate only per-agent env suffix blocks;
- generate a full Compose include file for env and service variants;
- leave service topology hand-written until CI proves generated output is
  stable.

Generated files should have a clear header and a verifier command that fails if
regeneration changes tracked output.

### 8. Test And CI Cleanup

The shell test suite is valuable and should stay focused. Cleanup should make
it easier to know which tests prove which module.

- Add direct module source tests when each shell module appears.
- Add Python unit tests for `agentmill/policy.py`, `agentmill/env_schema.py`,
  `agentmill/jsonl.py`, and `agentmill/profiles.py`.
- Add drift tests for env schema, policy manifest, generated Compose env, and
  docs snippets.
- Keep slower Docker smoke tests separate from fast source and unit tests.
- Add an optional CI summary showing largest files and threshold status.

## Phased Rollout

### Phase 0: Baseline

- Add or update the cleanup design docs.
- Capture current metrics in CI output without failing.
- Add source-load tests for future module loaders.
- Add `.gitignore` entries for Python cache artifacts.

### Phase 1: Low-Risk Extraction

- Add runtime and CLI loader skeletons.
- Extract core utilities from `entrypoint-common.sh`.
- Extract low-risk display/reporting commands from `mill`.
- Keep public function names and call sites stable.

### Phase 2: Structured Data Modules

- Introduce `agentmill/jsonl.py`, `agentmill/policy.py`, and
  `agentmill/env_schema.py`.
- Move parsing and projection logic out of heredocs in small groups.
- Add direct Python unit tests for each migrated function.

### Phase 3: Policy And Env Canonicalization

- Land `policy/defaults.toml` with projection drift tests.
- Land `schema/env.toml` with env drift tests.
- Start generating `.env.example` and Compose env blocks only after drift tests
  are green.

### Phase 4: Runtime And CLI Decomposition

- Complete the module extraction sequence from `docs/MONOLITH_SPLIT_PLAN.md`.
- Keep `entrypoint-common.sh` and `mill` as compatibility loaders.
- Add CI thresholds once the old monoliths have dropped below agreed limits.

### Phase 5: Generated Config And Docs Pruning

- Replace hand-maintained env and policy tables with generated snippets where
  useful.
- Move historical implementation notes out of `TASK.md` when they are covered
  by durable docs.
- Keep README operator-focused and point detailed architecture material to
  docs.

## Acceptance Criteria

The cleanup program is complete when:

- `entrypoint-common.sh` is a compatibility runtime loader.
- `mill` is a compatibility CLI dispatcher.
- No hand-written runtime shell module exceeds 1500 lines, with a preferred
  long-term target of 1000 lines.
- No CLI command module exceeds 500 lines without a documented exception.
- Inline Python blocks in shell are limited to tiny wrappers around importable
  Python modules.
- Policy constants live in `policy/defaults.toml` or a documented test-only
  fixture.
- Env var definitions live in `schema/env.toml`, and drift tests cover
  `.env.example`, Compose env, doctor validation, and docs projections.
- Python cache and test cache artifacts do not appear in normal `git status`.
- Fast source, shell, and Python tests pass.
- A Docker fake-client smoke lane proves direct and read-only clone modes still
  run.
- SonarCloud and human review no longer identify `entrypoint-common.sh` and
  `mill` as the dominant maintainability risks.

## First PR Recommendation

Make the first cleanup PR deliberately small:

- add `.gitignore` entries for Python and pytest cache artifacts;
- add a metrics script for largest files, shell function counts, and inline
  Python block counts;
- add skeleton runtime and CLI loaders with source-only tests;
- do not move behavior yet.

That PR creates a safe measuring stick. Subsequent PRs can then move code by
responsibility and prove that behavior stayed the same.
