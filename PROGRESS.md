# Progress

## Completed
- 2026-03-09: Completed `[P0-3] Replace asserts on subprocess pipes with conditionals` in `codex_preview_supervisor.py`.
- Verification: `grep -r "assert process" *.py` returned no matches, `python3 -m py_compile codex_preview_server.py codex_preview_supervisor.py`, and `python3 -c "import codex_preview_server, codex_preview_supervisor; print('OK')"` succeeded.
- 2026-03-09: Completed `[P0-4] Fix subscriber broadcast race condition in server` in `codex_preview_server.py`.
- Verification: `python3 -m unittest tests.test_codex_preview_server`, `rg -n "for q in list\\(self\\.subscribers\\)" codex_preview_server.py`, `python3 -m py_compile codex_preview_server.py codex_preview_supervisor.py`, and `python3 -c "import codex_preview_server, codex_preview_supervisor; print('OK')"` succeeded.

## In Progress

## Blocked
- Full smoke verifier from `TASK.md` is currently unavailable in this environment because `docker` is not installed.

## Next Up
- Pick the next highest-leverage unclaimed task from `TASK.md`; `[P1-1]` is the next adjacent Python robustness fix.
