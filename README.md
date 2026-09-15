# AgentMill

Give Claude a mission and a check command. AgentMill runs fresh sessions in Docker until Claude claims completion and the check passes.

## Quick start

Requires Git, a running Docker daemon, and `ANTHROPIC_API_KEY` or
`CLAUDE_CODE_OAUTH_TOKEN` in your environment (or the AgentMill installation's
`.env`). Run these commands from the AgentMill checkout:

```bash
./mill build
./mill init /path/to/repo
${EDITOR:-vi} /path/to/repo/MILL.md && git -C /path/to/repo add MILL.md && git -C /path/to/repo commit -m "Describe mission"
./mill run /path/to/repo --check 'pytest'
```

Use a check appropriate to your project. Python dependency setup runs automatically
before the baseline check, including declared `dev` dependencies. uv projects use a
container-local virtualenv, leaving the host's `.venv` alone. For other stacks,
set `REPO_SETUP_COMMAND` (for example, `npm ci`). Set `AUTO_SETUP=false` to skip setup.
Setup output is saved in the printed run directory.

## How it decides success

The baseline must pass before Claude starts. Each fresh `claude -p` session reads
`MILL.md` and uses committed `PROGRESS.md` and Git history as its handoff. It must
commit its work and return a structured completion claim. The same check runs
after every session; success means a completion claim plus a passing check on a
clean, unchanged commit. This verifies your check, not an independent review of
the mission. Review the resulting diff.

`--iterations` defaults to 5 and `--timeout` to 1800 seconds per setup, session, or
check. Use `--model` to select a model. The repo defaults to `REPO_PATH`, then the
current directory; `CHECK_CMD` can supply the check instead of `--check`.

## Stopping and inspecting a run

Ctrl-C stops the foreground run. Failures and timeouts stop immediately; there
is no automatic restart, reset, WIP commit, or push. Commits and unfinished work
remain in your checkout for inspection.

Each invocation prints its directory under
`${XDG_STATE_HOME:-$HOME/.local/state}/agentmill/runs/`. It contains setup/check
output, session JSON, separate stderr logs, and `outcome.json` with the stop reason
and checked commit. Exit codes: `0` checked completion, `2` iteration limit,
`1` failure, `130`/`143` interrupted/terminated. Docker startup failures retain
Docker's status; an abrupt kill may leave no outcome.

Use one run per regular checkout, as a non-root user. Commit or stash changes
first and ignore generated artifacts. Linked worktrees are not supported yet.
Claude runs with automatic tool approval and can modify the checkout and logs;
logs are not tamper-proof evidence. Only the checkout and run directory are
mounted—no host Claude configuration or Docker socket. Authentication is supplied
to the container, which has network access.

## Legacy users

The former Compose commands are available only through `mill legacy`, such as
`mill legacy run`, `mill legacy watch`, and `mill legacy stop`.
See [legacy documentation](docs/legacy.md). The default `init` writes only
`MILL.md`; the default `run` never starts Compose.
