# Client Refactor Web Research Gaps

Research date: 2026-05-29. This note reviews the client-general refactor in
`TASK.md` section 17 against the existing plans in
`docs/GENERIC_CLIENT_ENGINE_PLAN.md`, `docs/CODEX_INTEGRATION_PLAN.md`, and the
security harness docs. Source discovery and page sampling used BrightData MCP
(`search_engine_batch`, `scrape_batch`).

## Summary

The current docs are strong enough to start the refactor by wrapping Claude
behind an adapter and adding a fake client. Additional web research becomes
valuable before adding real non-Claude clients, because those parts depend on
fast-moving CLI flags, JSON event shapes, config precedence, sandbox behavior,
and MCP/skill loading rules.

The highest-leverage research gaps are:

1. exact raw event schemas and fixture examples for OpenCode, Qwen, Gemini, and
   Codex;
2. sandbox behavior in the actual Docker/container constraints AgentMill uses;
3. permission/config precedence for project, user, generated, and env-provided
   settings;
4. MCP, skill, plugin, and instruction loading defaults for each client;
5. current install/package/release pins immediately before Docker changes;
6. ACP framing, capability negotiation, and client-specific implementation
   quirks before using ACP for `mill shell` or `mill watch`.

## Gaps

### 1. Raw JSON Event Fixtures

`docs/GENERIC_CLIENT_ENGINE_PLAN.md` proposes normalized events and fixture
tests, but still lacks source-backed raw event examples for each client. BrightData
confirmed the docs advertise machine-readable modes:

- OpenCode: `opencode run --format json` emits raw JSON events.
- Qwen Code: `--output-format json` returns buffered message arrays and
  `--output-format stream-json` emits line-delimited messages with `system`,
  `assistant`, and `result` examples.
- Gemini CLI: current docs and README results advertise `--output-format
  stream-json`.
- Codex: `codex exec --json` prints newline-delimited events.

Needed before implementation:

- scrape official event examples where available;
- run pinned CLI versions and save real fixture files under `tests/fixtures/`;
- define which raw fields map to `agent.*`, `tool.*`, `mcp.tool.*`,
  `usage.recorded`, and `file.changed`;
- verify failure, partial-message, tool-call, MCP-call, and token-usage events.

Web research helps locate official schemas and release notes. Local smoke tests
are still required because several docs describe formats generically rather than
pinning a stable schema.

### 2. Sandbox Behavior and Container Compatibility

The Codex plan already flags nested sandbox uncertainty, but the exact Linux
story needs refresh before enabling standard or untrusted Codex runs. BrightData
sampling found current Codex docs describing Linux setup in terms of `bubblewrap`
availability and user namespace support, while the command reference also
documents a `codex sandbox` Linux path using Landlock plus seccomp. That is a
material implementation detail for AgentMill's hardened Docker settings.

Needed before implementation:

- refresh Codex sandbox docs and CLI reference at the selected pinned version;
- test `codex sandbox ... -- true` or equivalent inside the AgentMill image;
- research Qwen/Gemini sandbox behavior inside containers and whether their
  sandbox flags imply Docker/Podman nesting;
- document fail-closed behavior when a requested profile cannot be enforced.

Web research should identify the current intended behavior. Final acceptance
must come from local container smoke tests.

### 3. Permission and Policy Projection

The generic plan proposes a policy IR, but exact projection rules are still
underspecified. BrightData found implementation-relevant details that should be
verified per client:

- OpenCode has native permissions, an `OPENCODE_PERMISSION` env var, agent
  permission frontmatter, and a `--dangerously-skip-permissions` run flag.
- Qwen/Gemini have approval modes, tool settings, sandbox flags, and project
  settings.
- Codex has sandbox mode, approval policy, execpolicy rules, hook trust, and
  permissions profiles.

Needed before implementation:

- source the exact syntax and precedence for each client's generated config;
- decide how AgentMill's `trusted|standard|untrusted` policy IR maps to native
  config and what cannot be represented natively;
- identify opt-out flags for project/user config loading;
- verify dangerous escape hatches are unavailable outside `trusted`.

This research should prioritize official docs and current command references.

### 4. Host and Project Config Precedence

Fail-closed host config forwarding is a top task item, but the client-neutral
refactor adds new config roots. Current docs identify broad principles, not a
full matrix for each client.

Needed before implementation:

- exact config paths and precedence for `~/.codex`, `.codex`, `.opencode`,
  `.qwen`, `.gemini`, `AGENTS.md`, `QWEN.md`, `GEMINI.md`, and `.agents/skills`;
- per-client flags/env vars that disable user/project config imports;
- which clients read `.env` automatically and how to prevent model credentials
  from reaching spawned shell commands;
- trust behavior for project-local hooks, rules, skills, agents, plugins, and
  MCP config.

OpenCode is especially worth refreshing because BrightData showed current docs
include compatibility with Claude prompt/skills loading and env vars such as
`OPENCODE_DISABLE_CLAUDE_CODE*`. That can silently bypass AgentMill's intended
client isolation unless explicitly handled.

### 5. MCP, Skills, Plugins, and OAuth

The existing security docs correctly treat MCP as high risk, but the generic
client plan needs client-specific MCP schemas before implementation.

Needed before implementation:

- machine-readable MCP listing commands per client, such as `codex mcp list
  --json` where available;
- local vs remote MCP transport schemas, OAuth support, bearer-token handling,
  and timeout controls;
- per-server and per-tool allowlist/denylist syntax;
- skill and plugin discovery paths, package formats, and disable flags;
- whether MCP tool descriptions and schemas can be snapshotted without starting
  broad host/project servers.

Web research helps build the config matrix; local tests need fake MCP servers
to verify generated allowlists.

### 6. Release Pins and Install Surfaces

`docs/CODEX_INTEGRATION_PLAN.md` pins a then-current Codex release. The
client-general plan lists other clients but does not yet pin package names,
release channels, or install methods.

Needed before Docker changes:

- latest stable release and recommended install method for Codex, OpenCode,
  Qwen Code, and Gemini CLI;
- package manager names and whether self-update should be disabled;
- changelog notes for JSON output, sandbox, MCP, and permissions changes;
- `mill doctor` version checks and minimum supported versions.

This should be refreshed immediately before editing `Dockerfile`, not cached
too early in docs.

### 7. ACP Protocol and Client Implementations

The generic plan correctly treats ACP as a later transport. BrightData confirmed
the ACP overview uses JSON-RPC 2.0 with initialization, capability negotiation,
`session/prompt`, `session/update`, file operations, terminal operations, and
permission requests. It also exposed a bad/stale URL assumption: a direct
`/protocol/session-update` page returned 404; the schema is under
`/protocol/schema` with anchors.

Needed before ACP implementation:

- scrape ACP initialization, prompt-turn, tool-call, transports, and schema
  pages, not only the overview;
- reconcile OpenCode's docs saying `opencode acp` communicates via nd-JSON
  with ACP's JSON-RPC message model;
- verify which clients expose ACP today and which capabilities they advertise;
- define how AgentMill turns ACP permission requests and terminal/file
  operations into policy events.

ACP should not block the headless adapter work.

### 8. New Autonomy Features in Qwen/Gemini-Like Clients

The current plan treats Qwen/Gemini as a shared JSON-client family. BrightData
search surfaced Qwen docs and updates around subagents, hooks, scheduled tasks,
auto approval, goal/autonomous modes, and worktree isolation. These features
may be useful later, but they expand AgentMill's authority surface.

Needed before enabling:

- whether goal/background/scheduled modes can run without AgentMill's loop;
- how subagents inherit tools, MCP servers, memory, and credentials;
- how client-managed worktrees interact with AgentMill's branch and clone-mode
  policy;
- which features must be disabled in generated standard/untrusted config.

For the first adapter, use only explicit headless prompt execution and disable
client-native autonomy unless a separate policy decision enables it.

## Source Pages Sampled

- OpenCode CLI: <https://open-code.ai/en/docs/cli>
- OpenCode permissions: <https://opencode.ai/docs/permissions>
- Qwen Code headless mode:
  <https://qwenlm.github.io/qwen-code-docs/en/users/features/headless/>
- Qwen Code approval mode:
  <https://qwenlm.github.io/qwen-code-docs/en/users/features/approval-mode/>
- Qwen Code sandboxing:
  <https://qwenlm.github.io/qwen-code-docs/en/users/features/sandbox/>
- Gemini CLI headless:
  <https://google-gemini.github.io/gemini-cli/docs/cli/headless.html>
- Gemini CLI configuration:
  <https://google-gemini.github.io/gemini-cli/docs/get-started/configuration.html>
- Gemini CLI MCP:
  <https://google-gemini.github.io/gemini-cli/docs/tools/mcp-server.html>
- Codex non-interactive mode:
  <https://developers.openai.com/codex/noninteractive>
- Codex command reference:
  <https://developers.openai.com/codex/cli/reference>
- Codex sandboxing:
  <https://developers.openai.com/codex/concepts/sandboxing>
- ACP overview: <https://agentclientprotocol.com/protocol/overview>
- ACP schema: <https://agentclientprotocol.com/protocol/schema>
- ACP tool calls: <https://agentclientprotocol.com/protocol/tool-calls>

## Recommendation

Do not do more web research before phases 0-2 of the client refactor:

1. add `AGENTMILL_CLIENT` naming/docs;
2. wrap Claude behind a no-behavior-change adapter;
3. add a fake client and normalized-event fixture harness.

Do run targeted BrightData research before each real adapter phase. Treat every
non-Claude adapter as requiring a short preflight research note that captures
current CLI version, install path, JSON event samples, config precedence,
permission mapping, sandbox behavior, MCP/skills defaults, and known escape
hatches.
