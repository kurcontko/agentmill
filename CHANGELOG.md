# Changelog

## Unreleased

### Added

- Added tag-push GHCR publishing for `ghcr.io/kurcontko/agentmill:<semver>` and
  `ghcr.io/kurcontko/agentmill:latest`.
- Added multi-arch image publishing for `linux/amd64` and `linux/arm64`.
- Added GitHub artifact provenance attestations for published image digests.
- Added `mill build --pull` to use the published image when available and fall
  back to a local build otherwise.

### Changed

- Pinned the container's Claude Code CLI to `2.1.154` via
  `CLAUDE_CODE_VERSION` in `Dockerfile`. Keep future CLI bumps listed here so
  model alias behavior and release contents stay auditable.
