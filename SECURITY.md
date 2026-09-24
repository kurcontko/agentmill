# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/kurcontko/agentmill/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

Include a description, reproduction steps, the impact you expect, and a suggested
fix if you have one. You can expect an acknowledgement within 48 hours and an
initial assessment within a week; fixes are best effort, depending on severity.

Only the latest release is supported with security fixes.

## Threat model

AgentMill runs a coding agent unattended. Treat the agent, its model output, the
repository's content (docs, issues, tests, dependencies) and the candidate code it
produces as **untrusted**: any of them can carry a prompt injection or malicious
code.

### What AgentMill protects

- **Your machine.** Docker is the execution boundary. Workers and checks run as
  your numeric UID/GID with all capabilities dropped and `no-new-privileges`. The
  source checkout, the Docker socket, run records and the snapshot store are never
  mounted into a worker.
- **Your checkout.** Input is a committed revision cloned into private storage.
  AgentMill never modifies, resets, stashes, merges or pushes your checkout.
- **Host Git.** Host Git never runs against worker-controlled Git metadata, so
  hooks, `core.fsmonitor` and other config written by the agent do not execute on
  the host. The supervisor captures bytes with its own repository and index.
- **The verdict.** Checks run on the captured snapshot in fresh containers with no
  agent credentials. `--check-dir` keeps held-out checks out of the worker. A
  claimed `done` never completes a run without passing checks.

### What AgentMill does not protect

- **Network egress is open.** Workers and check containers can reach any host. A
  prompt-injected agent can send anything it can read to any server: the
  repository, its history, and the credential you selected.
- **Credentials are visible to the worker.** The selected environment variables,
  or a copy of the selected Codex `auth.json`, are readable inside the worker for
  the whole session.
- **Setup and checks execute candidate code** with network access. They receive no
  agent credentials, but can read the candidate and any `--check-dir` files.
- **Containers are not VMs.** A kernel or container-runtime vulnerability could
  allow escape. Docker Desktop and Colima add a VM boundary on macOS; on Linux,
  consider rootless Docker or a VM.
- **No resource quotas.** Time and session limits are enforced; CPU, memory, disk
  and provider spend are not.
- **Capture exclusions are filename-based**, not a secret scanner. Logs, retained
  workspaces and exported artifacts can contain sensitive data.

### Recommended practice

- Use a dedicated, low-limit API key or short-lived token for AgentMill runs, and
  rotate it if a run behaves unexpectedly.
- Do not run AgentMill on repositories whose content or history holds secrets you
  cannot afford to disclose.
- Where you need egress control today, run AgentMill against a Docker daemon whose
  network is restricted by a firewall or proxy.
- Review the exported patch or bundle in a clean checkout before merging.

Egress allowlisting is planned; until it ships, assume every run can reach the
internet.

## Execution profiles

Codex uses an explicit `danger-full-access` profile inside the container, because
nested namespace sandboxing is incompatible with the container restrictions above.
Claude uses `dontAsk` with coding-tool approvals and `--strict-mcp-config`. These
commands are constructed for isolated worker containers, never for unrestricted
execution in a source checkout.
