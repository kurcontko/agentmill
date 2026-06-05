# CI TODO

Based on review of `split/05-ci-improvements` at commit `8291260`.

## Priority 0

- [ ] Make Trivy findings enforce the build.
  - Add a blocking scan path with `exit-code: "1"` for HIGH/CRITICAL findings.
  - Keep SARIF upload with `if: always()` so failures still publish diagnostics.
  - Decide whether unfixed OS vulnerabilities should fail or only report.

- [ ] Publish images only from a verified tag SHA.
  - For `workflow_dispatch`, resolve `v${version}` and checkout that exact tag.
  - Fail if the tag does not exist or does not match the checked-out commit.
  - Require protected branch/tag policy or a GitHub environment approval for manual releases.

- [ ] Gate publishing on a green proof path.
  - Either run the required CI/security jobs inside `publish-image.yml`, or trigger publish from a successful CI `workflow_run`.
  - Ensure the image digest corresponds to the same SHA that passed validation.

## Priority 1

- [ ] Prevent accidental `latest` rollback.
  - Publish immutable semver tags by default.
  - Move `latest` only from a protected release path, or require an explicit manual promotion input.
  - Add a guard that rejects publishing `latest` from an older semver than the current registry/latest release.

- [ ] Make SonarCloud absence explicit.
  - Skip SonarCloud only on fork PRs where secrets are unavailable.
  - Fail protected branch runs if `SONAR_TOKEN` is missing.
  - Document whether SonarCloud is required or optional for this repo.

- [ ] Add workflow linting as a first-class CI gate.
  - Add `actionlint` with a pinned version.
  - Include a simple no-tabs/no-bad-YAML check for workflow and Dependabot files.
  - Keep this fast enough to run on every PR.

## Priority 2

- [ ] Move test orchestration out of workflow YAML.
  - Add one local command such as `make test`, `scripts/test`, or `mill test`.
  - Let CI call that command instead of embedding shell test discovery.
  - Keep separate fast, integration, and security entry points if the suite grows.

- [ ] Add release documentation.
  - Document how tags are created, who can publish, what `latest` means, and how to verify provenance.
  - Include rollback and re-run behavior.

- [ ] Add CI ownership notes.
  - List which jobs are required branch checks.
  - Explain which security scanners are blocking versus advisory.
  - Capture expected runtime budget for the full PR path.

## Done Criteria

- Pull requests cannot merge with failing local tests, workflow lint, or enforced HIGH/CRITICAL vulnerability policy.
- Published images are reproducible from a known tag SHA that passed required checks.
- Manual release runs cannot publish an arbitrary branch as a semver image.
- Optional scanners are visibly optional; required scanners fail closed on protected refs.
