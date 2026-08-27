# AgentMill

A Docker container that runs an AI agent CLI (`claude -p` or `codex exec`) in
a respawning loop. Fresh context each iteration; the target repo (TODO.md +
git history) is the only memory.

## Commands

```bash
./mill run ~/myrepo                        # run the loop
./mill run ~/myrepo --agent codex --model gpt-5.2-codex --iterations 5
./mill shell ~/myrepo                      # interactive shell in the container
./mill logs                                # follow the running loop
./mill build / stop / ps / init

# Test / lint
bash tests/test_loop.sh
shellcheck loop.sh mill tests/*.sh
```

## Architecture

```
loop.sh            # the whole framework: agent loop, stop conditions, ratchet
mill               # CLI wrapper — plain docker run (no compose)
Dockerfile         # node:22-slim + claude + codex + git/jq/python3/sudo
prompts/PROMPT.md  # stock prompt: TODO.md convention + TASK_COMPLETE promise
tests/test_loop.sh # smoke tests with a stubbed CLI (no network, no docker)
logs/results.jsonl # one line per iteration: status, commits, head
```

## Key patterns

- **Respawning loop**: fresh context per iteration; carry-forward is only a
  preamble (recent commits + head of TODO.md).
- **Agent commits its own work**; the loop safety-nets leftovers as `[wip]`.
- **Ratchet**: `CHECK_CMD` failure reverts the iteration (`git reset --hard`).
- **Stop conditions**: `DONE_PROMISE` in the final message, `MAX_ITERATIONS`,
  `MAX_NOOPS`, `MAX_ERRORS` (exponential backoff), `ITER_TIMEOUT` per session.
- **Parallelism**: no framework code — one git worktree per agent, run mill twice.
- **Agent installs its own deps**: scoped passwordless sudo for apt; optional
  `SETUP_CMD` for determinism; `--dind` sidecar when the work needs docker.

## Conventions

- Shell only, `set -euo pipefail`, shellcheck-clean; no third-party deps.
- All config via env vars (`.env`, docker --env-file format — no inline comments).
- Git operations bounded — never retry infinitely.
- Container runs as non-root `agent`; permission bypass inside the container
  is intentional (the container is the boundary).
