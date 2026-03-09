# AgentMill — Task Board

Each task is independent, verifiable, and scoped to one agent session.
Pick one, do it, run the verifier, commit.

Verifier: `docker build -t agentmill-test . && docker run --rm --entrypoint python3 agentmill-test -c "import codex_preview_server; import codex_preview_supervisor; print('OK')"` (smoke) + manual dashboard check for UI tasks.

---

## Merge — Prerequisite

---

### [P0-2] Fix unquoted variable expansion in setup-repo-env.sh
Line 39: `pip install $EXTRA_PYTHON_TOOLS` — word-splits on spaces.
- Quote `"$EXTRA_PYTHON_TOOLS"` or convert to array
- Also: `eval "$REPO_SETUP_COMMAND"` on line 52 is a shell injection vector — document the trust boundary (operator-controlled, not user-controlled)
- **Files:** `setup-repo-env.sh`
- **Done when:** `shellcheck setup-repo-env.sh` passes clean

### [P0-3] Replace asserts on subprocess pipes with conditionals
`codex_preview_supervisor.py` and `codex_preview_server.py` use `assert process.stdout is not None`. Asserts are stripped with `python -O`.
- Replace with `if process.stdout is None: raise RuntimeError(...)`
- **Files:** `codex_preview_supervisor.py`, `codex_preview_server.py`
- **Done when:** `grep -r "assert process" *.py` returns zero matches

### [P0-4] Fix subscriber broadcast race condition in server
`codex_preview_server.py`: iterating `self.subscribers` while another thread could modify it.
- Copy the list before iterating: `for q in list(self.subscribers):`
- **Files:** `codex_preview_server.py`
- **Done when:** no shared mutable iteration without copy

---

## P1 — Robustness

### [P1-2] Prevent infinite rebase-push loop in entrypoint.sh
If push fails due to permanent conflict, the loop retries every iteration forever.
- Add a retry counter (max 3 rebase attempts per iteration)
- Log `ERROR: push failed after 3 retries` and skip push after max
- **Files:** `entrypoint.sh`
- **Done when:** agent logs error and continues to next iteration instead of looping

### [P1-3] Narrow broad exception handlers in server
`codex_preview_server.py`: bare `except Exception: pass` silently swallows OOM, KeyboardInterrupt, etc.
- Catch `(OSError, json.JSONDecodeError)` specifically
- **Files:** `codex_preview_server.py`
- **Done when:** no bare `except Exception: pass` in file

### [P1-4] Fix file handle leak in setup-claude-config.sh
Embedded Python uses `json.load(open(...))` — never closes the fd.
- Use `with open(...) as f: json.load(f)` pattern
- **Files:** `setup-claude-config.sh`
- **Done when:** no bare `open()` calls in embedded Python

### [P1-5] Add graceful shutdown to FileWatcher daemon thread
The watcher thread is a daemon that gets killed abruptly on server stop.
- Add a `threading.Event` stop flag, check in poll loop, set on shutdown
- **Files:** `codex_preview_server.py`
- **Done when:** server shuts down cleanly without orphan threads

### [P1-6] Clean up temp files in entrypoint-codex.sh
`mktemp` creates temp files that aren't cleaned on error paths.
- Add a trap: `trap 'rm -f "$tmp_file"' EXIT`
- **Files:** `entrypoint-codex.sh`
- **Done when:** temp files cleaned on both success and error exit

---

## P2 — Dashboard UI/UX

### [P2-1] Add event type filtering to feed
Filter by: errors only, commands only, reasoning only, all.
- Add a filter bar above the feed with toggle buttons
- Filter by CSS class (`.tool-group`, `.reasoning-block`, `.msg-block`)
- Persist selection in `sessionStorage`
- **Files:** `static/index.html`
- **Done when:** clicking "errors" hides non-error events; refresh preserves filter

### [P2-2] Add keyboard shortcuts
- `j`/`k` to navigate tool groups
- `Enter` to expand/collapse focused group
- `Esc` to close all expanded groups
- `?` to show shortcut overlay
- **Files:** `static/index.html`
- **Done when:** pressing `?` shows overlay; `j`/`k` moves focus

### [P2-3] Add log export button
Button in topbar that downloads the current agent's `events.ndjson`.
- Use `Blob` + `URL.createObjectURL` for client-side download
- **Files:** `static/index.html`
- **Done when:** clicking export downloads a `.ndjson` file

### [P2-4] Add Subresource Integrity to CDN scripts
`marked.js` loaded from CDN without SRI hash.
- Pin to exact version (not `@15`)
- Add `integrity="sha384-..."` and `crossorigin="anonymous"`
- **Files:** `static/index.html`
- **Done when:** marked.js has SRI attribute

### [P2-5] Cap reasoning block height
Reasoning blocks can be arbitrarily long and push the feed down.
- Add `max-height: 300px; overflow-y: auto` to `.reasoning-block .rb-body`
- Add "show more" toggle when content overflows
- **Files:** `static/index.html`
- **Done when:** long reasoning blocks are scrollable with expand option

### [P2-6] Show visual indicator for stop confirmation
Stop button changes text to "confirm?" but has no visual distinction.
- Add red border or pulsing animation when in confirm state
- Auto-reset after 3 seconds if not clicked
- **Files:** `static/index.html`
- **Done when:** stop button visually changes during confirm window

---

## P3 — Code Quality & DX

### [P3-1] Deduplicate git sync logic between entrypoints
`entrypoint.sh` and `entrypoint-codex.sh` share identical git clone/rebase/push logic (~40 lines).
- Extract into `git-sync.sh` sourced by both
- **Files:** `entrypoint.sh`, `entrypoint-codex.sh`, new `git-sync.sh`
- **Done when:** both entrypoints source `git-sync.sh`; no duplicated git logic

### [P3-2] Reduce docker-compose.yml duplication
agent-1/2/3 are nearly identical (~50 lines of copy-paste).
- Use `docker compose --scale` or more aggressive YAML merge keys
- Or document `--scale agent=3` as the recommended pattern
- **Files:** `docker-compose.yml`
- **Done when:** agent definitions are <20 lines total (excluding comments)

### [P3-3] Add shellcheck CI
All `.sh` files should pass `shellcheck`.
- Fix all shellcheck warnings across all scripts
- Add a `Makefile` target or CI step: `shellcheck *.sh`
- **Files:** all `.sh` files, optionally `Makefile` or `.github/workflows/lint.yml`
- **Done when:** `shellcheck *.sh` exits 0

### [P3-4] Extract embedded Python from setup-claude-config.sh
~40 lines of Python inside a bash heredoc. Can't be linted, tested, or debugged easily.
- Move to `merge_claude_config.py`
- Call from bash: `python3 /merge_claude_config.py ...`
- **Files:** `setup-claude-config.sh`, new `merge_claude_config.py`
- **Done when:** no Python heredocs in shell scripts

### [P3-5] Add type hints to Python files
Both `.py` files lack type annotations on most functions.
- Add type hints to all function signatures
- Optionally add `mypy` config
- **Files:** `codex_preview_server.py`, `codex_preview_supervisor.py`
- **Done when:** `mypy --check-untyped-defs` passes

---

## P4 — Documentation

### [P4-1] Document multi-agent branch strategy
README mentions multi-agent but doesn't explain the branch model (each agent gets `agent-{id}` branch, rebases on upstream).
- Add "Multi-Agent Workflow" section with step-by-step
- **Files:** `README.md`
- **Done when:** new section explains clone, branch, rebase, push cycle

### [P4-2] Add troubleshooting section
Common failures: auth not configured, repo path wrong, codex binary missing, permission denied on volumes.
- Add "Troubleshooting" section with symptom → fix table
- **Files:** `README.md`
- **Done when:** at least 5 common issues documented

### [P4-3] Sync README status.json example with actual supervisor output
Example may show fields that don't match what the supervisor actually writes.
- Audit `codex_preview_supervisor.py` for actual fields
- Update README example to match exactly
- **Files:** `README.md`, cross-reference `codex_preview_supervisor.py`
- **Done when:** README example matches supervisor output

---

## Completed

_Move tasks here with date and commit hash when done._

- 2026-03-09: `[P1-1] Add process.wait() timeout in supervisor` completed in `codex_preview_supervisor.py` and `tests/test_codex_preview_supervisor.py`.
