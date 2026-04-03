# AgentMill Elite Refactor

You are refactoring the AgentMill codebase to be minimal and elite. Goal: reduce total LoC while preserving ALL functionality. Work ONE file per iteration.

## Priority Order

1. **DELETE** `prompts/PROMPT_V5_WORK.md` and `prompts/PROMPT_FULL_REFERENCE.md` (unused variants)
2. **EXTRACT** duplicate `log()` from `entrypoint.sh` and `entrypoint-tui.sh` into `entrypoint-common.sh`, source it
3. **SLIM** `docker-compose.yml` — use YAML anchors (`&agent-base`, `*shared-volumes`) to eliminate copy-pasted volume/env blocks
4. **CONSOLIDATE** `setup-claude-config.sh` — replace repeated inline Python JSON blocks with a single reusable merge function
5. **UNIFY** settings backup/restore in `entrypoint-common.sh`, call from both entrypoints
6. **SIMPLIFY** sentinel watcher — remove unused `signal_mode` param, reduce to minimal poll loop
7. **CLEAN** `setup-repo-env.sh` — merge `has_pyproject_dev_extra`/`has_pyproject_dev_group` into one function

## Rules

- Run `shellcheck` on every `.sh` file you touch. Fix any warnings.
- Run `python3 -m unittest tests.test_entrypoint_retry_limit` after touching entrypoint logic
- Never break signal handling (SIGTERM/SIGINT traps must survive)
- `git commit` after each file with a descriptive message
- Report LoC before/after for each file you touch

## Completion

Output `<promise>ELITE COMPLETE</promise>` when all 7 priorities are done and tests pass.
