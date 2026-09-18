# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in AgentMill, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please email the maintainers directly or use [GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability).

### What to include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response timeline

- **Acknowledgement**: within 48 hours
- **Initial assessment**: within 1 week
- **Fix or mitigation**: best effort, depending on severity

## Supported Versions

Only the latest release on the `main` branch is actively supported with security updates.

## Security Considerations

- Docker is the checked runner's execution boundary. Codex uses an explicit
  `danger-full-access` native profile inside that boundary; Claude uses `dontAsk`
  and coding-tool approvals. These commands are constructed for isolated worker
  containers, not unrestricted execution in the source checkout.
- Workers can modify their private checkout, use the network, and access selected
  native credentials. The source checkout, Docker socket, supervisor records, and
  snapshot repository are never mounted into workers. Check containers receive no
  supplied agent credentials or native configuration mounts.
- Check commands and repository tests execute code. A passing configured check is
  limited evidence, not a guarantee of correctness or independent acceptance.
- Captures exclude ignored new files and a documented set of credential filenames.
  They are not a secret scanner. Tracked sensitive files, logs, native configuration,
  and retained workspaces require appropriate handling before sharing artifacts.
- The legacy Compose runtime has a different boundary and uses Claude's
  `--dangerously-skip-permissions`. See the legacy documentation before using it.
