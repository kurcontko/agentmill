# Generic Client Engine Plan for AgentMill

Research date: 2026-05-29.

This document expands the Codex-specific integration work into a broader
client-neutral engine plan. The main idea: AgentMill should stay a durable
harness for repeated repo work, while Claude Code, Codex, OpenCode, Qwen Code
("qwencode"), Gemini CLI, and later clients become adapters at the process,
config, policy, and event boundaries.

## Executive Summary

AgentMill should generalize around `AGENTMILL_CLIENT`, not around one model
provider. "Client" means the coding-agent program that edits the repo, such as
`claude`, `codex`, `opencode`, `qwen`, or `gemini`. "Provider" should mean the
LLM backend used by that client, such as Anthropic, OpenAI, Qwen, OpenRouter,
local OpenAI-compatible servers, or OpenCode Zen. OpenCode in particular
already multiplexes many model providers, so calling the CLI selector
`AGENTMILL_PROVIDER` will become confusing quickly.

Recommended target:

1. Keep `mill run/watch/multi/shell` as the operator interface.
2. Add `AGENTMILL_CLIENT=claude|codex|opencode|qwen|gemini`, defaulting to
   current `claude`.
3. Keep `MODEL` as a compatibility alias, but internally resolve
   `AGENTMILL_MODEL` through the selected client.
4. Move Claude-only shell logic behind a client adapter contract first, with no
   behavior change.
5. Add new clients by implementing small adapters for auth, config generation,
   headless invocation, TUI invocation, native event parsing, and policy
   projection.
6. Use native JSON or JSONL headless modes for autonomous loops.
7. Use ACP for interactive/editor-style sessions once the core adapter layer is
   stable, especially for OpenCode and Qwen Code.
8. Treat Docker isolation, git workflow, logs, memory, convergence gates,
   hooks, and policy audit as AgentMill-owned behavior that must not move into
   any one client.

## Current Coupling

The current engine is still Claude Code specific at these boundaries:

- `Dockerfile` installs `@anthropic-ai/claude-code` only.
- `entrypoint.sh` resolves Claude model aliases and invokes
  `claude --dangerously-skip-permissions -p "$PROMPT_CONTENT"`.
- `entrypoint-tui.sh` is built around the Claude TUI and Ralph slash command.
- `entrypoint-common.sh` owns Claude auth, version checks, `.claude` settings,
  host MCP forwarding, and Claude model aliases.
- `setup-claude-config.sh` mutates/merges Claude config specifically.
- `docker-compose.yml` mounts `~/.claude*` paths and forwards Claude auth.
- Event names include `claude.completed`.

The durable harness behavior is already client-neutral in spirit:

- repo mount/clone/worktree setup;
- repeated fresh-context loop;
- prompt files and role profiles;
- `logs/results.tsv` and `logs/events.jsonl`;
- hooks and policy decisions;
- git identity, commits, rebases, pushes;
- memory files;
- completion and wall-clock gates.

The refactor should protect the second list and hide the first list behind
client-specific adapters.

## Research Findings

### OpenCode

OpenCode is the best reference client for genericity because it exposes several
integration surfaces:

- `opencode run [message..]` runs non-interactively for scripting and
  automation.
- `opencode run --format json` emits raw JSON events.
- `opencode serve` starts a headless HTTP API server.
- `opencode acp` starts an Agent Client Protocol subprocess over JSON-RPC via
  stdio.
- `opencode attach` can connect a TUI to an existing server.
- Config supports many model providers through `provider`, `model`, and
  `small_model`; OpenCode docs say it supports 75+ providers and local models.
- Permissions are native and granular: `allow`, `ask`, or `deny`, globally,
  per tool, per command pattern, per external directory, and per agent.
- Agents can be configured in `opencode.json` or markdown files under
  `.opencode/agents/`.
- OpenCode reads project instructions from `AGENTS.md` and can fall back to
  Claude conventions.
- Skills can live under `.opencode/skills`, `.claude/skills`, or
  `.agents/skills`.
- MCP supports local and remote servers, enable/disable flags, headers, OAuth,
  and per-agent/tool management.

AgentMill implication: OpenCode should be a first-class adapter after Claude is
wrapped because it exercises most abstractions AgentMill needs: multi-provider
models, native permission projection, native agents, skills, MCP, JSON events,
server mode, and ACP.

### Qwen Code / "qwencode"

Qwen Code is a separate coding-agent client, not just a model. Its current docs
show:

- `qwen -p "..."` and stdin-based usage for headless automation.
- `--output-format text|json|stream-json`, with JSON containing response and
  stats and streaming JSON suitable for event normalization.
- `--continue` and `--resume` for project-scoped sessions, but AgentMill should
  keep fresh sessions by default.
- `--approval-mode plan|default|auto-edit|yolo` and `--yolo` for automation.
- Settings in `~/.qwen/settings.json`, `.qwen/settings.json`, and system
  settings files, with command-line arguments taking highest precedence.
- `.qwen/` may hold project settings, sandbox files, and skills.
- MCP servers are configured in `mcpServers` through settings or `qwen mcp`.
- Sandbox support is Docker/Podman/macOS seatbelt oriented; `QWEN_SANDBOX` can
  override flags/settings.
- Qwen exposes an experimental Python SDK over the existing `stream-json` CLI
  protocol. The SDK includes permission callbacks that default to deny.
- Qwen has `--acp` for Agent Client Protocol integrations.

AgentMill implication: Qwen and Gemini CLI are likely a shared adapter family:
both accept `-p`, both can emit JSON/stream JSON, both use JSON settings and
project-local hidden config directories, both have MCP, both have approval
modes, and both can sandbox through an inner container. The important
AgentMill-specific problem is not prompt invocation; it is safe config import,
event normalization, and avoiding Docker-in-Docker surprises.

### Gemini CLI

Gemini CLI is relevant because Qwen Code is based on it and the surfaces are
similar:

- `gemini -p` is documented for headless mode.
- `--output-format json` returns response and stats; streaming JSON emits
  events such as init, message, tool use/result, error, and final result.
- Settings live in `~/.gemini/settings.json` and `.gemini/settings.json`.
- Gemini CLI uses `mcpServers` in settings for MCP.
- It supports approval and sandbox flags.

AgentMill implication: build one "Gemini-family JSON client" parser where
possible, but keep separate manifests because config paths, binary names, auth,
model defaults, and sandbox details diverge.

### Codex

The existing `docs/CODEX_INTEGRATION_PLAN.md` remains useful and detailed.
Codex is still a strong adapter candidate because `codex exec --json` maps
cleanly to AgentMill events and usage telemetry. The broader engine plan
changes one naming decision: prefer `AGENTMILL_CLIENT=codex` over
`AGENTMILL_PROVIDER=codex`, while keeping the older env name as a temporary
compatibility alias if implementation has already begun.

### ACP

Agent Client Protocol is useful as a long-term interactive protocol, not as the
first replacement for simple headless subprocess loops. ACP is JSON-RPC 2.0,
typically over stdio. A client creates or loads a session, sends
`session/prompt`, receives `session/update` notifications, handles permission
requests and file/terminal operations, and gets a prompt response with a stop
reason.

AgentMill implication:

- Use native `run`/`exec` headless modes first for autonomous commit loops.
- Use ACP for `mill shell`, `mill watch`, editor attachment, and eventually
  stable permission mediation across clients that implement ACP.
- Keep ACP as one transport under an adapter, not the only adapter shape.

## Proposed Architecture

### Harness Kernel

The harness kernel owns behavior that should be invariant across clients:

- repo discovery and clone/worktree setup;
- prompt assembly and iteration context;
- loop scheduling and shutdown;
- completion gates;
- hooks;
- memory and logs;
- normalized events;
- git add/commit/rebase/push;
- runtime policy validation;
- credential redaction;
- high-risk file checks;
- client capability snapshots.

This code should not know whether the active agent is Claude, OpenCode, Qwen,
Gemini, or Codex except through adapter calls.

### Client Adapter Contract

Start with shell functions in `entrypoint-common.sh`, then split into
`clients/<name>.sh` if it grows:

```bash
client_select "${AGENTMILL_CLIENT:-claude}"
client_version
client_require_auth
client_resolve_model "$MODEL"
client_prepare_home "$AGENTMILL_PROFILE_LEVEL"
client_prepare_project "$REPO_DIR" "$AGENTMILL_PROFILE_LEVEL"
client_snapshot_capabilities
client_run_headless "$PROMPT_CONTENT" "$SESSION_LOG"
client_run_tui "$INITIAL_PROMPT"
client_normalize_events "$SESSION_LOG"
client_cleanup
```

The adapter returns a small set of standard result variables:

- `CLIENT_EXIT_CODE`
- `CLIENT_DONE_SIGNALED`
- `CLIENT_COMPLETION_TEXT`
- `CLIENT_SESSION_ID`
- `CLIENT_RAW_LOG`
- `CLIENT_USAGE_JSON`

Existing Claude behavior can be represented as the first adapter:

- `client_run_headless`: current `claude --dangerously-skip-permissions -p`.
- `client_prepare_project`: current `.claude/settings.local.json` backup/write.
- `client_prepare_home`: current `setup-claude-config.sh`.
- `client_normalize_events`: initially emits only `agent.completed` plus current
  convergence events, then later parses Claude JSON output.

### Client Manifest

Keep the executable details data-driven where possible:

```toml
name = "opencode"
binary = "opencode"
home = "/home/agent/.config/opencode"
project_config_dir = ".opencode"
instructions = ["AGENTS.md"]
event_format = "opencode-json"

[headless]
argv = ["opencode", "run", "--format", "json", "--dir", "{repo}", "--model", "{model}", "{prompt}"]

[tui]
argv = ["opencode", "{repo}"]

[capabilities]
json_events = true
stream_json = true
acp = true
mcp = true
native_permissions = true
native_agents = true
```

Do not overfit this manifest too early. The first pass can be a documented
contract and hardcoded shell adapters. Add TOML/JSON manifests once there are at
least two non-Claude clients.

### Normalized Event Schema

Each client should keep raw logs, then append normalized AgentMill events:

- `agent.started`
- `agent.completed`
- `agent.failed`
- `agent.message`
- `tool.invoked`
- `tool.completed`
- `tool.failed`
- `mcp.tool.invoked`
- `mcp.tool.completed`
- `usage.recorded`
- `policy.requested`
- `policy.allowed`
- `policy.denied`
- `file.changed`

Client-specific raw event names should remain inside payloads:

```json
{
  "type": "tool.completed",
  "payload": {
    "client": "opencode",
    "raw_type": "tool_result",
    "tool_name": "bash",
    "duration_ms": 1234
  }
}
```

Acceptance should be fixture-driven. Add static fake logs for Claude, Codex,
OpenCode, Qwen, and Gemini, then test that each normalizer produces the same
AgentMill event family.

### Policy Intermediate Representation

AgentMill profiles should compile into a policy IR before being projected into
client-specific config:

```json
{
  "profile": "standard",
  "permissions": {
    "read": "allow",
    "edit": "allow",
    "shell": {"*": "ask", "git status *": "allow", "git push *": "deny"},
    "webfetch": "deny",
    "websearch": "deny",
    "mcp": {"BrightData": "allow", "*": "deny"},
    "subagent": "ask",
    "external_directory": "deny"
  },
  "network": {"default": "deny", "allow_domains": []},
  "host_config": "deny",
  "project_config": "deny"
}
```

Then each adapter translates that IR:

- Claude: `.claude/settings.local.json` allow/deny/defaultMode plus external
  AgentMill hooks.
- OpenCode: `opencode.json` `permission`, `agent`, `mcp`, and
  `enabled_providers`/`disabled_providers`.
- Qwen/Gemini: `settings.json` approval mode, tool excludes/allowlists, MCP
  settings, sandbox flags, and SDK permission callbacks if using SDK.
- Codex: `config.toml`, rules, sandbox, approval policy, MCP, hooks, and shell
  environment policy.

Native client permissions are useful, but not sufficient. AgentMill should keep
outer Docker isolation, high-risk change checks, hook vetoes, finite budgets,
event audit, and future egress policy.

### Instruction and Skill Mapping

Adopt `AGENTS.md` and `.agents/skills` as the shared instruction layer:

- Claude: keep `CLAUDE.md`; optionally generate/sync a short `AGENTS.md`.
- Codex: use `AGENTS.md` and `.agents/skills`.
- OpenCode: use `AGENTS.md`, `.opencode/agents`, and `.agents/skills`.
- Qwen: generate or point to `QWEN.md`/context settings from shared
  `AGENTS.md`, and allow `.qwen/skills` only when trusted.
- Gemini: generate or point to `GEMINI.md`/settings from shared `AGENTS.md`.

Do not copy large prompt bodies into every client-specific file. Keep the
client-local files as maps to `README.md`, `TASK.md`, `docs/`, `prompts/`, and
role profiles.

### Config and Secret Isolation

Each adapter should have an isolated home under the container, for example:

- `/home/agent/.agentmill/clients/claude`
- `/home/agent/.agentmill/clients/codex`
- `/home/agent/.agentmill/clients/opencode`
- `/home/agent/.agentmill/clients/qwen`
- `/home/agent/.agentmill/clients/gemini`

Host config import should be profile-gated:

- `trusted`: may mount/import host config and auth for the selected client.
- `standard`: generated config only, selected MCP allowlist only, no broad host
  auth cache.
- `untrusted`: generated config only, no project-local client config, no host
  config, finite budget required.

Never pass all possible client credentials into all containers by default.
Only the selected adapter should receive its credential variables, and spawned
agent shell commands should not inherit model credentials when the client
supports environment filtering.

## Candidate Adapter Priority

1. Wrap current Claude behavior behind the adapter contract. This creates the
   seam without changing runtime behavior.
2. Implement a fake adapter for tests. It should read a prompt, optionally emit
   a normalized fake tool event, touch the done file, and exit. This proves the
   harness is no longer coupled to a real AI client.
3. Add OpenCode. It gives the biggest genericity payoff because it supports raw
   JSON events, server mode, ACP, granular permissions, agents, skills, MCP, and
   many model providers.
4. Add Codex or Qwen next depending on operator priority:
   - Codex if the goal is OpenAI-native telemetry and `codex exec --json`.
   - Qwen if the goal is open-source/local or Qwen-family clients.
5. Add Gemini after Qwen by reusing the Qwen/Gemini-family JSON normalizer.
6. Add ACP transport support for `mill shell` and `mill watch`.

## Implementation Phases

### Phase 0 - Contract and Naming

Deliverables:

- Add this generic client plan.
- Add `AGENTMILL_CLIENT` docs.
- Keep `AGENTMILL_PROVIDER` as a deprecated alias only if needed by the Codex
  work.
- Add a `client` field to `logs/events.jsonl` payloads where relevant.
- Rename future generic events from `claude.completed` to `agent.completed`
  while keeping old event names for compatibility during transition.

Acceptance evidence:

- `AGENTMILL_CLIENT` is documented in README, `.env.example`, and `TASK.md`.
- Existing Claude tests still pass.
- `rg -n "claude.completed"` shows only compatibility shims/tests.

### Phase 1 - Claude Adapter, No Behavior Change

Deliverables:

- Add shell adapter functions and route current Claude paths through them.
- Keep exact existing Claude invocation, auth, settings, and model resolution.
- Replace direct calls in `entrypoint.sh` and `entrypoint-tui.sh` with adapter
  calls.

Acceptance evidence:

- Current shell tests pass.
- A real or fake Claude smoke run behaves as before.
- `entrypoint.sh` no longer invokes `claude` directly outside the Claude
  adapter.

### Phase 2 - Fake Client and Parser Fixtures

Deliverables:

- Add `AGENTMILL_CLIENT=fake` for tests only.
- Add raw event fixtures and normalizer tests.
- Prove loop, completion, hooks, commit, and events work without Claude.

Acceptance evidence:

- Fake client can create a file, touch `$DONE_FILE`, and let the harness commit
  changes.
- Tests cover nonzero client exit, malformed JSON events, and missing done
  signal.

### Phase 3 - OpenCode Adapter

Deliverables:

- Install/pin OpenCode.
- Generate isolated `opencode.json`.
- Implement `opencode run --format json`.
- Normalize raw JSON events.
- Map AgentMill profiles to OpenCode permissions.
- Support `opencode` TUI for `mill shell` and `opencode acp` as an experimental
  watch/shell transport.

Acceptance evidence:

- `opencode --version` and `opencode run --format json` smoke tests pass in the
  image.
- Standard profile denies or asks for high-risk shell commands through native
  permissions and AgentMill hooks.
- OpenCode raw JSON fixture normalizes to AgentMill events.

### Phase 4 - Qwen/Gemini-Family Adapter

Deliverables:

- Add Qwen Code and optionally Gemini CLI installation pins.
- Generate isolated `.qwen/settings.json` and `.gemini/settings.json`.
- Invoke `qwen -p ... --output-format stream-json` and
  `gemini -p ... --output-format stream-json` where supported.
- Normalize response/stats/tool events.
- Decide whether to use CLI subprocess directly or Qwen's Python SDK for
  permission callbacks.

Acceptance evidence:

- Fixture tests prove Qwen/Gemini JSON outputs produce `usage.recorded` and
  `tool.*` events.
- Startup fails closed if a requested sandbox/profile cannot be enforced.
- Host/project config import is disabled outside trusted runs.

### Phase 5 - ACP Transport

Deliverables:

- Add an ACP subprocess bridge for clients that implement it.
- Use ACP for interactive/watch sessions before using it for headless loops.
- Normalize ACP `session/update`, permission requests, file operations, and
  terminal operations into AgentMill events.

Acceptance evidence:

- `mill shell` can start an ACP-capable client and exchange one prompt.
- Permission requests become AgentMill policy events.
- Unsupported ACP capabilities are detected during initialization and reported
  clearly.

## Risks

- Native event schemas are not stable across clients. Pin versions and keep raw
  fixture tests per client release.
- OpenCode defaults are permissive; generated permissions must be explicit.
- Qwen/Gemini `--yolo` style automation may enable or imply inner sandboxing,
  which can conflict with AgentMill's hardened Docker container.
- Client-owned MCP and skills can bloat context or leak secrets. Generate
  allowlisted config instead of forwarding everything.
- Project-local `.opencode`, `.qwen`, `.gemini`, `.codex`, or `.claude` config
  can be attacker-controlled in untrusted repos. Load project config only when
  the profile permits it.
- Credentials differ by client and may be stored in auth caches. Mount only the
  selected client's secret material, and only in trusted mode until isolation is
  stronger.
- ACP is promising, but it is not the simplest path for deterministic
  autonomous loops. Do not block headless adapters on ACP.

## Source Set

- OpenCode CLI: <https://dev.opencode.ai/docs/cli/>
- OpenCode config: <https://opencode.ai/docs/config>
- OpenCode permissions: <https://opencode.ai/docs/permissions>
- OpenCode agents: <https://opencode.ai/docs/agents>
- OpenCode MCP: <https://opencode.ai/docs/mcp-servers>
- OpenCode ACP: <https://dev.opencode.ai/docs/acp/>
- OpenCode SDK/server: <https://dev.opencode.ai/docs/sdk/>
- OpenCode skills: <https://opencode.ai/docs/skills/>
- Qwen Code GitHub: <https://github.com/QwenLM/qwen-code>
- Qwen Code headless: <https://qwenlm.github.io/qwen-code-docs/en/users/features/headless/>
- Qwen Code settings: <https://qwenlm.github.io/qwen-code-docs/en/users/configuration/settings/>
- Qwen Code MCP: <https://qwenlm.github.io/qwen-code-docs/en/users/features/mcp/>
- Qwen Code approval mode:
  <https://qwenlm.github.io/qwen-code-docs/en/users/features/approval-mode/>
- Qwen Code sandbox: <https://qwenlm.github.io/qwen-code-docs/en/users/features/sandbox/>
- Qwen Code Python SDK: <https://qwenlm.github.io/qwen-code-docs/en/developers/sdk-python/>
- Gemini CLI headless:
  <https://google-gemini.github.io/gemini-cli/docs/cli/headless.html>
- Gemini CLI configuration:
  <https://google-gemini.github.io/gemini-cli/docs/get-started/configuration.html>
- Gemini CLI MCP:
  <https://google-gemini.github.io/gemini-cli/docs/tools/mcp-server.html>
- ACP overview: <https://agentclientprotocol.com/protocol/overview>
- ACP transports: <https://agentclientprotocol.com/protocol/transports>
- Existing AgentMill Codex plan: `docs/CODEX_INTEGRATION_PLAN.md`
