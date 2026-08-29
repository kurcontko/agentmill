# AgentMill

A Docker container that runs an AI agent CLI (`claude -p` or `codex exec`) in
a respawning loop. Fresh context each iteration; the target repo (PROGRESS.md +
git history) is the only memory.

## Commands

```bash
mill run                                   # loop on the repo containing the cwd
mill -C ~/myrepo run --agent codex --model gpt-5.2-codex --iterations 5
mill shell                                 # interactive shell in the container
mill logs [--raw|--results]                # summaries / event log / ledger table
mill steer "..."                           # one-shot note for the next session
mill stop [--soft|--all]                   # container / after this iteration / all
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
prompts/PROMPT.md  # framework prompt (claude: --append-system-prompt-file):
                   #   one task per session, PROGRESS.md, failed-approaches log,
                   #   {done, summary, blocked} reply
prompts/EVALUATOR.md # read-only reviewer prompt: PASS | NEEDS_WORK + findings
<repo>/MILL.md     # the mission (body, spliced into the prompt each iteration)
                   #   + frontmatter `key: value` settings (lowercase env names)
<repo>/.mill/      # operator drop-box, git-excluded: STOP, STEER.md
tests/test_loop.sh # smoke tests with a stubbed CLI (no network, no docker)
tests/test_mill.sh # smoke tests for the CLI with a stubbed docker
logs/<container>/  # per-checkout: results.jsonl, metrics.tsv (metric mode),
                   #   iter-N-<sha>.log / .summary / .eval.log, dot-files for
                   #   the last parse (.last-metrics, .last-struct, schemas)
```

## Key patterns

- **Respawning loop**: fresh context per iteration; carry-forward is only a
  preamble (recent commits + head of PROGRESS.md + current METRIC best).
- **Initializer**: no PROGRESS.md = first session; the preamble tells it to turn
  the mission into a checklist, ensure a verifier, commit, and exit.
- **Structured reply**: `--json-schema` (claude) / `--output-schema` (codex)
  yields `{done, summary, blocked}`; `summary` replaces the raw final message.
  `DONE_PROMISE` in plain text is the fallback when no schema reply came back.
- **Completion contract**: a `done` claim is verified, never trusted —
  `DONE_CMD` (else CHECK_CMD green this iteration), then `EVALUATOR=true` runs
  one read-only fresh-context review session over the run's diff. A rejection is
  appended to PROGRESS.md, committed, and the loop continues.
- **Steering drop-box**: `.mill/STOP` (mill stop --soft) brakes between
  iterations; `.mill/STEER.md` (mill steer) is one-shot, read then deleted, and
  injected as `<operator-steer>`. loop.sh adds `.mill/` to info/exclude so
  `git status` gating and `git clean -ffd` ignore it. MILL.md is re-read every
  iteration, so editing the mission steers a running loop.
- **Agent commits its own work**; the loop safety-nets leftovers as `[wip]`.
- **Ratchet**: `CHECK_CMD` failure reverts the iteration (`git reset --hard` +
  `git clean`), including initialized submodules recursively and including
  after an agent error or timeout. Repository-status errors are fatal, so the
  loop never mistakes an unreadable checkout for a clean one. The loop
  therefore refuses to start on a dirty worktree.
- **Metric ratchet**: `METRIC_CMD`'s last stdout line is the score; baseline
  measured on the clean tree (unparseable = fatal), then only a strictly better
  score in `METRIC_DIRECTION` is kept. Floats compared with awk, not the shell.
- **Cost & health stops**: per-session cost/turns/tokens parsed from the result
  event; `MAX_BUDGET_USD`/`MAX_TURNS` bound a session (claude),
  `MAX_TOTAL_BUDGET_USD` the run. `MIN_TURNS` turns an idle "successful"
  session into an error (bad key/model) instead of a slow no-op; a self-reported
  `blocked` counts toward `MAX_NOOPS`.
- **Stop conditions**: a verified done claim, `.mill/STOP`, `MAX_ITERATIONS`,
  `MAX_NOOPS`, `MAX_ERRORS` (exponential backoff capped by `MAX_BACKOFF`),
  `MAX_TOTAL_BUDGET_USD`, `ITER_TIMEOUT` per session. TERM/INT is forwarded to the agent's process
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
- Nothing a model returned may abort the loop: every parse of a structured
  reply or metric degrades to "unknown" and defaults to fail-closed.
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
