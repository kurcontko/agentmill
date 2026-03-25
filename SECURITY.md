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

- Containers run Claude Code with `--dangerously-skip-permissions` by design. This is intentional for autonomous operation inside isolated containers and should **never** be used outside a container boundary.
- Agents have full read/write access to the mounted repository. Do not mount sensitive host directories.
- API keys (`ANTHROPIC_API_KEY`) are passed via environment variables. Use Docker secrets or a vault in production.
