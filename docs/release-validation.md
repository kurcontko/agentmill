# Release-candidate validation

## Reference and scope

Inspected PR #38 at `9d2dd9ee4c01b4c1e57b10c26e2a2568df4adb27`, stacked on
`split/32-basic-loop` at `bd27cfc315d9cf7ab70082499deb0a01229bbdc9`. All checks,
including the separate Sonar quality gate and automated review, passed on that
reference head. The release-candidate changes preserve that stack and its gates.

The runner remains synchronous Python with standard-library runtime dependencies,
two native adapters, private regular checkouts, and supervisor-owned snapshots.
Only terminal semantics, result inspection, documentation, and release validation
are in scope. The API and internal records remain experimental.

## Validation performed for this change

Local environment: macOS arm64, Colima, Python 3.13 for coverage and Python 3.14
for the independently installed package. The unchanged runtime Dockerfile supplies
Codex 0.154.0 and Claude Code 2.1.119. CI runs on Linux amd64 using the Ubuntu
runner's Python; native protocol tests also exercise Python 3.11 in the image.

- **67 unittest tests passed**, approximately **94% coverage**, above the existing
  80% requirement. New regression tests first reproduced the relevant failures at
  the inspected head; fixes retained the existing connected-pipe and source-safety
  tests.
- Built the universal Python wheel and installed it into a separate virtualenv.
  From outside the source checkout, verified that imports resolve to that
  environment's `site-packages` and that the installed `mill --help` works.
- **12 Docker scenarios passed through the installed entrypoint**, with its cwd
  outside the source checkout and no source `PYTHONPATH`. Both backends exercised
  repair, regression after a pass, blocked work, missing terminal output, timeout,
  and signal cancellation. Storage paths contain spaces; `show` and `diff` locate
  and read the recorded outcomes/artifacts.
- Those fixtures also exercise default API-key environment routing, explicit
  Claude OAuth-variable routing, and Codex `--auth-file` copying, using dummy
  values only. Check containers receive none of those supplied worker credentials.
  This establishes routing/isolation, not acceptance of credentials by a provider.
- Real packaged CLIs executed a shell tool and produced structured terminal output
  against the existing loopback API fixture with container networking disabled.
  This establishes native protocol compatibility without a provider call.

No live worker/provider validation calls were made. The earlier live full-path runs are evidence
for the earlier implementation, **not validation of the changed execution code**.
A new model-driven full-path run of these changes remains conditional on explicit
authorization. No other OS/architecture or published package/image is claimed.

## Finite acceptance gate

Run existing suites; do not expand this into a benchmark or orchestration project:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
AGENTMILL_SMOKE_IMAGE=agentmill:latest python3 tests/smoke_basic_image.py
# Optional test-harness override for an independently installed wheel:
AGENTMILL_SMOKE_IMAGE=agentmill:latest \
  AGENTMILL_SMOKE_CLI=/path/to/venv/bin/mill python3 tests/smoke_basic_image.py
```

The native protocol fixture runs through the Docker invocation in
[CI](../.github/workflows/ci.yml). Keep lint, shell tests, package checks, Docker
checks, security scans, and the **separate** Sonar quality gate. A successful scan
workflow alone does not establish a passing quality gate.
The release-candidate display-command finding was reproduced as safe shell
quoting with a real bundle and hostile filename, then documented in the existing
[security triage](security-triage.md). Its narrow false-positive exclusion does not
change any quality-gate threshold.

| Boundary | Evidence |
| --- | --- |
| Dirty source, snapshots, binary/ignored files, exact patch/bundle contents | `test_basic_loop.py`, `test_workspace.py`; checks rerun in the clean imported checkout |
| Both adapters, repair, failed checks, malformed/unsuccessful native output | Shared lifecycle and adapter suites; Docker fixtures |
| Exactly one native session when capped at one | Continuing-reply lifecycle regression |
| Blocked question, capture, no new check environment, historical passing identity | Both-backend blocked tests and Docker fixtures |
| Primary failure plus capture/export/record-write faults | Failure-precedence regressions |
| Cleanup uncertainty, cancellation, and no unsafe capture | Executor and lifecycle regressions |
| No work admitted after run/finalization deadline; allowance never renewed | Executor admission and success-boundary regressions |
| Full connected output pipe plus SIGTERM | CLI subprocess regression, authoritative terminal outcome |
| Custom paths, safe command quoting, partial/missing exports | CLI regressions and installed Docker workflow |
| No terminal record after interruption | `show` returns unknown; no implicit resumption |
| Signal handler restoration even when final recording fails | Lifecycle regression |

## Timing: existing live task and current offline replay

Reference task: repair `retryable(status)` to accept exactly 429, 500, 502, 503,
and 504, with existing unittest checks. Source revision:
`f5bd20c7f5f545ba086bee46eb05a314eba1ed97`.

The retained **2026-09-18 live-run** event timestamps give these phase intervals.
They include container/Git overhead where stated; they are not isolated model or
setup timings. Both runs used `setup=true` and finished in one native session.

| Interval, seconds | Codex `r_386225ff36514788` | Claude `r_35c9fb9d4e3f4a8b` |
| --- | ---: | ---: |
| Source preparation | 0.377 | 0.663 |
| Baseline preparation/setup/check/cleanup | 1.215 | 1.392 |
| Worker setup/version/native execution/cleanup | 19.596 | 15.397 |
| Candidate capture | 0.306 | 0.326 |
| Candidate preparation/setup/check/cleanup | 1.013 | 1.042 |
| Export and terminal recording | 0.188 | 0.205 |
| Whole run | 22.697 | 19.028 |

The recorded baseline/candidate check-command durations are 0.138/0.092 seconds
for Codex and 0.143/0.123 seconds for Claude. Setup was not separately timed then;
these measurements do not establish cold dependency-install performance.

For a fresh breakdown without provider calls, a one-off harness replayed the
retained fix against that same source task using the current runner. It timed
`Container.setup/session/check` and `Workspace.prepare/capture/export` with a
monotonic clock. Setup created a new Python virtualenv in each container; checks
ran the reference unittests. The native fixture replayed the recorded edit and
structured reply, so its duration **does not measure model execution**.

Run `r_5cce61f7d819478b`, warm local Docker image, no dependency downloads:

| Phase | Seconds |
| --- | ---: |
| Source preparation | 0.344 |
| First fresh setup: baseline | 2.250 |
| Repeated fresh setup: worker | 2.366 |
| Repeated fresh setup: candidate checks | 2.803 |
| Native fixture execution | 0.170 |
| Baseline / candidate check commands | 0.153 / 0.173 |
| Candidate capture / export | 0.394 / 0.163 |
| Whole run, including remaining container/record overhead | 12.390 |

Fresh setup consumed about 7.42 seconds (60%) of this offline replay; source
preparation was only 0.34 seconds. This is a small, dependency-free task with a
warm runtime image, not a cold-image or network-install benchmark. No cache or
shared check environment was introduced.

## Follow-ups deliberately excluded

- With authorization, repeat a live full-path task per backend on the release
  candidate; do not reinterpret older live evidence as a fresh pass.
- Measure a dependency-heavy real repository's first and repeated setup costs.
  The measured preparation cost warrants investigation, not shared mutable check
  state or result caching. Rechecking the same commit may see different external
  state.
- Validate the existing tag/manual image-publication workflow separately; it was
  neither changed nor triggered here. Package registry distribution, broader
  platform validation, and legacy retirement are separate release work.
- Scheduling, graphs, reviewers, services, shared execution environments, model
  fallback, resumption, and automatic publication remain outside the core.

Stop this PR when its scoped tests and required gates pass. The next step is
repeated real usage, not another architecture revision.
