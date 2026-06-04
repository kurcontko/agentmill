# AgentMill Task List

Consolidated from `README.md`, `CLAUDE.md`, `docs/RESEARCHER_AGENT.md`,
`prompts/*`, `docker-compose.yml`, `mill`, and recent commit history. Items
are grouped by recurring patterns. Status reflects current tree state.

## Legend

- `[ ]` not started
- `[~]` partial (some scaffolding exists; not finished or not generalized)
- `[x]` implemented

---

## 1. Run modes (CLI is one client of the loop)

Cross-ref: `mill` subcommands, `docker-compose.yml` services
(`headless`/`watch`/`interactive`/`agent-1..3`).

- [x] Four core surfaces: `headless`, `watch`, `interactive`, `agent-N`.
- [x] `mill` CLI wrapper (run/watch/multi/shell/status/history/memory/diff).
- [x] **`mill run --json`** — emit JSONL events to stdout (`iteration.started`,
  `tool.*`, `commit`, `push`, `iteration.completed/failed`); progress to
  stderr; final status to stdout. Lets CI consume agent output without
  scraping logs. Implemented as event-log streaming with a final
  `mill.run.completed` JSONL event and parsed `tool.*`/`mcp.tool.*` events
  when JSON session logs contain tool calls. Explicit `iteration.failed`
  events are emitted for policy blocks, nonzero Claude exits, and push
  failures.
- [x] **`mill status --json`** and **`mill history --json`** for scripts.
- [x] **`mill exec`** — one-shot iteration (no loop, no respawn) for CI hooks.
- [x] **Python `mill` module** so `python -m agentmill` and `from agentmill
  import Mill` work. The module delegates to the bash CLI and keeps zero
  third-party deps per CLAUDE.md.

## 2. Agent profiles (formalize roles)

Cross-ref: `prompts/PROMPT_RESEARCH_*`, `PROMPT_LITE.md`, `PROMPT_MEMORY.md`,
`REFACTOR_ELITE.md`, multi-agent `PROMPT_FILE_1/2/3`.

Today every "role" is just a different prompt file path. Roles already exist
implicitly: coder (`PROMPT.md`), researcher (breadth/depth/redteam), refactor
(`REFACTOR_ELITE.md`), memory-curator (`PROMPT_MEMORY.md`).

- [x] **`agents/<role>.toml`** profile definitions — fields: `prompt_file`,
  `model`, `branch_pattern`, `max_iterations`, `loop_delay`,
  `completion_gate`, `research_saturation_iterations`,
  `research_open_questions_max`, `verifier_command`,
  `coder_open_questions_max`, `refactor_loc_target`,
  `refactor_loc_tolerance`, `refactor_max_loc_delta`, `mcp_allowlist`, `skill_allowlist`,
  `auto_commit_mode`, `ralph_max_iterations`, `profile_level`,
  `max_wall_seconds`, `network`, and `forward_host_mcp`.
- [x] **Built-in profiles**: `coder`, `researcher-breadth`,
  `researcher-depth`, `researcher-redteam`, `refactor`, `memory-curator`,
  `reviewer`.
- [x] **`mill run <repo> --agent researcher-depth`** resolves a profile,
  applies env vars, and selects the prompt.
- [x] **`mill multi <repo> --roles coder,reviewer,redteam`** maps positional
  agents to roles instead of `PROMPT_FILE_N` env vars.
- [x] **Per-role branch policy** — `branch_pattern` is applied to
  `AGENT_BRANCH`, including researchers on `main` and coders on `agent-$ID`.
  Startup now rejects an unexpected checked-out branch and standard/untrusted
  direct writes to protected branches. Push/rebase policy now validates refs,
  current branch, protected branches, default force-push denial, and
  non-trusted merge-commit mediation.

## 3. Convergence + completion gates

Cross-ref: `AUTO_RALPH_COMPLETION_PROMISE=TASK_COMPLETE`, commit `740deff`
"numeric completion gate", `prompts/PROMPT.md` §"Loop", `docs/RESEARCHER_AGENT.md`
§"saturation".

- [x] Sentinel-string completion (`TASK_COMPLETE`).
- [x] Numeric completion gate (per commit `740deff`).
- [x] **Per-mode default gates** — research saturates on
  "no-new-sources-for-N-iterations"; coder on "tests pass and
  open_questions empty"; refactor on "LOC delta within target ± tolerance".
  Research profiles now default to `research_saturation`, which requires a
  configurable zero-source streak and unresolved open questions at or below the
  configured threshold. Coder profiles now default to `coder_verified`, which
  requires a done signal, `AGENTMILL_VERIFIER_COMMAND` success, and open
  questions at or below threshold. Refactor profiles now default to
  `refactor_verified`, which requires a done signal, verifier success, and
  configured LOC-delta thresholds.
- [x] **Cost / token gate** — stop when cumulative spend or token count
  exceeds budget. `MAX_TOTAL_TOKENS` and `MAX_TOTAL_USD` consume parsed
  JSON usage telemetry, fail closed when a configured budget has no telemetry,
  and support explicit per-million-token cost estimator rates when a client
  emits tokens but not `cost_usd`. Budgeted Claude headless runs auto-enable
  `stream-json` telemetry.
- [x] **Time gate** — stop after wall-clock deadline. `MAX_WALL_SECONDS`
  stops headless and respawn loops, is required for unbounded
  standard/untrusted runs, and now also terminates in-flight client processes
  when the run-level wall-clock budget expires.
- [x] **Log-size gate** — `MAX_LOG_BYTES` stops loops when logs exceed the
  configured byte budget and emits a `budget.exhausted` event.
- [x] **`mill stop --on-converge`** flag for headless runs.
- [x] **`logs/convergence.tsv`** records per-iteration gate evaluation so
  failures to converge are auditable.
- [x] **Weak-model termination oracle** — implemented as a command contract.
  After each iteration, AgentMill builds a deterministic artifact bundle, runs
  `AGENTMILL_TERMINATION_ORACLE_COMMAND`, validates strict verdict JSON, logs
  `termination.oracle.*` events and `termination_oracle` convergence rows,
  injects bounded next-iteration context, and in `required` mode allows
  completion only when deterministic typed gates also prove completion.

## 4. Iteration log + structured events

Cross-ref: `logs/results.tsv`, CLAUDE.md §"Iteration Log", commit `de577af`
"greppable error logs".

- [x] `logs/results.tsv` (agent, files changed, commits, status).
- [x] Greppable error logs + `failed_approaches`.
- [x] **`logs/events.jsonl`** — structured per-iteration events. Schema:
  `{version: 1, iteration, agent_id, timestamp, type, ...}`. Types:
  `iteration.started`, `commit`, `push.attempted`, `push.rebased`,
  `push.failed`, `iteration.completed`, and `convergence.evaluated` are
  implemented. Parsed JSON session logs now also emit `tool.invoked`,
  `tool.completed`, `mcp.tool.invoked`, `mcp.tool.completed`,
  `tool.summary`, and `usage.recorded` across Claude JSON, Codex, OpenCode,
  Qwen, Gemini, fake-client, and ACP logs.
- [x] **Redacted session logs** — headless `logs/session_*` output and
  `agent-*.log` messages now pass through the same redaction policy as events.
  Regression coverage includes model/API tokens, GitHub tokens, bearer tokens,
  generic `sk-...` keys, and env assignment leaks.
- [x] **Token + cost capture** per iteration. Claude Code emits these in
  `--output-format=json`; headless runs can request JSON output and parse
  usage into `usage.recorded`, `logs/usage.tsv`, and `results.tsv` usage
  columns. Budgeted Claude runs auto-enable `stream-json`, non-Claude JSON
  adapters feed the same parser, and optional cost-estimator rates fill in USD
  when a client emits tokens but not `cost_usd`.
- [x] **`mill history --since TS`**, `--agent N`, `--failed-only` filters.
- [x] **`mill tail --json`** stream of events as they happen.

## 5. Hooks (pre/post iteration, on-completion)

Cross-ref: `entrypoint-common.sh` (no hooks today). Inspired by Claude Code
hook model.

- [x] **`hooks/pre_iteration.sh`** — runs before each Claude invocation.
  Abort/allow decisions, bounded `additional_context` injection, and
  constrained `prompt_file` switching are implemented.
- [x] **`hooks/post_iteration.sh`** — receives iteration JSON on stdin; can
  veto commit/push, append to memory, post status.
- [x] **`hooks/on_complete.sh`** — fires when convergence gate hits.
- [x] **`hooks/on_failure.sh`** — fires on push failure after retry limit
  (`PUSH_REBASE_MAX_RETRIES` exhausted).
- [x] **JSON stdin/stdout** decision protocol — `{decision: "allow|deny|
  defer", reason, additional_context}`. Decisions and reasons are
  implemented; `additional_context` injection is bounded and audited.
- [x] **Per-role hook scoping** so researcher hooks don't run for coder.
  Hooks may be global, `profiles/<profile>/`, or `roles/<role>/`; matching
  hooks run global → profile → role and fail closed on the first non-allow.
- [x] **Timeout** required per hook.

## 6. Permission + sandbox policy

Cross-ref: container hardening (`security_opt`, `cap_drop`, `mem_limit`,
`pids_limit`), `--dangerously-skip-permissions` (intentional, per CLAUDE.md),
`setup-claude-config.sh`.

- [x] Container hardened (`no-new-privileges`, drop ALL caps, mem/pid
  limits).
- [x] Permissive Claude settings applied with backup/restore.
- [x] **Per-agent network policy** — `network: allow|deny|allowlist`.
  Generated settings now deny WebFetch/WebSearch and common Bash network
  clients for standard/untrusted allowlist/deny profiles, with stricter git
  and package-manager denies for `network=deny`. Harness-managed git
  fetch/rebase/push now also gates network remotes with
  `AGENTMILL_GIT_REMOTE_ALLOWLIST`, and `mill` applies Docker
  `network_mode: none` for services whose resolved policy is
  `AGENTMILL_NETWORK=deny`. For `allowlist`, `mill` attaches selected services
  to an internal Docker network and starts an AgentMill HTTP(S) egress proxy
  that only connects to `AGENTMILL_EGRESS_ALLOWLIST` public targets.
- [x] **Bash command prefix allowlist / denylist** at the entrypoint
  settings layer. Non-trusted profiles now generate Claude `Bash(...)`
  allows from `AGENTMILL_SHELL_ALLOWLIST`, deny high-risk system commands,
  shell network clients, and optional `AGENTMILL_SHELL_DENYLIST` patterns.
  Claude runs now also get an AgentMill `PreToolUse` hook that blocks denied
  Bash commands using parsed argv-token prefix matching before execution.
  Codex runs now get generated permission profiles, execpolicy prefix rules,
  and non-trusted `untrusted` approval defaults; Qwen/OpenCode/Gemini receive
  the strongest native settings each CLI exposes, with Gemini shell disabled
  when prefix denies cannot be represented. Headless session logs are audited
  before auto-commit/push as a backstop.
- [x] **Filesystem write roots** — persistent host writes are constrained by a
  read-only container root filesystem plus tmpfs scratch for `/tmp`,
  `/home/agent`, and `/workspace`; intended durable write roots are the mounted
  repo, `logs/`, and `memory/`. `AGENTMILL_WRITE_ROOTS` / profile
  `write_roots` now enforce repo-relative durable output roots through Claude
  `PreToolUse`, Codex permission profiles, Bubblewrap filesystem sandboxes for
  OpenCode/Qwen/Gemini, and pre-commit/push gates for standard/untrusted runs.
- [x] **Clone/read-only host mode** — standard/untrusted `mill run` and
  `mill watch` auto-select read-only clone mode. The host repo is mounted at
  `/workspace/upstream:ro`, work happens in a container-local clone, and
  patch artifacts are written under `logs/patches/`. `mill patches` lists
  artifacts, and `mill apply` applies one to a clean target repo, optionally
  on a new branch.
- [x] **Egress allowlist for harness git remotes** — harness-managed
  fetch/rebase/push now treats local remotes as non-egress, blocks network
  `origin` remotes when `AGENTMILL_NETWORK=deny` unless
  `AGENTMILL_ALLOW_GIT_NETWORK=true`, and enforces
  `AGENTMILL_GIT_REMOTE_ALLOWLIST` for production-vs-throwaway remotes.
- [x] **Profile-aware git policy** — branch, add/commit, push, rebase, and
  force-push behavior must obey `agents/<role>.toml`. Implemented so startup
  enforces `AGENT_BRANCH`, protects configured branches from standard/untrusted
  direct writes unless explicitly overridden, emits policy events, and TUI
  auto-commit defaults to `off` for non-trusted profiles. Push/rebase policy
  now validates refs, branch agreement, protected branches, force-push denial,
  and harness git remote egress before remote side effects. New merge commits
  are denied for standard/untrusted iterations unless explicitly overridden.
- [x] **High-risk file-change gate** — standard/untrusted runs block
  commit/push when CI workflows, MCP/Claude/Codex config, env files,
  package scripts, Makefiles, container config, deploy/release scripts, or
  auth/secret paths changed unless explicitly allowed.
- [x] **`AGENTMILL_PROFILE_LEVEL=trusted|standard|untrusted`** env that
  picks a settings template. Basic settings generation and event metadata are
  implemented; Claude PreToolUse, Codex permission profiles and execpolicy,
  Bubblewrap write-root sandboxes for native and ACP non-Claude transports,
  ACP permission cancellation, conservative non-Claude native settings, and
  post-session shell/tool-class gates now harden tool mediation. Observed web,
  MCP, and subagent calls in JSON telemetry block auto-commit/push when they
  violate profile policy; where a client lacks Claude-style pre-execution hook
  APIs, AgentMill fails closed before durable output instead of relying on that
  missing hook surface.

## 7. MCP / skills / agents scoping (host config forwarding)

Cross-ref: commit `c293ca0` "enable all project MCP servers", commit
`103765d` "inject host skills, agents, auto-trust", `docker-compose.yml`
mounts of `~/.claude/{skills,agents,plugins,commands}`.

- [x] Host skills/agents/plugins/commands mounted into the container.
- [x] **Fail-closed host config forwarding** — for `standard` and
  `untrusted`, host `allowedTools`, hooks, env, plugins, skills, agents, and
  commands are not merged/copied unless the role explicitly enables
  `AGENTMILL_FORWARD_HOST_TOOLS`, `AGENTMILL_FORWARD_HOST_HOOKS`,
  `AGENTMILL_FORWARD_HOST_ENV`, or `AGENTMILL_FORWARD_HOST_EXTENSIONS`.
  Host settings never overwrite a safer profile `defaultMode`.
- [x] Project MCP forwarding is profile-aware: `trusted` preserves current
  broad forwarding, while `standard`/`untrusted` suppress host/project MCP
  unless `AGENTMILL_FORWARD_HOST_MCP=true`.
- [x] **Per-role MCP allowlist** in `agents/<role>.toml` so a researcher
  cannot accidentally invoke deploy/infra MCP servers. Allowlist filtering,
  Claude settings generation, manifest snapshots, and non-trusted config-hash
  drift detection are implemented.
- [x] **Live MCP tool-description/schema rug-pull detection** for stdio MCP
  servers. Manifest snapshots now include live `tools/list` names plus
  description/input-schema hashes when available, and the existing
  non-trusted manifest lock denies later iterations if that metadata changes.
- [x] **Per-role skill allowlist** to keep token budget tight on long runs:
  `agents/<role>.toml` exports `AGENTMILL_SKILL_ALLOWLIST`, and host skill
  copying filters to explicit skill directory names outside `trusted`.
- [x] **`mill mcp list`** + `mill mcp test <name>` for diagnosis, backed by
  redacted MCP manifest snapshots.
- [x] **Skill/agent precedence**: project `.claude/` remains separate from
  host `~/.claude/` staging; documented and covered by host forwarding tests.

## 8. Multi-language auto-setup

Cross-ref: `setup-repo-env.sh`, README §"Auto-Setup".

- [x] Python: `uv sync --frozen`, `pip install .`, `requirements.txt`.
- [x] `REPO_SETUP_COMMAND` override; `EXTRA_PYTHON_TOOLS` knob.
- [x] **Node**: `package-lock.json`/`pnpm-lock.yaml`/`yarn.lock` →
  `npm ci`/`pnpm install --frozen-lockfile`/`yarn install --immutable`.
- [x] **Go**: `go.mod` → `go mod download`.
- [x] **Rust**: `Cargo.toml` + `Cargo.lock` → `cargo fetch`.
- [x] **`Makefile install`** preferred when present (already recommended in
  README — make detection explicit and first-priority).
- [x] **`AUTO_SETUP_LANGUAGES`** env to opt out (e.g. heavy monorepos).

## 9. `mill doctor` + config validation

Cross-ref: README §"Quick Start" (manual checks today), `resolve_model()` in
`entrypoint-common.sh`, commit `293c151` "Pin claude-code CLI".

- [x] **`mill doctor`** checks: docker daemon, image presence, repo path,
  ownership/writability, prompt file resolvable, auth (one of API key / OAuth
  token), `.env` schema, profile validity, finite standard/untrusted budgets,
  broad MCP forwarding, high-risk override, hooks, compose read-only hook and
  host config mounts, git branch/remote/worktree, model alias/version floor,
  local image freshness against `Dockerfile`, and host claude-code CLI
  availability. It also validates the latest MCP manifest against the current
  allowlist and can fail strict preflight when allowlisted stdio launch commands
  are not reachable on `PATH`.
- [x] **`.env` schema validation** — required keys, conflicting keys
  (`ANTHROPIC_API_KEY` + `CLAUDE_CODE_OAUTH_TOKEN` set is a warning), and
  unknown keys are flagged.
- [x] **`mill doctor --fix`** — auto-create `.env`, `prompts/PROMPT.md`,
  `memory/`, `logs/` (subset of current `mill init`).
- [x] **`mill version`** — print mill version, image tag, claude-code CLI
  version, model defaults, host info.
- [x] **Actionable errors** for malformed `agents/*.toml`, missing prompt
  files, broken host mounts. Missing prompt, malformed profiles, host config
  mounts, and key runtime policy errors are covered by `mill doctor`.

## 10. Memory layer hardening

Cross-ref: CLAUDE.md §"Shared Memory", `memory/`, `mill memory`, commit
`d6f1a1d` "enhance memory layer".

- [x] flock-guarded markdown memory.
- [x] `mill memory` list/read/search/clear.
- [x] **Topic schema** — frontmatter (`type: findings|sources|decisions|
  contradictions|open_questions`, `created`, `last_iteration`). Keeps
  parsers honest.
- [x] **Append discipline test** — `tests/test_memory_concurrent.sh` spawns
  N writers and asserts no torn writes.
- [x] **`mill memory rotate`** — archive old entries to
  `memory/archive/<date>/` to keep working set small.
- [x] **`mill memory dedup`** — sources.md URL dedup pass.
- [x] **Read-by-role** — a role's prompt only loads memory topics it cares
  about (researcher: findings/sources; coder: decisions/failed_approaches).

## 11. Researcher mode polish

Cross-ref: `docs/RESEARCHER_AGENT.md`, `prompts/PROMPT_RESEARCH*`,
`prompts/TASK_TEMPLATE.md`.

- [x] Researcher prompts (breadth/depth/redteam) and TASK_TEMPLATE.
- [x] Memory layout for research (findings/sources/contradictions/open_qs).
- [x] **`mill init --research <topic>`** scaffolds the
  `~/research/<topic>/` layout (TASK.md, REPORT.md, memory/, logs/).
- [x] **Research-mode completion gate**:
  `no-new-sources-for-N-iterations` + `open_questions == 0`.
- [x] **Per-iteration audit**: which section of REPORT was touched, which
  sources added — already partially in results.tsv; expose via
  `mill report status`.
- [x] **Source-class filters** in the prompt — preprint vs peer-reviewed vs
  vendor blog. Document in TASK_TEMPLATE.
- [x] **`docs/LONG_RUNNING.md`** referenced from RESEARCHER_AGENT.md exists
  and maps researcher mode back to the broader long-running-agent pattern.

## 12. Cost + token observability

Cross-ref: `MAX_ITERATIONS`, `MAX_WALL_SECONDS`, and `MAX_LOG_BYTES` govern
runtime/log budgets today.

- [x] **Per-iteration usage** captured from claude-code JSON output and
  appended to `results.tsv` (input/output tokens, cache hits, est cost).
  Implemented for headless JSON logs, mirrored to `logs/usage.tsv`, shared by
  all JSON client adapters, and backed by optional estimator rates for clients
  that emit token counts without cost.
- [x] **`mill cost`** — daily/weekly/per-agent/per-iteration breakdown.
- [x] **`MAX_TOTAL_USD` / `MAX_TOTAL_TOKENS`** budget gate that stops the
  loop with a clean exit, including fail-closed handling for missing usage or
  cost telemetry when a budget is configured.
- [x] **`MAX_LOG_BYTES`** log-size budget gate stops the loop cleanly and emits
  `budget.exhausted` before logs grow without bound.
- [x] **Cache-hit telemetry** — long runs depend on prompt caching; surface
  hit rate to know when memory has grown too large.

## 13. Tests

Cross-ref: `tests/test_entrypoint_retry_limit.py`,
`tests/test_entrypoint_push_retry.sh`, `tests/test_resolve_model.sh`.

- [x] Retry limit, push retry, model resolution tests.
- [x] **Ralph completion-gate test** — fixture that emits sentinel; assert
  loop exits with code 0 and records reason.
- [x] **Numeric gate test** — boundary (gate < threshold, == threshold,
  > threshold).
- [x] **Multi-agent rebase test** — two fake agents push to same branch,
  assert one rebases successfully and the other fails after
  `PUSH_REBASE_MAX_RETRIES`.
- [x] **Settings backup/restore test** — symlink, missing file, corrupt
  JSON edge cases.
- [x] **Auto-setup detection test** — fixtures for python/node/go/rust/
  makefile and assert correct command invoked.
- [x] **Hook protocol test** — JSON stdin/stdout decision contract.
- [x] **Smoke integration test** — `mill run ./tests/fixtures/repo
  --iterations 1 --model haiku-4-5` end-to-end (gated on
  `ANTHROPIC_API_KEY`).

## 14. Image publishing + release hygiene

Cross-ref: `Dockerfile`, `.github/workflows/`, no published image today.

- [x] **GHCR publish** — `ghcr.io/kurcontko/agentmill:<semver>` and `:latest`
  on tag push.
- [x] **GitHub artifact provenance attestation** for the published image
  digest.
- [x] **Multi-arch build** — `linux/amd64` and `linux/arm64` (Apple Silicon
  hint already in README).
- [x] **`mill build --pull`** uses prebuilt image when available; falls
  back to local build.
- [x] **CHANGELOG.md** with claude-code CLI version bumps clearly noted
  (already pinned per commit `293c151`).
- [x] **Versioned `mill` script** — `mill --version` prints embedded version
  matching git tag.

## 15. Observability surface (lightweight, optional)

Cross-ref: `mill status`, `mill history`, `mill diff`, `mill logs`.

- [x] CLI inspection commands.
- [x] **`mill watch-status`** — `top`-style live dashboard reading
  `events.jsonl` + `results.tsv`.
- [x] **Optional web view** — `python -m http.server` over `logs/` rendered
  with a single self-contained HTML file (no JS framework). Strictly opt-in.
- [x] **Prometheus textfile exporter** — write `logs/metrics.prom` for
  iteration counts, push failures, convergence latency. Easy to scrape from
  outside the container.

## 16. Documentation gaps

Cross-ref: README, CLAUDE.md, docs/.

- [x] **`docs/LONG_RUNNING.md`** — referenced from CLAUDE.md and
  `docs/RESEARCHER_AGENT.md`; captures pedigree (Huntley 2025 Ralph loop,
  Anthropic Mar 2026, smsharma/clax) and how AgentMill maps to their
  recommendations.
- [x] **`docs/HOOKS.md`** once §5 lands.
- [x] **`docs/PROFILES.md`** once §2 lands.
- [x] **`docs/SECURITY.md`** expansion — root `SECURITY.md` covers
  reporting; docs threat model covers untrusted repos, leaked auth, hostile
  MCP/tooling, long-run budgets, memory/log poisoning, and profile hardening.
- [x] **`docs/GENERIC_CLIENT_ENGINE_PLAN.md`** — research and architecture
  plan for making AgentMill client-neutral across Claude, Codex, OpenCode,
  Qwen Code, Gemini CLI, and ACP-capable clients.
- [x] **README "Hackable by Design" section** — same spirit as Dante's
  positioning: bash + python stdlib only, every layer readable in one
  sitting.

## 17. Client-general engine

Cross-ref: `docs/GENERIC_CLIENT_ENGINE_PLAN.md`,
`docs/CODEX_INTEGRATION_PLAN.md`, `entrypoint.sh`,
`entrypoint-tui.sh`, `entrypoint-common.sh`, `docker-compose.yml`.

Current state: the durable loop is already mostly generic, but the execution
boundary is Claude-specific. The goal is to make Claude one client adapter
beside Codex, OpenCode, Qwen Code, Gemini CLI, and later ACP-compatible agents.

- [x] **`AGENTMILL_CLIENT=claude|codex|opencode|qwen|gemini`** — add a
  first-class client selector. Keep `AGENTMILL_PROVIDER` only as a deprecated
  compatibility alias for early Codex work.
- [x] **Claude adapter with no behavior change** — move current auth, model
  resolution, config prep, headless run, TUI run, and cleanup behind
  `client_*` functions.
- [x] **Provider/model vocabulary split** — reserve "client" for the CLI/agent
  executable and "provider" for the model backend used by that client.
- [x] **Fake client fixture** — test the loop, completion, hooks, commits, and
  events without a real AI client.
- [x] **Normalized client events** — emit `agent.started`,
  `agent.completed`, `tool.*`, `mcp.tool.*`, `usage.recorded`, and keep raw
  client event names in payloads.
- [x] **Client policy IR** — compile `trusted|standard|untrusted` profiles into
  read/edit/shell/web/MCP/subagent/network rules, then project into Claude,
  Codex, OpenCode, Qwen, and Gemini native config.
- [x] **Client home isolation** — generate config under a selected-client home
  and import host config only when the profile permits it.
- [x] **OpenCode adapter** — install/pin OpenCode, generate `opencode.json`,
  run `opencode run --format json`, parse events, and map permissions.
- [x] **Qwen/Gemini-family adapter** — use `qwen`/`gemini` headless JSON or
  stream-json output with isolated `.qwen`/`.gemini` settings and fail-closed
  sandbox/profile checks.
- [x] **Codex adapter** — preserve the detailed Codex implementation plan, but
  hang it from the same `AGENTMILL_CLIENT` adapter contract.
- [x] **ACP transport** — experimental path for `mill shell`/`mill watch` with
  clients exposing JSON-RPC over stdio, especially OpenCode and Qwen Code.

---

## Cross-cutting constraints

From CLAUDE.md §"Code Conventions":

- Shell scripts use `set -euo pipefail` and pass `shellcheck`.
- Python targets 3.11+, **stdlib only** (no third-party deps in framework).
- Entrypoints must trap signals and clean up — never leave orphan processes.
- Git operations need bounded retries; never retry infinitely.
- All user-facing config via env vars (documented in
  `docker-compose.yml`/`.env.example`).
- Status files go under `logs/`.
- Container runs as non-root `agent` (UID 1000).
- `--dangerously-skip-permissions` inside containers stays — automation by
  design.
- Brightdata MCP preferred over built-in web tools; for git repo scraping,
  clone into `/tmp` and operate locally.

## Suggested order

Driven by leverage: each item should make the next one cheaper.

1. **Fail-closed host config forwarding** (§7) — implemented: non-trusted
   runs no longer inherit host tools, hooks, env, plugins, skills, agents,
   commands, or permissive `defaultMode` unless explicitly forwarded.
2. **Structured events `logs/events.jsonl`** (§4) — implemented: unblocks
   policy audit, doctor, hooks, tests, dashboard, cost tracking, and incident
   review.
3. **Client adapter boundary** (§17) — wrap current Claude behavior first, then
   add fake/OpenCode/Qwen/Codex clients without forking the harness.
4. **Profile-aware settings** (§2, §6) — `trusted|standard|untrusted` should
   decide tools, network, MCP, git push, and budget defaults.
5. **MCP / skill per-role allowlists** (§7) — stop enabling every host/project
   MCP server before long runs become routine.
6. **Cost + token + wall-clock gates** (§3, §12) — required for safe infinite
   or overnight loops.
7. **Agent profiles `agents/<role>.toml`** (§2) — turns the latent role system
   into a first-class configuration surface.
8. **Per-mode convergence gates** (§3) — researcher/coder/refactor have
   different "done" definitions.
9. **Hooks v1: pre/post/complete/failure** (§5) — policy enforcement and
   high-risk action vetoes after events exist.
10. **`mill doctor`** (§9) — validate profile, MCP, auth, model, mounts, and
   policy before a run starts.
11. **Memory layer hardening** (§10) — typed provenance, dedup, rotation,
   concurrent-write tests, and no-secret durable writes.
12. **Test coverage** (§13).
13. **Multi-language auto-setup** (§8).
14. **GHCR publish + signed images** (§14).
15. **Sandbox tightening** (§6) — network/firewall and filesystem enforcement
   become profile-specific.
16. **`mill run --json`, Python module surface** (§1).
17. **Researcher mode polish** (§11).
18. **Observability dashboard** (§15) — last, opt-in.
