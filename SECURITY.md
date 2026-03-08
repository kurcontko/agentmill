# Security Policy

## Security Model

AgentMill runs Claude Code with `--dangerously-skip-permissions` inside an isolated Docker container. This is intentional — autonomous operation requires full tool access. The container boundary is the security perimeter.

**Key design decisions:**
- Container runs as non-root user (`agent`)
- No secrets are stored in the image or committed to git
- Host config is mounted read-only where possible
- Resource limits prevent runaway consumption

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public issue**
2. Email the maintainers or use GitHub's private vulnerability reporting
3. Include steps to reproduce and potential impact

## Best Practices for Users

- **Never commit `.env`** — it contains auth tokens. The `.gitignore` excludes it.
- **Use deploy keys** over mounting `~/.ssh` for private repos
- **Set resource limits** in docker-compose.yml to prevent DoS
- **Rotate tokens regularly** — OAuth tokens and API keys should be refreshed
- **Review session logs** — logs may contain sensitive output from Claude sessions
- **Network isolation** — consider running containers with `--network=none` if the task doesn't require internet
