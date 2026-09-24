# Changelog

All notable changes to AgentMill are recorded here. The project follows
[Semantic Versioning](https://semver.org/); the Python API and record layouts are
experimental until 1.0.

## 0.1.0 — Unreleased

First public release: one checked, bounded run of `codex exec` or `claude -p`.

### Added

- `agentmill run` executes a task from a committed revision in a private clone,
  with up to `--max-sessions` native sessions inside `--max-duration`.
- Checks run on each captured snapshot in fresh containers with no agent
  credentials; failures feed the next session. Completion requires a valid native
  result, a `done` reply and every check passing.
- Explicit exit codes: 0 complete, 1 failure, 2 incomplete, 3 blocked,
  130/143 cancelled. Latest and last-passing candidates are both kept.
- A session that crashes, returns no valid reply or times out keeps its captured
  work and seeds the next session; two failures in a row stop the run.
- `--check-dir` held-out checks, mounted read-only only into check containers.
- Exports `result.patch` and a self-contained `result.bundle`; `list`, `show` and
  `diff` (with `latest`) inspect retained runs.
- `session.progress` events about once a minute during long sessions.
- Actionable failures: `image_unavailable`, `docker_unavailable`, and runtime
  diagnostics with the tool's error output, log path and hints.
- Runtime image with Node 24, Claude Code 2.1.281 and Codex 0.156.1, published as
  `ghcr.io/kurcontko/agentmill:<version>`.
- Threat model in `SECURITY.md`.

### Changed

- The project replaces the earlier respawning Compose runtime, which committed and
  pushed from inside the container. That runtime and its prompt templates, memory
  helpers and automatic Git publication are retired.
