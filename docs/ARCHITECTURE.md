# Architecture

## Overview

AgentMill is a Docker-native system for running Claude Code agents in an autonomous loop. The core design is a simple shell-based lifecycle that clones a repo, runs Claude, commits results, and repeats.

## Components

```
┌─────────────────────────────────────────────────────┐
│  Docker Container (node:20-slim + python3 + uv)     │
│                                                     │
│  entrypoint.sh          Main loop orchestrator      │
│  ├── setup-claude-config.sh   Config merging (jq)   │
│  ├── setup-repo-env.sh        Repo bootstrapping    │
│  └── auto-trust.exp           Trust dialog handler  │
│                                                     │
│  entrypoint-tui.sh      TUI dashboard mode          │
│                                                     │
│  /workspace/repo        Agent's working directory   │
│  /workspace/upstream    Multi-agent shared repo     │
│  /workspace/logs        Session logs                │
│  /prompts               Mounted prompt files        │
└─────────────────────────────────────────────────────┘
```

## Workspace Modes

### Mode 1: Single Agent (Direct Mount)

```
Host repo ──mount──> /workspace/repo
```

- Simplest mode. Agent works directly in the mounted repo.
- No sync overhead. Changes are immediately visible on host.
- Use case: one agent, one repo, full control.

### Mode 2: Multi-Agent (Independent Clones)

```
Host repo ──mount──> /workspace/upstream (read-only reference)
                     │
                     ├──clone──> /workspace/repo-1 (agent-1 branch)
                     ├──clone──> /workspace/repo-2 (agent-2 branch)
                     └──clone──> /workspace/repo-3 (agent-3 branch)
```

- Each agent gets its own clone and branch.
- Sync via `git push/pull` to the upstream mount.
- Conflict resolution: rebase with retry (up to 3 attempts).
- Use case: parallel agents on different tasks, same codebase.

### Mode 3: Multi-Agent (Pre-Created Worktrees)

```
Host creates worktrees ──mount each──> /workspace/repo per container
```

- Host creates git worktrees before starting containers.
- Each container sees its worktree as a direct mount (looks like Mode 1).
- No clone or sync overhead. Host manages branch topology.
- Use case: advanced setups where host controls branching strategy.

## Lifecycle

```
startup
  ├── check_auth()           Validate API key or OAuth token
  ├── setup-claude-config.sh Merge host MCP/plugin/settings config
  ├── git config             Set agent identity
  ├── setup_workspace()      Detect mode, clone/checkout as needed
  ├── setup-repo-env.sh      Bootstrap Python venv, install deps
  └── setup_autonomous_settings()  Override permissions for autonomy

loop (while !shutdown && !max_iterations)
  ├── run Claude (-p pipe mode, --dangerously-skip-permissions)
  ├── git add -A && git commit
  ├── push_with_retry() (multi-agent only)
  └── sleep LOOP_DELAY

shutdown
  ├── restore_settings()     Put back original settings.local.json
  └── exit
```

## Signal Handling

- **SIGTERM/SIGINT**: Sets `SHUTTING_DOWN=true`. Current Claude session completes, then loop exits.
- **EXIT trap**: Restores `settings.local.json` to its pre-run state.

## Config Merging

`setup-claude-config.sh` uses `jq` to merge host Claude configuration into the container:

1. **~/.claude.json**: MCP servers, project trust settings
2. **settings.json**: Permission allowlists, plugin configuration
3. **plugins/**: Copies plugin files, rewrites install paths from host to container paths

## Resource Limits

Docker Compose services have resource limits (configurable in docker-compose.yml):
- Memory: 4GB limit, 1GB reservation
- CPU: 2.0 cores limit, 0.5 cores reservation

## Healthcheck

The container includes a healthcheck that verifies the Claude node process is running:
```
pgrep -f "node.*claude"
```
Interval: 30s, Timeout: 10s, Retries: 3.
