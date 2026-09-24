# AgentMill

A small, checked job runner around `codex exec` and `claude -p`. Read README.md for
the public contract and docs/runner-reference.md for detailed interfaces.

## Architecture

- `agentmill/contracts.py`: RunSpec, RunOutcome, worker reply and process contracts.
- `agentmill/runner.py`: one bounded repair/continuation loop.
- `agentmill/executor.py`: shared subprocess deadlines, Docker lifecycle and cleanup.
- `agentmill/workspace.py`: private checkouts, supervisor-owned snapshots and exports.
- `agentmill/checks.py`: fresh candidate check environments and bounded feedback.
- `agentmill/records.py`: versioned events and atomic terminal outcome.
- `agentmill/adapters/`: native command construction and final-result parsing only.
- `agentmill/cli.py`: run, show and diff.
- `mill`: checkout launcher (installed CLI is `agentmill`), image build, optional mission init.
- `basic_loop.py`: isolated Python launcher for the evolved checked loop.

The supervisor runs on the host. Workers never receive a writable mount of its
records or snapshot store. Checks receive no supplied agent credentials. Never
mount the source checkout or Docker socket into a worker. Do not infer completion
from an exit code alone: require a valid native terminal envelope, a `done` reply,
and passing configured checks on the captured candidate.

## Conventions

Python 3.11+, standard-library runtime only. Keep provider flags out of the runner.
All subprocesses must be bounded. Killing a Docker client is not container cleanup.
Capture partial changes after worker exit, even on failure or cancellation. Never
reset, stash, merge, or push the user's checkout. Preserve both latest and last
passing candidates. Never run host Git against worker-controlled Git metadata.

## Testing

Run focused unittest files during development, then the relevant CI checks:

```bash
python3 -m unittest discover -s tests -p 'test_basic_loop.py'
python3 -m unittest discover -s tests -p 'test_adapters.py'
python3 -m unittest discover -s tests -p 'test_workspace.py'
shellcheck mill
AGENTMILL_SMOKE_IMAGE=agentmill:latest python3 tests/smoke_basic_image.py
```

Docker smoke tests use deterministic native CLI fixtures without provider billing.
Real native CLI protocol tests must also exercise the packaged versions. Do not
add agent-framework, scheduler, review, approval, or provider-registry abstractions.

## Repository scope

Keep one checked runner and its user-facing documentation. Do not restore the
retired Compose runtime, prompt templates, memory helpers, or automatic Git
publication. Keep private notes, review transcripts, and per-PR validation journals
outside tracked files; `.docs/` is ignored for local notes. Summarize validation in
the PR description instead.
