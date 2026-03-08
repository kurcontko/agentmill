# Troubleshooting

## Authentication

### "ERROR: No auth configured"

Set one of:
- `ANTHROPIC_API_KEY` in `.env` (API credits)
- `CLAUDE_CODE_OAUTH_TOKEN` in `.env` (subscription — get via `claude setup-token`)

### OAuth token expired

Tokens expire. Re-run `claude setup-token` on the host and update `.env`.

## Repo Issues

### "ERROR: No repo found"

The container expects either:
- `/workspace/repo` (single agent): set `REPO_PATH` in `.env` to an absolute path
- `/workspace/upstream` (multi-agent): same, but use `agent-1`/`agent-2`/`agent-3` services

### Permission denied on mounted repo

The container runs as user `agent` (non-root). Ensure the host directory is readable:
```bash
chmod -R a+rX /path/to/your/repo
```

### Git push fails in multi-agent mode

Common causes:
1. **Rebase conflict**: Two agents modified the same file. The agent will retry up to 3 times, then defer to the next iteration.
2. **Read-only upstream**: If upstream is mounted read-only, push will fail. Remove `:ro` from the volume mount.
3. **Branch checked out on host**: Pushing to the currently checked-out branch of a non-bare repo can fail. Agents default to `agent-$ID` branches to avoid this.

## Python Environment

### "No module named X"

The auto-setup only installs what's declared in `pyproject.toml` or `requirements.txt`. For additional tools:
```bash
EXTRA_PYTHON_TOOLS="ruff pytest mypy" docker compose up
```

### Wrong Python version

The container ships with the system Python from `node:20-slim` (Debian). If your project requires a specific Python version, use `REPO_SETUP_COMMAND` to install it:
```bash
REPO_SETUP_COMMAND="apt-get install -y python3.11" docker compose up
```

## Container Issues

### Container shows "healthy" but agent is idle

Check logs:
```bash
tail -f logs/agent-1.log
```

If Claude exits with non-zero codes repeatedly, the agent logs warnings but continues looping. Look for `WARN: Claude exited with code` in logs.

### Out of memory

The default memory limit is 4GB. For large repos or complex tasks, increase in `docker-compose.yml`:
```yaml
deploy:
  resources:
    limits:
      memory: 8g
```

### Logs filling up disk

Enable log rotation by setting:
```bash
LOG_MAX_SIZE=10485760  # 10MB per log file
LOG_MAX_FILES=5        # Keep 5 rotated files
```

Or use JSON structured logging for external log aggregation:
```bash
LOG_FORMAT=json docker compose up
```

## TUI Dashboard

### Dashboard shows blank screen

The TUI requires an interactive terminal:
```bash
docker compose run dashboard  # NOT 'docker compose up dashboard'
```

### Auto-trust dialog appears

If the expect script fails to handle the trust dialog, ensure `auto-trust.exp` is executable and the Claude Code version matches the expected dialog text.

## Debugging

### Enable verbose logging

```bash
LOG_FORMAT=json docker compose up
```

### Inspect a specific session

Session logs are in `logs/session_YYYYMMDD_HHMMSS_iterN.log`. Each file contains the full Claude output for that iteration.

### Test the container manually

```bash
docker compose run --entrypoint bash agent
# Now you're inside the container — run commands manually
```
