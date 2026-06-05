<p align="center">
  <img src="assets/agentmill.png" alt="AgentMill" width="200">
</p>

<h1 align="center">AgentMill</h1>

<p align="center">
  A Docker harness that runs AI coding clients in a respawning loop.<br>
  Point it at a repo and a prompt — it works, audits, commits when allowed, and repeats.<br>
  <strong>Tasks go in, code comes out.</strong>
</p>

<p align="center">
  <a href="https://github.com/kurcontko/agentmill/actions/workflows/ci.yml"><img src="https://github.com/kurcontko/agentmill/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/kurcontko/agentmill/actions/workflows/security-scan.yml"><img src="https://github.com/kurcontko/agentmill/actions/workflows/security-scan.yml/badge.svg" alt="Security Scan"></a>
  <a href="https://github.com/kurcontko/agentmill/actions/workflows/codeql.yml"><img src="https://github.com/kurcontko/agentmill/actions/workflows/codeql.yml/badge.svg" alt="CodeQL"></a>
  <a href="https://sonarcloud.io/summary/overall?id=kurcontko_agentmill"><img src="https://sonarcloud.io/api/project_badges/measure?project=kurcontko_agentmill&metric=security_rating" alt="Security Rating"></a>
  <a href="https://sonarcloud.io/summary/overall?id=kurcontko_agentmill"><img src="https://sonarcloud.io/api/project_badges/measure?project=kurcontko_agentmill&metric=reliability_rating" alt="Reliability Rating"></a>
  <a href="https://github.com/kurcontko/agentmill/actions/workflows/scorecard.yml"><img src="https://github.com/kurcontko/agentmill/actions/workflows/scorecard.yml/badge.svg" alt="OpenSSF Scorecard"></a>
</p>

## Quick Start

1. **Configure** — copy `.env.example` to `.env`, set `REPO_PATH` and auth
2. **Write your prompt** — edit `prompts/PROMPT.md` with the task
3. **Preflight** — run `./mill doctor` and fix any `ERROR` lines
4. **Run** — pick a mode below
5. **Stop** — `docker compose down` or `./mill stop --on-converge` for a graceful stop after the completion gate passes

```bash
cp .env.example .env   # then edit REPO_PATH and auth
nano prompts/PROMPT.md  # describe the task
./mill doctor
```

To use the published container image when it is available, run:

```bash
./mill build --pull
```

## Authentication

Set one of these in `.env`:

- **API Key** — set `ANTHROPIC_API_KEY`
- **OAuth Token** — run `claude setup-token` on the host, set `CLAUDE_CODE_OAUTH_TOKEN`

For non-Claude clients, set the provider credential the client expects, such as
`CODEX_API_KEY` or `OPENAI_API_KEY` for Codex, `DASHSCOPE_API_KEY` or
`OPENAI_API_KEY` for Qwen Code, and `GEMINI_API_KEY`, `GOOGLE_API_KEY`, or
Vertex AI environment for Gemini CLI.

For Codex subscription auth, run `codex login` on the host. AgentMill mounts
host `~/.codex` read-only at `/home/agent/.host-codex` and copies `auth.json`
into the isolated Codex home only for trusted-profile runs. Standard and
untrusted runs should use `CODEX_API_KEY`, `OPENAI_API_KEY`, or
`CODEX_ACCESS_TOKEN` instead.

For GitHub Actions PR review with Claude Code and DeepSeek, see
[`docs/claude-code-github-actions.md`](docs/claude-code-github-actions.md).

## How to Run

Pick the mode that fits your workflow:

---

### 1. `headless` — fire and forget

Claude runs in a loop in the background. No UI — output goes to `./logs/`. Restarts automatically on crash. Best for CI, overnight runs, or when you don't need to watch.

```bash
REPO_PATH=/path/to/repo docker compose up headless

# Use REPO_PATH from .env, or pass /path/to/repo to override it
./mill run --agent coder --iterations 3
```

Loop: pull → run Claude → commit → push → wait → repeat.

For unattended headless runs, wait for a completion gate before stopping
containers:

```bash
./mill stop --on-converge --timeout 3600 --run-id "$AGENTMILL_RUN_ID"
```

---

### 2. `exec` — one bounded iteration

Run exactly one headless iteration and exit. It uses the same profiles, hooks,
events, workspace isolation, high-risk gates, and commit policy as `run`, but
forces `MAX_ITERATIONS=1` and uses a one-off container.

```bash
./mill exec /path/to/repo --agent reviewer
```

---

### 3. `watch` — autonomous TUI, you observe

Full selected-client TUI in your terminal. The agent works autonomously under
the active profile policy while you watch file edits, tool calls, and reasoning
in real time. You're an observer, not a driver.

```bash
# Single autonomous session, then exit
REPO_PATH=/path/to/repo docker compose run watch

# With Ralph loop — bounded iteration (runs up to N times, then stops)
REPO_PATH=/path/to/repo AUTO_RALPH=true AUTO_RALPH_MAX_ITERATIONS=10 \
  docker compose run watch

# With respawn — restart Claude automatically after each session
REPO_PATH=/path/to/repo RESPAWN=true docker compose run watch
```

---

### 4. `interactive` — you drive

Plain selected-client TUI. No prompt injected, no automation. You type, the
client responds. Same idea as running the client locally, but inside the
container with the repo and tools already set up.

```bash
REPO_PATH=/path/to/repo docker compose run interactive
```

---

### 5. `agent-1`, `agent-2`, `agent-3` — parallel workers

Multiple headless agents on the same repo. Each pushes to its own branch (`agent-1`, `agent-2`, etc.) and rebases on conflict. Assign different prompts for different roles.

```bash
# Two agents, different tasks
PROMPT_FILE_1=/prompts/features.md PROMPT_FILE_2=/prompts/tests.md \
  REPO_PATH=/path/to/repo docker compose up agent-1 agent-2

# Two agents, role profiles
./mill multi /path/to/repo --roles researcher-breadth,researcher-depth

# Three agents, same branch (rebase on conflict)
AGENT_BRANCH=main REPO_PATH=/path/to/repo docker compose up agent-1 agent-2 agent-3
```

## Agent Profiles

Profiles in `agents/<role>.toml` turn prompts and safety defaults into a
first-class run surface. Inspect them with:

```bash
./mill profiles
./mill profiles researcher-depth
```

Built-in roles:

- `coder`
- `reviewer`
- `researcher-breadth`
- `researcher-depth`
- `researcher-redteam`
- `refactor`
- `memory-curator`

Profiles can set the prompt, model, branch pattern, max iterations, wall-clock
limit, log-size limit, profile level, commit mode, completion gate, verifier
command, network label, and MCP allowlist. Non-empty env values from `.env` or
the shell win over profile defaults, and CLI flags win over both.
See `docs/PROFILES.md` for the full field list.
See `docs/AGENTS.md` for the role-contract patterns borrowed from OpenClaw and
the larger agent patterns intentionally left out.

## Workspace Isolation

`mill run` and `mill watch` auto-select `readonly-clone` workspace mode for
`standard` and `untrusted` profiles. In that mode the target repo is mounted at
`/workspace/upstream:ro`, AgentMill works in a container-local clone, and
changes are exported to `logs/patches/<run-id>-<agent>-iterN/` instead of being
pushed into the mounted host repo. Use `--workspace-mode direct` only for
trusted work, or set `AGENTMILL_ALLOW_DIRECT_HOST_REPO=true` to override the
guard explicitly.

Git branch policy also runs before headless/watch work starts. If
`AGENT_BRANCH` is set, the current branch must match it. Standard/untrusted
direct writes to protected branches such as `main` and `master` are denied
unless the run is in `readonly-clone` mode or
`AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES=true` is set. TUI sessions honor
`AUTO_COMMIT`; non-trusted profiles default to `off`. Headless push/rebase
attempts also pass through a remote-action policy that validates the ref,
requires the current branch to match the push branch, protects configured
branches, denies force-push unless explicitly enabled, and applies
`AGENTMILL_GIT_REMOTE_ALLOWLIST` to network `origin` remotes. When
`AGENTMILL_NETWORK=deny`, harness-managed fetch/rebase/push to network remotes
is blocked unless `AGENTMILL_ALLOW_GIT_NETWORK=true`; local remotes such as the
read-only clone upstream are not treated as egress. When launched through
`mill`, `AGENTMILL_NETWORK=deny` also applies a Docker Compose override with
`network_mode: none` to the selected service. `AGENTMILL_NETWORK=allowlist`
attaches selected services to an internal Docker network and routes proxy-aware
HTTP(S) traffic through an AgentMill egress proxy that only connects to
`AGENTMILL_EGRESS_ALLOWLIST`; the proxy rejects private, loopback, link-local,
and other non-public targets even when listed.

Apply read-only clone output deliberately from the host:

```bash
./mill patches
./mill apply "$(./mill patches --latest)" /path/to/repo --branch agent-review
```

## Doctor

Run `./mill doctor [repo]` before long-running work. It checks auth, Docker,
repo state, prompt resolution, profile and budget settings, MCP forwarding,
high-risk change policy, hooks, `.env` schema, model/version compatibility,
latest MCP manifest reachability, and the host Claude CLI.
`./mill doctor --fix` creates starter local files and directories such as
`.env`, `prompts/`, `logs/`, `memory/`, and `hooks/`.

## CI

CI is intentionally small and split into focused gates. See
[`docs/CI.md`](docs/CI.md) for the workflow layout and the OpenClaw patterns
that were adapted here.

## Configuration

**All modes:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `REPO_PATH` | *(required unless passed)* | Absolute path to the repo on your host; `mill run/exec/watch/multi/shell [repo]` can override it |
| `ANTHROPIC_API_KEY` | — | API key auth |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | OAuth token auth (alternative to API key) |
| `AGENTMILL_CLIENT` | `claude` | Client executable (`claude`, `codex`, `opencode`, `qwen`, `gemini`; `fake` is test-only) |
| `AGENTMILL_PROVIDER` | — | Deprecated compatibility alias for early client selection; provider names are reserved for model backends |
| `AGENTMILL_CLIENT_TRANSPORT` | `native` | Client transport (`native` or experimental `acp` for `opencode`/`qwen` watch and shell) |
| `AGENTMILL_ACP_PROMPT` | — | Optional one-turn prompt for experimental ACP transport |
| `AGENTMILL_CLIENT_HOME_ROOT` | `$HOME/.agentmill/clients` | Root for isolated selected-client config homes |
| `AGENTMILL_CLIENT_HOME` | — | Absolute override for the selected client's generated config home |
| `AGENTMILL_OPENCODE_COMMAND` | `opencode` | OpenCode binary path/command for `AGENTMILL_CLIENT=opencode` |
| `AGENTMILL_OPENCODE_REQUIRE_AUTH` | `true` | Require a known provider key or auth file before OpenCode runs |
| `AGENTMILL_CODEX_COMMAND` | `codex` | Codex CLI binary path/command for `AGENTMILL_CLIENT=codex` |
| `AGENTMILL_CODEX_REQUIRE_AUTH` | `true` | Require Codex/OpenAI env or trusted Codex auth before Codex runs |
| `AGENTMILL_CODEX_DEFAULT_MODEL` | `gpt-5.3-codex` | Model used when `MODEL` is still a Claude alias |
| `AGENTMILL_CODEX_SANDBOX` | profile-derived | Optional legacy Codex sandbox override (`read-only`, `workspace-write`, `danger-full-access`); when empty AgentMill writes a generated Codex permission profile |
| `AGENTMILL_CODEX_APPROVAL_POLICY` | profile-derived | Optional Codex approval override; defaults to `never` for `trusted` and `untrusted` for `standard`/`untrusted` |
| `AGENTMILL_HOST_CODEX_HOME` | `/home/agent/.host-codex` | Container path for read-only mounted host `~/.codex`; `auth.json` is copied only for trusted-profile Codex runs |
| `AGENTMILL_QWEN_COMMAND` | `qwen` | Qwen Code binary path/command for `AGENTMILL_CLIENT=qwen` |
| `AGENTMILL_QWEN_REQUIRE_AUTH` | `true` | Require provider env or Qwen config/cache before Qwen runs |
| `AGENTMILL_QWEN_OUTPUT_FORMAT` | `stream-json` | Qwen headless output mode (`text`, `json`, `stream-json`) |
| `AGENTMILL_QWEN_INCLUDE_PARTIAL_MESSAGES` | `false` | Include partial stream chunks when Qwen uses `stream-json` |
| `AGENTMILL_QWEN_DEFAULT_MODEL` | `qwen3-coder-plus` | Model used when `MODEL` is still a Claude alias |
| `AGENTMILL_QWEN_SANDBOX` | — | Optional `QWEN_SANDBOX` override (`true`, `false`, `docker`, `podman`, `sandbox-exec`) |
| `AGENTMILL_GEMINI_COMMAND` | `gemini` | Gemini CLI binary path/command for `AGENTMILL_CLIENT=gemini` |
| `AGENTMILL_GEMINI_REQUIRE_AUTH` | `true` | Require Gemini/Google env or Gemini config/cache before Gemini runs |
| `AGENTMILL_GEMINI_OUTPUT_FORMAT` | `json` | Gemini headless output mode (`text`, `json`) |
| `AGENTMILL_GEMINI_DEFAULT_MODEL` | `gemini-2.5-flash` | Model used when `MODEL` is still a Claude alias |
| `AGENTMILL_GEMINI_SANDBOX` | — | Optional `GEMINI_SANDBOX` override (`true`, `false`, `docker`, `podman`, `sandbox-exec`) |
| `MODEL` | `sonnet` | Model requested from the selected client (`sonnet`, `opus`, etc. for Claude) |
| `AGENTMILL_ROLE` | — | Role name selected by `--agent` or `--roles` |
| `AGENTMILL_PROFILE_LEVEL` | `trusted` | `trusted`, `standard`, or `untrusted`; controls generated Claude settings and MCP forwarding defaults |
| `AGENTMILL_RUN_ID` | auto | Stable run identifier written to `logs/events.jsonl` |
| `AGENTMILL_NETWORK` | — | Optional network policy (`allow`, `allowlist`, `deny`); `deny` disables Docker networking and `allowlist` routes proxy-aware HTTP(S) through the egress proxy for `mill`-launched services |
| `AGENTMILL_EGRESS_ALLOWLIST` | — | Comma-separated proxy target allowlist for `AGENTMILL_NETWORK=allowlist`, e.g. `api.anthropic.com,github.com,*.githubusercontent.com` |
| `AGENTMILL_EGRESS_PROXY_PORT` | `18080` | Internal proxy listen port used for `AGENTMILL_NETWORK=allowlist` |
| `AGENTMILL_FORWARD_HOST_MCP` | — | Set `true` to forward host/project MCP servers outside `trusted` |
| `AGENTMILL_FORWARD_HOST_TOOLS` | — | Set `true` to merge host `allowedTools` outside `trusted`; host `defaultMode` is never allowed to weaken the profile |
| `AGENTMILL_FORWARD_HOST_HOOKS` | — | Set `true` to merge host Claude hooks outside `trusted` |
| `AGENTMILL_FORWARD_HOST_ENV` | — | Set `true` to merge host Claude env settings outside `trusted` |
| `AGENTMILL_FORWARD_HOST_EXTENSIONS` | — | Set `true` to copy host plugins, agents, commands, and allowlisted skills outside `trusted` |
| `AGENTMILL_MCP_ALLOWLIST` | — | Comma-separated MCP servers allowed for standard/untrusted profiles |
| `AGENTMILL_MCP_MANIFEST_LOCK` | `true` | For standard/untrusted profiles, deny the next iteration if MCP config changes after startup |
| `AGENTMILL_MCP_TOOL_SNAPSHOT` | `true` | Include live stdio MCP `tools/list` names plus description/schema hashes in the manifest lock when available |
| `AGENTMILL_MCP_TOOL_SNAPSHOT_TIMEOUT_SECONDS` | `3` | Timeout for each live MCP tool metadata snapshot |
| `AGENTMILL_DOCTOR_REQUIRE_MCP_REACHABLE` | `false` | Make `mill doctor` fail when latest MCP manifest stdio commands are not reachable on PATH |
| `AGENTMILL_SKILL_ALLOWLIST` | — | Comma-separated host skill directory names allowed for standard/untrusted profiles |
| `AGENTMILL_HOOK_DIR` | `/hooks` | Harness-owned hook directory inside the container |
| `AGENTMILL_HOOK_TIMEOUT_SECONDS` | `30` | Timeout for each hook script |
| `AGENTMILL_HOOK_CONTEXT_MAX_BYTES` | `16384` | Maximum `pre_iteration` hook `additional_context` bytes injected into the next prompt |
| `AGENTMILL_ALLOW_HIGH_RISK_CHANGES` | `false` | Permit standard/untrusted runs to commit high-risk files such as workflows, MCP config, env files, package scripts, Makefiles, container config, deploy scripts, or auth/secret paths |
| `AGENTMILL_WORKSPACE_MODE` | `auto` | `auto`, `direct`, or `readonly-clone`; `mill run/watch` use read-only clone mode for standard/untrusted profiles |
| `AGENTMILL_ALLOW_DIRECT_HOST_REPO` | `false` | Explicitly permit standard/untrusted direct writable host repo mounts |
| `AGENTMILL_READ_ONLY_ROOTFS` | `true` | Run containers with a read-only root filesystem; scratch/home/workspace staging use tmpfs |
| `AGENTMILL_WRITE_ROOTS` | — | Optional comma-separated repo-relative durable write roots; projected into Claude PreToolUse, Codex permission profiles, and a Bubblewrap filesystem sandbox for OpenCode/Qwen/Gemini; standard/untrusted runs also deny auto-commit/push when changed files fall outside them |
| `AGENTMILL_WRITE_ROOT_SANDBOX` | `auto` | `auto`, `bwrap`, or `off`; controls Bubblewrap write-root enforcement for clients without native write-root policy |
| `AGENTMILL_BWRAP_COMMAND` | `bwrap` | Bubblewrap command used for non-native client write-root sandboxing |
| `AGENTMILL_PRETOOL_POLICY_COMMAND` | `/agentmill-pretool-policy.py` | Claude `PreToolUse` hook command for AgentMill tool policy |
| `AGENTMILL_SHELL_ALLOWLIST` | — | Comma-separated shell permission patterns to allow; projected into Claude `Bash(...)`, Codex execpolicy rules, supported native client settings, and headless audit |
| `AGENTMILL_SHELL_DENYLIST` | — | Extra comma-separated shell permission patterns to deny in Claude PreToolUse, Codex execpolicy rules, supported native client settings, and audit |
| `AGENTMILL_ALLOW_SHELL_NETWORK` | `false` | Allow curl/wget/nc-style Bash network clients outside trusted profiles |
| `AGENTMILL_PROTECTED_BRANCHES` | `main,master,trunk,release,production` | Comma-separated branch names protected from standard/untrusted direct writes |
| `AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES` | `false` | Explicitly permit standard/untrusted direct writes to protected branches |
| `AGENTMILL_ALLOW_FORCE_PUSH` | `false` | Explicitly permit force-push policy checks; AgentMill does not force-push by default |
| `AGENTMILL_ALLOW_MERGE_COMMITS` | `false` | Explicitly permit standard/untrusted iterations to introduce merge commits |
| `AGENTMILL_GIT_REMOTE_ALLOWLIST` | — | Comma-separated network git remote allowlist for harness-managed fetch/rebase/push, e.g. `github.com/org/repo` |
| `AGENTMILL_ALLOW_GIT_NETWORK` | `false` | Permit harness-managed git network remotes when `AGENTMILL_NETWORK=deny` |
| `PROMPT_FILE` | `/prompts/PROMPT.md` | Prompt file path inside the container |
| `GIT_USER` | `agentmill` | Git commit author name |
| `GIT_EMAIL` | `agent@agentmill` | Git commit author email |
| `AUTO_SETUP` | `true` | Auto-detect and install repo dependencies on start |
| `AUTO_SETUP_LANGUAGES` | `all` | `all` or comma-separated setup detectors: `make,python,node,go,rust` |
| `REPO_SETUP_COMMAND` | — | Custom bootstrap command (overrides auto-detect) |
| `EXTRA_PYTHON_TOOLS` | — | Additional pip packages to install (e.g. `ruff pytest`) |

**Headless / multi-agent only:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `MAX_ITERATIONS` | `0` (infinite) | Stop after N loop iterations |
| `MAX_WALL_SECONDS` | `0` | Stop after N wall-clock seconds; standard/untrusted unbounded loops require this or `MAX_ITERATIONS` |
| `MAX_LOG_BYTES` | `0` | Stop after logs under `./logs` reach this many bytes |
| `MAX_TOTAL_TOKENS` | `0` | Stop after cumulative parsed usage reaches this many tokens |
| `MAX_TOTAL_USD` | `0` | Stop after cumulative parsed usage reaches this estimated USD cost |
| `AGENTMILL_COST_INPUT_PER_MTOKENS` | `0` | Optional cost-estimator rate per 1M input tokens when the client does not emit `cost_usd` |
| `AGENTMILL_COST_OUTPUT_PER_MTOKENS` | `0` | Optional cost-estimator rate per 1M output and reasoning tokens |
| `AGENTMILL_COST_CACHE_CREATION_PER_MTOKENS` | `0` | Optional cost-estimator rate per 1M cache-write tokens |
| `AGENTMILL_COST_CACHE_READ_PER_MTOKENS` | `0` | Optional cost-estimator rate per 1M cache-read tokens |
| `AGENTMILL_CLAUDE_OUTPUT_FORMAT` | `text` | `text`, `json`, or `stream-json`; JSON modes let AgentMill parse Claude usage telemetry when supported |
| `AGENTMILL_VERIFIER_COMMAND` | — | Shell command required by `coder_verified` and `refactor_verified`; completion is rejected if it is missing or exits nonzero |
| `AGENTMILL_CODER_OPEN_QUESTIONS_MAX` | `0` | Coder gate limit for unresolved bullets in `memory/open_questions.md` |
| `AGENTMILL_REFACTOR_LOC_TARGET` | — | Optional signed net line-delta target for `refactor_verified`, measured against the run base |
| `AGENTMILL_REFACTOR_LOC_TOLERANCE` | `0` | Non-negative tolerance around `AGENTMILL_REFACTOR_LOC_TARGET` |
| `AGENTMILL_REFACTOR_MAX_LOC_DELTA` | `0` | Refactor fallback when no target is set; default rejects net LOC growth |
| `AGENTMILL_RESEARCH_SATURATION_ITERATIONS` | `3` | Research gate streak: consecutive `results.tsv` rows with `sources_added=0` required for completion |
| `AGENTMILL_RESEARCH_OPEN_QUESTIONS_MAX` | `0` | Research gate limit for unresolved bullets in `memory/open_questions.md` |
| `LOOP_DELAY` | `5` | Seconds between iterations |
| `AUTO_COMMIT` | `wip` | `wip` = commit uncommitted changes as safety net, `on` = always commit, `off` = never |
| `AGENT_BRANCH` | auto | Branch name for multi-agent (default: `agent-$ID`) |
| `PROMPT_FILE_1/2/3` | `PROMPT_FILE` | Per-agent prompt overrides (multi-agent only) |

**Watch / interactive only:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `RESPAWN` | `false` | Restart Claude automatically after each session |
| `LOOP_DELAY` | `5` | Seconds between respawns |
| `SKIP_PROMPT` | `false` | Skip prompt injection (set automatically for `interactive`) |
| `AUTO_RALPH` | `false` | Auto-start Ralph loop for bounded autonomous iteration |
| `AUTO_RALPH_MAX_ITERATIONS` | `10` | Max Ralph loop iterations |
| `AUTO_RALPH_COMPLETION_PROMISE` | `TASK_COMPLETE` | Token that signals task completion to Ralph |

## Auto-Setup

When `AUTO_SETUP=true` (default), AgentMill bootstraps the repo's dev environment:

1. `REPO_SETUP_COMMAND` if set, otherwise:
2. `Makefile` with an `install` target → `make install`
3. `pyproject.toml` + `uv.lock` → `uv sync --frozen`
4. `pyproject.toml` + `poetry.lock` → `poetry install --no-interaction`
5. `pyproject.toml` alone → editable `pip install`
6. `requirements.txt` → `pip install -r requirements.txt`
7. Node lockfiles → `npm ci`, `pnpm install --frozen-lockfile`, or
   `yarn install --immutable`
8. `go.mod` → `go mod download`
9. `Cargo.toml` + `Cargo.lock` → `cargo fetch`

The `.venv/bin` is prepended to `PATH`, so tools like `pytest` and `ruff` are available to Claude.

Use `AUTO_SETUP_LANGUAGES=python,node` to restrict detection for large
monorepos. `REPO_SETUP_COMMAND` still overrides all detectors.

**Recommendation:** Add a `Makefile` to your upstream repo with an `install` target that sets up the full dev environment:

```bash
docker compose up headless
```

This keeps build logic in the repo where it belongs, and any setup — system deps, virtual envs, code generation — just works.

## Hackable By Design

AgentMill keeps the control plane in plain files:

- `agents/*.toml` for role defaults and trust policy
- `prompts/*.md` for task instructions
- `hooks/` for policy decisions and prompt shaping
- `memory/*.md` for durable shared notes
- `logs/events.jsonl`, `logs/results.tsv`, and `logs/usage.tsv` for audits
- `mill` for the CLI surface, with `python -m agentmill` as a thin wrapper

The harness favors append-only logs, shell-visible environment variables,
Docker Compose services, and small scripts over hidden state. That makes long
runs easier to inspect, patch, and resume when an agent gets interrupted.

## Volumes

| Host | Container | Purpose |
|------|-----------|---------|
| `./prompts` | `/prompts` | Agent prompt files |
| `./hooks` | `/hooks` | Read-only harness policy hooks |
| `./logs` | `/workspace/logs` | Session logs |
| `$REPO_PATH` | `/workspace/repo` or `/workspace/upstream` | Target repository |
| `~/.claude.json` | `/home/agent/.host-claude.json` | Host Claude config (read-only) |
| `~/.claude/settings.json` | `/home/agent/.claude/settings.host.json` | Host settings (read-only) |
| `~/.claude/skills` | `/home/agent/.host-skills` | Host skills staged read-only, then copied only for trusted or explicitly allowlisted runs |
| `~/.claude/agents` | `/home/agent/.host-agents` | Host agents staged read-only, then copied only for trusted or explicitly forwarded runs |
| `~/.claude/commands` | `/home/agent/.host-commands` | Host commands staged read-only, then copied only for trusted or explicitly forwarded runs |

Containers run with a read-only root filesystem by default. `/tmp`,
`/home/agent`, and `/workspace` are writable tmpfs scratch areas, while the
intended persistent host write roots are the mounted repo, `./logs`, and
`./memory`. Set `AGENTMILL_WRITE_ROOTS=src,tests` or a role profile
`write_roots = ["src", "tests"]` to scope Claude write/edit tools and Codex
permission-profile workspace writes. OpenCode, Qwen, and Gemini native or ACP
runs are wrapped in a Bubblewrap filesystem sandbox that mounts the repo
read-only except for those roots. If Bubblewrap cannot create the filesystem
sandbox, AgentMill fails closed instead of running that client unmediated.
Standard/untrusted auto-commit or push is also denied when repo changes escape
the configured roots.

Project-local `.claude/skills` and `.claude/agents` stay inside the mounted
repo. Host skills and agents are copied only into `/home/agent/.claude`, so
project-local definitions remain the repo override surface.

## Event Log

AgentMill appends structured audit events to `logs/events.jsonl`. Each line
includes `run_id`, `agent_id`, `profile`, `iteration`, `type`, timestamp, and a
redacted payload. Use it for CI, incident review, and long-running harness
debugging:

Headless session logs and shared `agent-*.log` files are also passed through
the same secret redaction policy before being written.
Completion-gate checks are also written to `logs/convergence.tsv` with the
gate name, pass/fail result, observed value, threshold, evidence, and hook
decision.
When headless Claude output contains JSON usage data, AgentMill records
`usage.recorded` events and appends per-iteration rows to `logs/usage.tsv`.
Set `AGENTMILL_CLAUDE_OUTPUT_FORMAT=json` or `stream-json` to request JSON
output from Claude Code on supported versions.
When JSON session logs contain tool calls, AgentMill emits `tool.*` and
`mcp.tool.*` events with tool names, ids, input keys, and input hashes. It does
not write full tool arguments or results into the event payload. The same
normalized stream is audited before auto-commit/push so standard/untrusted
profiles fail closed if observed web, MCP, subagent, or shell tool calls violate
the active policy.
Policy blocks, nonzero Claude exits, and push failures also emit
`iteration.failed` events so CI can detect failed iterations without parsing
human-readable descriptions.

```bash
./mill events --tail 20
./mill events --follow
./mill tail --json
python -m agentmill version --json
./mill run /path/to/repo --json --iterations 1
./mill status --json
./mill watch-status
./mill history --json --tail 10 --agent 1 --failed-only
./mill cost --by day
./mill report status /path/to/research
./mill metrics
./mill web --no-serve
./mill web --port 8000
./mill mcp list
./mill mcp test BrightData
./mill version --json
```

`mill run --json` writes only JSONL to stdout. Docker Compose and container
progress go to stderr, and the last stdout line is a `mill.run.completed`
event with the CLI exit code.

MCP configuration is snapshotted per run to
`logs/mcp-manifest-<run-id>-<agent-id>.json`; the event stream records the
manifest hash and server count. Snapshots include server names, source,
config hashes, transport kind, safe launch endpoint metadata, and when
available live stdio MCP `tools/list` names plus description/input-schema
hashes, not full arguments, env, descriptions, or schemas. For
standard/untrusted profiles,
`AGENTMILL_MCP_MANIFEST_LOCK=true` also records a baseline hash and refuses a
later iteration if host MCP wiring or snapshotted live tool metadata changes
mid-run. `mill mcp test NAME --require-reachable` and `mill doctor` can use the
latest snapshot to catch missing allowlisted servers, stdio launch commands, or
tool snapshot status before a long run.

## Memory

Shared memory lives in `./memory` as append-only markdown topics guarded by a
file lock. Topic files start with frontmatter containing `type`, `created`, and
`last_iteration`, followed by append-only entry records. Use `./mill memory` to
list topics, `./mill memory <topic>` to read one, `./mill memory --search
<text>` to search, `./mill memory dedup` to remove duplicate URL lines from
`sources.md`, and `./mill memory rotate` to archive the current working set
under `memory/archive/<timestamp>/`.
Iteration context filters memory by role: researcher profiles see research
topics, coder/refactor/reviewer profiles see decisions, failed approaches, and
open questions, and `memory-curator` sees all topics.

Create a research knowledge-base repo with:

```bash
./mill init --research "container escape CVEs"
```

That scaffolds `~/research/container-escape-cves/` with `TASK.md`,
`REPORT.md`, schema-backed `memory/*.md`, `logs/`, and a git repo.
Use `./mill report status ~/research/container-escape-cves` to audit current
source count, open questions, per-section citation counts, and recent
per-iteration section/source activity.

## Hooks

Hooks are optional executable scripts in `./hooks`, mounted read-only into the
container. Supported names are `pre_iteration.sh`, `post_iteration.sh`,
`on_complete.sh`, and `on_failure.sh`.
See `docs/HOOKS.md` for the JSON contract and scoped hook layout.

Hooks can be global or scoped. Global hooks live at `hooks/<name>.sh` and run
for every role. Profile hooks live at `hooks/profiles/<profile>/<name>.sh`.
Role hooks live at `hooks/roles/<role>/<name>.sh`. Matching hooks run in that
order; any deny, defer, timeout, malformed JSON, or non-zero exit stops the
side effect. Allowed `additional_context` from multiple scoped hooks is joined
and injected once. A `pre_iteration` hook may also return `prompt_file` to
switch to another file under `/prompts` for the current and following
iterations.

Each hook receives JSON on stdin. Empty stdout allows the action; JSON stdout
can return a decision:

```json
{"decision":"deny","reason":"workflow file changed without review"}
```

Valid decisions are `allow`, `deny`, and `defer`. Non-zero exit, malformed
JSON, timeout, `deny`, or `defer` fail closed for commit/push side effects.

## Apple Silicon

If a dependency lacks a Linux `arm64` wheel, build or force x86 emulation:

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose build
```
