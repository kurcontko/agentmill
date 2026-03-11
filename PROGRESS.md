# Progress

## Completed
- 2026-03-09: Completed `[P1-1] Add process.wait() timeout in supervisor` in `codex_preview_supervisor.py`.
- Verification: `python3 -m unittest tests.test_codex_preview_supervisor`, `python3 -m unittest tests.test_codex_preview_server`, `python3 -m py_compile codex_preview_server.py codex_preview_supervisor.py`, and `python3 -c "import codex_preview_server, codex_preview_supervisor; print('OK')"` succeeded.
- 2026-03-09: Completed `[P0-3] Replace asserts on subprocess pipes with conditionals` in `codex_preview_supervisor.py`.
- Verification: `grep -r "assert process" *.py` returned no matches, `python3 -m py_compile codex_preview_server.py codex_preview_supervisor.py`, and `python3 -c "import codex_preview_server, codex_preview_supervisor; print('OK')"` succeeded.
- 2026-03-09: Completed `[P0-4] Fix subscriber broadcast race condition in server` in `codex_preview_server.py`.
- Verification: `python3 -m unittest tests.test_codex_preview_server`, `rg -n "for q in list\\(self\\.subscribers\\)" codex_preview_server.py`, `python3 -m py_compile codex_preview_server.py codex_preview_supervisor.py`, and `python3 -c "import codex_preview_server, codex_preview_supervisor; print('OK')"` succeeded.
- 2026-03-09: Completed `[P1-2] Prevent infinite rebase-push loop in entrypoint.sh` in `entrypoint.sh`.
- Verification: `python3 -m unittest tests.test_entrypoint_retry_limit` and `python3 -c "import codex_preview_server, codex_preview_supervisor; print('OK')"` succeeded.
- 2026-03-09: Completed `[P1-3] Narrow broad exception handlers in server` in `codex_preview_server.py` and `tests/test_codex_preview_server.py`.
- Verification: `python3 -m unittest tests.test_codex_preview_server`, `rg -n "except Exception: pass|except Exception" codex_preview_server.py`, `python3 -m py_compile codex_preview_server.py codex_preview_supervisor.py`, and `python3 -c "import codex_preview_server, codex_preview_supervisor; print('OK')"` succeeded.

- 2026-03-11: Completed `[R1] Work-Stealing Queue` research task.
  - Implemented `queue_server.py`: HTTP-based work-stealing queue, Python stdlib only, atomic dequeue via threading.Lock, crash recovery (in-flight tasks re-queued on restart), FIFO with priority re-queue for failed tasks (max 3 retries).
  - Added `tests/test_queue_server.py`: 22 tests including concurrent dequeue test verifying no double-dequeue with 20 simultaneous threads.
  - Added `docs/research/work-stealing-queue.md`: compares file-based (TOCTOU race), SQLite, and HTTP queue approaches; recommends HTTP queue for multi-agent Docker deployments.
  - Verification: `python3 -m unittest tests.test_queue_server` — 22 tests, OK.

- 2026-03-11: Completed `[R2] Hierarchical / Supervisor-Worker Model` research task.
  - Implemented `coordinator.py`: HTTP-based coordinator, Python stdlib only, atomic assign via threading.Lock, crash recovery (in-flight tasks re-queued on restart), heartbeat TTL reaping, priority ordering, TASK.md seeding on startup.
  - Added `tests/test_coordinator.py`: 28 tests including concurrent assign (no double-dequeue), crash recovery, TASK.md parser, and HTTP API integration tests.
  - Added `docs/research/hierarchical-coordination.md`: surveys CrewAI/AutoGen/Devin; recommends HTTP coordinator for 3+ agent deployments; documents extension points for merge gate (R3) and autoscaling (R7).
  - Verification: `python3 -m unittest tests.test_coordinator` — 28 tests, OK.

## In Progress

## Blocked
- Full smoke verifier from `TASK.md` is currently unavailable in this environment because `docker` is not installed.

## Next Up
- Pick next P0 research task from `TASK.md`: `[R3] Consensus-Based Merge Gate`.
