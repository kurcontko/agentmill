# Native protocol fixtures

`codex-success.jsonl` and `claude-success.jsonl` are reference transcripts,
originally captured from the packaged Codex 0.154.0 and Claude Code 2.1.119 CLIs
using `tests/smoke_native_clis.py`. That smoke test re-runs whichever CLIs the
Dockerfile currently pins, so protocol compatibility is checked on every image.
Each CLI executed its real Bash/shell tool and returned schema-constrained output.
The API responses were deterministic loopback fixtures inside a Docker container
with `--network none`; no provider credentials or paid calls were used.

`native_cli.py` is the deterministic CLI substitute for the broader lifecycle
matrix. It exercises repair across sessions, commits and uncommitted work,
blocked replies, protocol failure, timeouts, and cancellation. The real-CLI smoke
test separately detects incompatibility between the adapters and pinned versions.
