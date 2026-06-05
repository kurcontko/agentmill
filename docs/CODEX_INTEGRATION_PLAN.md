# Codex Integration Plan for AgentMill

Research date: 2026-05-29. Source discovery and page sampling were done with
BrightData MCP (`search_engine_batch`, `scrape_batch`, and
`scrape_as_markdown`). Official OpenAI markdown endpoints and the GitHub API
were then used for precise command/config details from the discovered sources.

Broader note: this plan is Codex-specific. The cross-client architecture and
recommended `AGENTMILL_CLIENT` naming are tracked in
`docs/GENERIC_CLIENT_ENGINE_PLAN.md`. If both plans mention
`AGENTMILL_PROVIDER`, treat it as the older Codex-only name and keep it only as
a compatibility alias.

## Executive Summary

AgentMill should integrate Codex by becoming provider-neutral at the execution
boundary, not by forking the harness. The valuable AgentMill pieces already
exist outside the model provider: Docker isolation, repo setup, git commits,
multi-agent branches, `memory/`, `logs/results.tsv`, `logs/events.jsonl`, wall
clock gates, and prompt files. The Claude-specific pieces should become one
provider adapter beside a Codex adapter.

The recommended target:

1. Keep `mill run/watch/multi/shell` as the operator interface.
2. Add `AGENTMILL_PROVIDER=claude|codex`, defaulting to current `claude`.
3. Add a Codex provider adapter that runs `codex exec` for headless iterations
   and `codex` for interactive/watch sessions.
4. Parse `codex exec --json` directly into AgentMill events and usage/cost
   telemetry.
5. Generate provider-specific config under isolated homes:
   `/home/agent/.claude` for Claude and `/home/agent/.codex` for Codex.
6. Map AgentMill profile levels (`trusted|standard|untrusted`) to Codex
   sandbox, permission-profile, rules, MCP, hooks, and network settings.
7. Add `AGENTS.md` support and repo-local `.agents/skills` support so Codex
   gets the same durable instructions and role workflows that Claude gets from
   `CLAUDE.md` and current prompt files.

Do not make Codex the only engine yet. The lowest-risk implementation is a
side-by-side provider track with shared loop code and provider-specific auth,
config, invocation, and telemetry.

## Current AgentMill Provider Coupling

The current tree is intentionally Claude-first:

- `Dockerfile` installs `@anthropic-ai/claude-code` and pins
  `CLAUDE_CODE_VERSION`.
- `entrypoint.sh` runs `claude --dangerously-skip-permissions -p "$PROMPT"`.
- `entrypoint-tui.sh` launches `claude` through `auto-trust.exp` and builds a
  Claude-specific Ralph slash command prompt.
- `entrypoint-common.sh` has Claude-only auth, model aliasing, version checks,
  and `.claude/settings.local.json` backup/restore.
- `setup-claude-config.sh` forwards host `~/.claude` config, plugins, skills,
  agents, commands, and MCP/project trust state.
- `docker-compose.yml` forwards `ANTHROPIC_API_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN`, and host `~/.claude/*` paths.
- `README.md`, `.env.example`, `CLAUDE.md`, and `TASK.md` describe Claude
  models, Claude settings, and Claude output parsing.

Codex integration should isolate each of those surfaces behind provider-aware
functions and docs instead of mixing Codex conditionals through every script.

Important current-state note: the repo contains a zero-byte `.codex` file. Codex
project configuration requires `.codex/` as a directory. Replacing that file
with a directory is a required migration step before project-local Codex
config, hooks, or rules can be committed.

## Research Findings

### Codex CLI and Automation

OpenAI documents `codex exec` as the non-interactive mode for scripts and CI.
It accepts a prompt argument or `-` for stdin, sends progress to `stderr`, and
prints the final message to `stdout` by default. With `--json`, `stdout`
becomes a JSONL event stream containing thread/turn lifecycle events, item
events, and `turn.completed` usage including input, cached input, output, and
reasoning output tokens. This maps directly to AgentMill's `logs/events.jsonl`
and the planned token/cost gates.

Recommended headless shape:

```bash
codex exec - \
  --cd "$REPO_DIR" \
  --model "$MODEL" \
  --json \
  --ask-for-approval untrusted \
  --output-last-message "$SESSION_FINAL"
```

Use `codex exec resume` only for explicit staged workflows. AgentMill's core
value is a fresh-context loop backed by files and git, so default iterations
should start new Codex exec sessions rather than resume prior Codex sessions.

### Auth

Codex supports ChatGPT sign-in, API key sign-in, and enterprise Codex access
tokens. For automation, OpenAI recommends API-key auth and notes that
`CODEX_API_KEY` is supported for a single `codex exec` invocation. The docs
warn not to expose API keys as broad job-level environment variables when
repository-controlled code can run in the same environment.

AgentMill implication:

- Add `CODEX_API_KEY`, `OPENAI_API_KEY`, `CODEX_ACCESS_TOKEN`, and `CODEX_HOME`
  env docs, but do not blindly forward all of them to model-generated commands.
- For `codex exec`, prefer `CODEX_API_KEY` scoped to the provider invocation.
- Set Codex `shell_environment_policy.include_only` so spawned commands do not
  inherit model credentials.
- For interactive/watch mode, support either a mounted `~/.codex/auth.json` in
  trusted mode or startup login from a provided API key/access token.
- Treat mounted `auth.json` like a secret. Do not mount it for `standard` or
  `untrusted` until credential isolation is stronger.

### Versioning and Install

The OpenAI Codex GitHub repo currently reports release `0.135.0`, published
2026-05-28. The README lists install options: the `chatgpt.com/codex/install.sh`
installer, `npm install -g @openai/codex`, Homebrew, and release binaries.

AgentMill should mirror the existing Claude pin:

```dockerfile
ARG CODEX_CLI_VERSION=0.135.0
RUN npm install -g "@openai/codex@${CODEX_CLI_VERSION}"
```

Add `codex --version`, `codex doctor`, and `codex login status` checks to the
future `mill doctor`.

### Models

The current Codex model docs recommend `gpt-5.5` for most Codex tasks and
`gpt-5.4-mini` for faster/lower-cost lighter coding or subagent work.
`gpt-5.3-codex` remains listed for Codex Cloud. The latest OpenAI model guide
also identifies `gpt-5.5` as the latest model and calls out stronger complex
coding, tool-heavy agent, and long-running workflow behavior.

AgentMill implication:

- Do not reuse Claude aliases directly. Add provider-aware model resolution.
- Suggested defaults:
  - `claude`: keep current `sonnet` behavior.
  - `codex`: default to `gpt-5.5`.
  - `codex-fast` or reviewer/subagent roles: `gpt-5.4-mini`.
- Keep explicit model IDs pass-through.

### Sandbox and Network

Codex has three relevant control layers: permission profiles, the legacy
sandbox mode override, and approval policy. Defaults are designed around no
command network access and workspace-limited writes. Relevant sandbox override
modes are `read-only`, `workspace-write`, and `danger-full-access`; approval
policies include `untrusted`, `on-request`, and `never`.

Codex Linux sandboxing uses `bubblewrap` plus `seccomp` by default. OpenAI
explicitly notes that Docker/containerized environments may block the namespace,
setuid `bwrap`, or seccomp operations Codex needs. In that case, the docs say
to configure Docker as the isolation boundary and run Codex with
`danger-full-access` inside the container.

AgentMill implication:

- Prefer generated Codex permission profiles over `--sandbox` for AgentMill
  runs, because profiles can express workspace-root write scopes, env-file deny
  reads, and network allowlists in one profile.
- Keep `AGENTMILL_CODEX_SANDBOX` only as an explicit legacy override. Standard
  and untrusted doctor checks reject combining that override with
  `AGENTMILL_WRITE_ROOTS`, because it bypasses generated write-root rules.
- If a profile still needs `danger-full-access`, allow it only for trusted
  provider runs with Docker/AgentMill as the outer isolation boundary.
- Keep AgentMill-level egress controls on the roadmap because Codex hooks and
  rules do not fully replace container/network boundaries.

### Rules, Hooks, and Permissions

Codex has three useful policy surfaces:

- Rules: Starlark `.rules` files with tokenized `prefix_rule()` command
  policies. Codex splits simple `bash -lc` chains into independent commands
  before policy evaluation and conservatively treats complex shell scripts as a
  single shell invocation.
- Hooks: lifecycle hooks such as `PreToolUse`, `PermissionRequest`,
  `PostToolUse`, `SessionStart`, `Stop`, and subagent hooks. Hooks can deny
  supported tool calls or add context. OpenAI documents that `PreToolUse` is a
  guardrail, not a complete enforcement boundary, because interception is not
  complete for every tool path.
- Permission profiles: beta least-privilege filesystem and network profiles,
  including workspace roots, deny-read globs, domain allowlists, and local
  network guards.

AgentMill implication:

- For Codex runs, prefer Codex rules/permissions for Codex-native enforcement
  instead of duplicating all shell policy in bash.
- Still keep AgentMill policy events and external guardrails because Codex's
  hook interception is explicitly incomplete.
- Generate provider config from AgentMill profiles:
  - `trusted`: generated workspace-write permission profile, with explicit
    sandbox override available for trusted Docker-isolated runs.
  - `standard`: generated permission profile, optional scoped
    `AGENTMILL_WRITE_ROOTS`, no command network by default, rules for git
    push/deploy/package managers, no project `.codex` unless trusted.
  - `untrusted`: generated read-only or clone-mode permission profile, no
    network, no host Codex auth/config forwarding, finite budgets required.

### MCP and Skills

Codex supports MCP over STDIO and streamable HTTP, including bearer tokens and
OAuth. MCP server config lives in `~/.codex/config.toml` or trusted
project-local `.codex/config.toml`. Per-server controls include `enabled`,
`required`, `enabled_tools`, `disabled_tools`, default/per-tool approval modes,
timeouts, and OAuth scopes.

Codex skills are not stored under `~/.claude/skills`. Codex reads skills from
repo `.agents/skills`, user `$HOME/.agents/skills`, admin `/etc/codex/skills`,
and system locations. Skills use progressive disclosure and can be packaged in
plugins.

AgentMill implication:

- Add Codex mounts separately from Claude mounts:
  - host `~/.codex` only in trusted mode;
  - host `~/.agents/skills` as read-only when allowed;
  - repo `.agents/skills` for checked-in AgentMill workflows.
- Generate Codex MCP config from AgentMill role/profile definitions instead of
  blindly forwarding every host server.
- For researcher mode, configure BrightData as an allowlisted MCP server/tool
  set for Codex just as current prompts prefer BrightData for Claude.

### Instructions and Repo Knowledge

Codex reads `AGENTS.md` and `AGENTS.override.md`, starting from global Codex
home and then from the Git root down to the current directory. Project-local
Codex config, hooks, and rules load only for trusted projects.

The OpenAI harness-engineering post strongly supports AgentMill's current
direction: small agent-legible entry points, repository knowledge as the system
of record, execution plans checked into the repo, custom linters with
agent-readable remediation, worktree-isolated app instances, and direct access
to logs/metrics/UI state. It also warns that a single huge `AGENTS.md` becomes
stale and crowds out useful context.

AgentMill implication:

- Add a concise `AGENTS.md` that mirrors `CLAUDE.md` for Codex but acts as a
  map, not an encyclopedia.
- Keep deeper guidance in `docs/`, `prompts/`, and future `agents/*.toml`.
- Prefer execution plans and indexed docs over monolithic prompt files.
- Add mechanical checks that key docs and prompt references stay current.

## Proposed Architecture

### Provider Boundary

Add a small provider layer in shell, likely inside `entrypoint-common.sh` first
and then split when it grows:

```bash
agent_provider="${AGENTMILL_PROVIDER:-claude}"

agent_require_auth "$agent_provider"
agent_resolve_model "$agent_provider" "$MODEL"
agent_prepare_config "$agent_provider" "$profile" "$REPO_DIR"
agent_run_headless "$agent_provider" "$PROMPT_CONTENT" "$SESSION_LOG"
agent_run_tui "$agent_provider" "$INITIAL_PROMPT"
agent_parse_usage "$agent_provider" "$SESSION_LOG"
```

Provider-specific responsibilities:

| Surface | Claude adapter | Codex adapter |
| --- | --- | --- |
| Install | `@anthropic-ai/claude-code` | `@openai/codex` or release binary |
| Auth | `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` | `CODEX_API_KEY`, `OPENAI_API_KEY`, `CODEX_ACCESS_TOKEN`, `auth.json` |
| Home | `/home/agent/.claude` | `/home/agent/.codex` via `CODEX_HOME` |
| Instructions | `CLAUDE.md`, prompt files | `AGENTS.md`, `.agents/skills`, prompt files |
| Headless | `claude -p` | `codex exec - --json` |
| TUI | `claude` + `auto-trust.exp` | `codex "$INITIAL_PROMPT"` or `codex --cd "$REPO_DIR"` |
| Config | `.claude/settings.local.json` | `.codex/config.toml`, rules, hooks |
| Events | parse session log later | consume JSONL directly |

### Codex Headless Loop

Initial `entrypoint.sh` behavior for Codex:

1. Build `PROMPT_CONTENT` exactly as today, including iteration context.
2. Run `codex exec - --json --cd "$REPO_DIR"` and pipe the prompt on stdin.
3. Capture JSONL to a raw session file, for example
   `logs/session_codex_YYYYmmdd_iterN.jsonl`.
4. Normalize Codex JSONL into AgentMill events:
   - `thread.started` -> `codex.thread.started`
   - `turn.started` -> `iteration.agent_turn.started`
   - `item.started/completed` command execution -> `tool.invoked`,
     `tool.completed`
   - MCP tool call items -> `mcp.tool.invoked`, `mcp.tool.completed`
   - file change items -> `file.changed`
   - `turn.completed.usage` -> `usage.recorded`
   - `turn.failed` or `error` -> `iteration.failed`
5. Preserve existing AgentMill commit, push, convergence, wall-clock, and
   results-log behavior.

For first implementation, parsing can be a small Python stdlib script under
`tools/` or a shell+jq path if `jq` is guaranteed in the image. Python stdlib is
already available in the image and avoids new runtime dependencies.

### Codex Config Generation

Generate a minimal `$CODEX_HOME/config.toml` at startup rather than mutating
host config. Current generated runs use `default_permissions = "agentmill"`
unless `AGENTMILL_CODEX_SANDBOX` is explicitly set:

```toml
model = "gpt-5.5"
approval_policy = "untrusted"
default_permissions = "agentmill"

[shell_environment_policy]
include_only = ["PATH", "HOME", "LANG", "LC_ALL", "TERM"]

[permissions.agentmill.filesystem]
":minimal" = "read"
glob_scan_max_depth = 3

[permissions.agentmill.filesystem.":workspace_roots"]
"." = "read"
"src" = "write"
"tests" = "write"
"**/*.env" = "deny"

[permissions.agentmill.network]
enabled = false

[agentmill]
profile = "standard"
network = "deny"
```

Then add profile-specific overlays:

- `trusted`: optional host Codex config import, optional live web search, MCP
  forwarding if explicitly enabled.
- `standard`: no host config import by default, finite loop required, no command
  network except allowlisted package/git endpoints, project `.codex` only after
  trust.
- `untrusted`: no host Codex config, no auth cache mount, no command network,
  no project `.codex`, no live web search, no push unless explicit.

### Codex TUI and Watch

Replace Claude-only `auto-trust.exp` in Codex mode:

- `mill shell <repo>`:
  - `AGENTMILL_PROVIDER=codex` runs `codex --cd "$REPO_DIR"` with no injected
    prompt.
- `mill watch <repo>`:
  - start `codex --cd "$REPO_DIR" "$INITIAL_PROMPT"` for a visible TUI session;
  - use `RESPAWN=true` the same way the current TUI loop does;
  - do not use Claude's `/ralph-loop` slash command.
- For autonomous watch, prefer Codex goal mode only after it is tested in this
  harness. Until then, the deterministic `codex exec` loop is a better match
  for AgentMill's existing one-task-per-iteration design.

## Implementation Phases

### Phase 0 - Documentation and Contract

Deliverables:

- Add this plan.
- Add a concise `AGENTS.md` for Codex users that points at `CLAUDE.md`,
  `README.md`, `TASK.md`, and the harness docs.
- Replace the current `.codex` file with a `.codex/` directory only when adding
  actual Codex project config.
- Add `TASK.md` items for provider abstraction, Codex config, Codex JSONL
  parser, and Codex auth.

Acceptance evidence:

- `git status` shows expected doc/config-only changes.
- `rg -n "AGENTMILL_PROVIDER|Codex|CODEX_HOME|CODEX_API_KEY"` finds the new
  documented surfaces.

### Phase 1 - Install and Auth Plumbing

Deliverables:

- Add `ARG CODEX_CLI_VERSION=0.135.0` and install Codex in `Dockerfile`.
- Add `.env.example` entries for:
  - `AGENTMILL_PROVIDER=claude|codex`
  - `CODEX_API_KEY`
  - `CODEX_ACCESS_TOKEN`
  - `CODEX_HOME=/home/agent/.codex`
  - `CODEX_MODEL=gpt-5.5` or provider-aware `MODEL`
- Add `require_codex_auth()` and `log_codex_version()`.
- Add `mill doctor` checks once `mill doctor` exists; until then, add startup
  diagnostics.

Acceptance evidence:

- Image build succeeds.
- `codex --version` prints the pinned release.
- `codex login status` is checked and reported without leaking secrets.
- Tests cover provider auth selection without requiring real keys.

### Phase 2 - Provider Adapter for Headless Runs

Deliverables:

- Add `AGENTMILL_PROVIDER` branching at the provider boundary.
- Implement `codex exec` invocation with prompt on stdin.
- Store raw Codex JSONL session logs.
- Keep current commit/push/sentinel behavior.
- Add fake `codex` fixtures for tests.

Acceptance evidence:

- A fake Codex run can touch `$DONE_FILE`, create a file, and be committed by
  the existing loop.
- Claude provider behavior stays unchanged.
- Shell tests prove provider selection and prompt-file handling.

### Phase 3 - JSONL Event and Usage Parser

Deliverables:

- Parse `codex exec --json` into AgentMill `event_emit_kv` calls or a direct
  append path.
- Capture `turn.completed.usage` into `logs/events.jsonl` and eventually
  `logs/results.tsv`.
- Add `tool.invoked`/`tool.completed` counts from Codex item events.
- Add parser tests with static JSONL fixtures.

Acceptance evidence:

- `bash tests/test_events_jsonl.sh` still passes.
- New parser tests prove token counts, command events, MCP events, and error
  events are normalized.

### Phase 4 - Sandbox, Rules, and Profile Mapping

Deliverables:

- Test whether Codex `workspace-write` sandbox works in AgentMill's container
  when a user explicitly selects the legacy sandbox override.
- Install `bubblewrap` if needed and compatible for that legacy override.
- Generate Codex config profiles for `trusted`, `standard`, and `untrusted`.
  Implemented with generated `default_permissions = "agentmill"` profiles.
- Add Codex rules for high-risk commands. Implemented by generating
  `$CODEX_HOME/rules/agentmill.rules` from AgentMill shell allow/deny policy.
- Add startup fail-closed behavior when requested profile cannot be enforced.

Acceptance evidence:

- Generated config tests parse the Codex TOML profile and verify full-workspace
  and scoped-write-root modes; a future `codex sandbox linux
  --permissions-profile ... -- true` smoke test should document actual nested
  sandbox behavior for explicit legacy overrides.
- Standard/untrusted runs cannot start with `danger-full-access` unless an
  explicit trusted override is present.
- Rules tests with `codex execpolicy check` cover allowed and forbidden
  commands; unmatched commands fall through to Codex's non-trusted approval
  policy.

### Phase 5 - MCP, Skills, and Research Mode

Deliverables:

- Generate Codex MCP config from AgentMill role/profile definitions.
- Add BrightData MCP allowlist for Codex researcher roles.
- Add `.agents/skills` support for AgentMill workflows.
- Add Codex skill/plugin mounting rules separate from Claude mounts.

Acceptance evidence:

- `codex mcp list --json` shows only profile-allowed servers.
- Required MCP startup failure causes `codex exec` to fail early.
- A Codex researcher profile can use BrightData but not broad host MCP tools.

### Phase 6 - TUI/Watch and Multi-Agent Polish

Deliverables:

- Implement Codex `mill shell` and `mill watch`.
- Decide whether Codex subagents are enabled in automated runs. Default should
  be off until AgentMill role isolation is explicit.
- Map `mill multi` roles to Codex config profiles and AGENTS/skills context.

Acceptance evidence:

- `mill shell` opens Codex interactively in the mounted repo.
- `mill watch` can run a bounded autonomous Codex session and exit cleanly.
- Multi-agent Codex services keep isolated workspaces/branches as current
  Claude services do.

## Risks and Design Decisions

- **Nested sandbox uncertainty:** Codex's Linux sandbox may not work under the
  current Docker hardening. Treat this as a gating test before enabling Codex
  in `standard` or `untrusted`.
- **Credential exposure:** Passing `CODEX_API_KEY` through Compose exposes it
  to the container environment. Mitigate with Codex shell environment policy
  immediately, then move toward a proxy or short-lived scoped tokens.
- **Config trust:** Project `.codex/` can define config, hooks, and rules.
  Only load project Codex config for trusted projects.
- **Hook limits:** Codex hooks are useful but not a complete enforcement
  boundary. Keep AgentMill-level eventing, Docker isolation, and future egress
  policy.
- **Instruction duplication:** `CLAUDE.md` and `AGENTS.md` can drift. Keep both
  short and point to shared docs rather than copying large guidance blocks.
- **Provider vocabulary:** Avoid renaming every existing Claude field in one
  pass. Add provider-neutral names where new behavior is introduced, then
  deprecate old names after Codex works.

## Source Set

- Codex CLI overview and README:
  <https://developers.openai.com/codex/cli>,
  <https://github.com/openai/codex>
- Codex non-interactive mode:
  <https://developers.openai.com/codex/noninteractive>
- Codex command reference:
  <https://developers.openai.com/codex/cli/reference>
- Codex approvals and security:
  <https://developers.openai.com/codex/agent-approvals-security>
- Codex sandboxing:
  <https://developers.openai.com/codex/concepts/sandboxing>
- Codex config basics and reference:
  <https://developers.openai.com/codex/config-basic>,
  <https://developers.openai.com/codex/config-reference>
- Codex auth:
  <https://developers.openai.com/codex/auth>
- Codex rules, permissions, hooks, MCP, skills, and AGENTS.md:
  <https://developers.openai.com/codex/rules>,
  <https://developers.openai.com/codex/permissions>,
  <https://developers.openai.com/codex/hooks>,
  <https://developers.openai.com/codex/mcp>,
  <https://developers.openai.com/codex/skills>,
  <https://developers.openai.com/codex/guides/agents-md>
- Codex models and current OpenAI model guidance:
  <https://developers.openai.com/codex/models>,
  <https://developers.openai.com/api/docs/guides/latest-model>
- Codex GitHub Action:
  <https://developers.openai.com/codex/github-action>
- OpenAI harness engineering:
  <https://openai.com/index/harness-engineering/>
- Latest Codex release checked via GitHub API:
  <https://github.com/openai/codex/releases/tag/rust-v0.135.0>
