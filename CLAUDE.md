# AgentMill

A Docker container that runs an AI agent CLI (`claude -p` or `codex exec`) in
a respawning loop. Fresh context each iteration; the target repo (PROGRESS.md +
git history) is the only memory.

## Commands

```bash
mill run                                   # loop on the repo containing the cwd
mill -C ~/myrepo run --agent codex --model gpt-5.2-codex --iterations 5
mill shell                                 # interactive shell in the container
mill logs                                  # follow this checkout's loop
mill stop / mill stop --all                # this checkout, or everything
mill init / build / ps                     # init writes MILL.md + user config

# Test / lint
bash tests/test_loop.sh && bash tests/test_mill.sh
shellcheck loop.sh mill tests/*.sh
```

## Architecture

```
loop.sh            # the whole framework: agent loop, stop conditions, ratchet
mill               # CLI wrapper — plain docker run (no compose)
Dockerfile         # node:22-slim + claude + codex + git/jq/python3/sudo
prompts/PROMPT.md  # framework prompt: one task per session, PROGRESS.md +
                   #   failed-approaches log, TASK_COMPLETE when the mission is done
<repo>/MILL.md     # the mission (body, spliced into the prompt each iteration)
                   #   + frontmatter `key: value` settings (lowercase env names)
tests/test_loop.sh # smoke tests with a stubbed CLI (no network, no docker)
tests/test_mill.sh # smoke tests for the CLI with a stubbed docker
logs/<container>/  # per-checkout logs: results.jsonl + iter-N-<sha>.log
```

## Key patterns

- **Respawning loop**: fresh context per iteration; carry-forward is only a
  preamble (recent commits + head of PROGRESS.md).
- **Agent commits its own work**; the loop safety-nets leftovers as `[wip]`.
- **Ratchet**: `CHECK_CMD` failure reverts the iteration (`git reset --hard` +
  `git clean`), including initialized submodules recursively and including
  after an agent error or timeout. Repository-status errors are fatal, so the
  loop never mistakes an unreadable checkout for a clean one. The loop
  therefore refuses to start on a dirty worktree.
- **Stop conditions**: `DONE_PROMISE` in the final message, `MAX_ITERATIONS`,
  `MAX_NOOPS`, `MAX_ERRORS` (exponential backoff capped by `MAX_BACKOFF`),
  `ITER_TIMEOUT` per session. TERM/INT is forwarded to the agent's process
  group; both timeout expiry and an
  external shutdown escalate the agent's whole descendant process group to
  SIGKILL after `SHUTDOWN_GRACE`. `mill stop`
  gives the loop that grace period plus a cleanup window before Docker can
  escalate, so checkpoint/check/revert completes before removal. Inter-
  iteration sleeps are interruptible, so no new session starts after a signal.
- **Parallelism**: no framework code — one git worktree per agent, run mill
  twice. `mill` canonicalizes each checkout before naming it and mounts it at
  that same absolute host path, so initialized submodule `gitdir:` pointers
  remain valid. It also mounts a linked worktree's common git dir and every
  sibling worktree's `.git` file (read-only), so `git worktree prune` inside
  cannot delete their metadata on the host. `mill stop <repo>` stops one
  checkout.
- **Agent installs its own deps**: scoped passwordless sudo for apt; optional
  `SETUP_CMD` for determinism; `--dind` sidecar when the work needs docker.
  The agent starts only after the sidecar's TCP Docker endpoint passes a
  bounded readiness check.

## Conventions

- Shell only, `set -euo pipefail`, shellcheck-clean; no third-party deps.
- The checkout is the git repo containing the cwd (`-C DIR` overrides) —
  never a positional path. `mill` follows symlinks to find its own dir.
- All config via env vars. Precedence: flags > environment > `MILL.md`
  frontmatter > `~/.config/agentmill/env` (`AGENTMILL_CONFIG` overrides the
  path; `$MILL_DIR/.env` is a deprecated fallback). Files are `KEY=value` /
  `key: value` with quoted values and inline ` # comments`; `mill` parses
  them without sourcing. Secrets belong only in the user config file. API credentials are exported only inside the `mill`
  process and forwarded with Docker's bare `-e KEY` form, keeping their values
  out of host process arguments.
- Git identity goes through `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env, never
  `git config` — the repo is a bind mount and a repo-local setting would
  persist on the host.
- Container user `agent` has `AGENT_UID`/`AGENT_GID` build args (Linux hosts
  need them to match the caller; `mill build` passes them).
- Git operations bounded — never retry infinitely.
- Container runs as non-root `agent`; permission bypass inside the container
  is intentional (the container is the boundary).
