# AgentMill CI

AgentMill intentionally keeps CI much smaller than OpenClaw while borrowing the
patterns that fit this repo:

- Workflows set explicit read-only default permissions and per-job write
  permissions only where needed.
- Third-party actions are pinned by commit SHA and checkouts use
  `persist-credentials: false`.
- Every job has a timeout and workflows use concurrency groups to cancel stale
  branch runs.
- `ci.yml` owns the local proof path: ShellCheck, Hadolint, Python tests, shell
  tests, then a Docker build.
- `workflow-sanity.yml` keeps workflow files mechanically valid with a no-tabs
  check and pinned `actionlint`.
- Security checks stay separate from the fast proof path: CodeQL, dependency
  review, Gitleaks, Trivy, Scorecard, and optional SonarCloud.
- Container publishing uses Buildx cache, multi-arch output, generated SBOM and
  provenance, and GitHub artifact attestation instead of a one-off signing
  shell script.

OpenClaw patterns deliberately not copied:

- Changed-lane preflight and large matrix generation. AgentMill's test surface
  is small enough that the full shell suite is clearer than route planning.
- Custom CodeQL packs and OpenGrep rules. The current shell/Python/container
  surface does not justify maintaining custom security query packs yet.
- `pull_request_target` dependency automation. This repo can use Dependabot and
  dependency-review without a privileged PR-target workflow.
- Release umbrella workflows, hosted testboxes, mobile/desktop matrices, and
  long-running live-provider lanes. Those are OpenClaw scale controls, not
  AgentMill controls.

When adding CI, prefer one explicit small gate over a generalized routing
framework. If a job needs secrets, package publishing, or SARIF upload, keep its
permissions local to that job.

Agent operating patterns are covered separately in
[`docs/AGENTS.md`](AGENTS.md).
