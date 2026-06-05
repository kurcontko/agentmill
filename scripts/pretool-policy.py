#!/usr/bin/env python3
"""Claude Code PreToolUse policy gate for AgentMill.

Reads Claude hook JSON on stdin. Prints a structured denial JSON only when a
tool call violates AgentMill policy; otherwise exits silently with success.
"""

from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import shlex
import sys
import time
from pathlib import Path, PurePosixPath
from typing import Any


HIGH_RISK_PATHS: tuple[tuple[str, str], ...] = (
    ("ci-workflow", r"^\.github/workflows/"),
    ("git-hook", r"^\.git/hooks/"),
    ("mcp-config", r"(^|/)\.mcp\.json$"),
    ("claude-config", r"(^|/)\.claude/"),
    ("codex-config", r"(^|/)\.codex/"),
    ("env-file", r"(^|/)\.env(\.|$|/)"),
    ("container-config", r"(^|/)(Dockerfile|docker-compose[^/]*\.ya?ml)$"),
    ("package-script", r"(^|/)(package\.json|pnpm-workspace\.yaml|Makefile)$"),
    ("deploy-script", r"(^|/)(deploy|release|infra|terraform|ansible)(/|$)"),
    ("secret-path", r"(^|/)(secrets?|credentials?|\.ssh|\.aws|\.azure)(/|$)"),
)

HIGH_RISK_SHELL_DENY = [
    "sudo:*",
    "su:*",
    "rm -rf:*",
    "chmod:*",
    "chown:*",
    "dd:*",
    "mkfs:*",
    "mount:*",
    "umount:*",
    "docker:*",
    "podman:*",
    "kubectl:*",
    "helm:*",
]
SHELL_NETWORK_DENY = [
    "curl:*",
    "wget:*",
    "nc:*",
    "ncat:*",
    "netcat:*",
    "telnet:*",
    "ftp:*",
    "sftp:*",
    "scp:*",
    "rsync:*",
]
STRICT_NETWORK_DENY = [
    "git clone:*",
    "git fetch:*",
    "git pull:*",
    "git push:*",
    "npm install:*",
    "pnpm install:*",
    "yarn install:*",
    "pip install:*",
    "uv sync:*",
    "uv pip install:*",
    "cargo fetch:*",
    "cargo install:*",
    "go mod download:*",
]


def truthy(value: str | None) -> bool:
    return (value or "").lower() in {"1", "true", "yes", "on"}


def items(raw: str | None) -> list[str]:
    return [item.strip() for item in (raw or "").split(",") if item.strip()]


def deny(reason: str, **payload: Any) -> None:
    detail = {
        "reason": reason,
        "profile": os.environ.get("AGENTMILL_PROFILE_LEVEL", "trusted"),
        "tool_name": payload.get("tool_name", ""),
        **payload,
    }
    append_event(detail)
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": permission_reason(detail),
                }
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )


def permission_reason(detail: dict[str, Any]) -> str:
    reason = str(detail.get("reason", "policy_denied"))
    tool = str(detail.get("tool_name", "tool"))
    if reason == "shell_command_denied":
        return f"AgentMill denied {tool}: shell command violates {detail.get('policy', 'policy')} policy"
    if reason == "mcp_tool_denied":
        return f"AgentMill denied MCP server {detail.get('mcp_server', '')}: not in allowlist"
    if reason == "web_tool_denied":
        return f"AgentMill denied {tool}: web tools are disabled for this profile"
    if reason == "subagent_denied":
        return f"AgentMill denied {tool}: subagents are disabled for this profile"
    if reason == "write_root_violation":
        return f"AgentMill denied {tool}: path is outside configured write roots"
    if reason == "high_risk_path":
        return f"AgentMill denied {tool}: high-risk path requires explicit override"
    return f"AgentMill denied {tool}: {reason}"


def append_event(detail: dict[str, Any]) -> None:
    event_log = os.environ.get("EVENT_LOG")
    if not event_log:
        return
    event_path = Path(event_log)
    try:
        event_path.parent.mkdir(parents=True, exist_ok=True)
        safe = dict(detail)
        if "command" in safe:
            safe["command_hash"] = hashlib.sha256(str(safe.pop("command")).encode()).hexdigest()
        line = {
            "version": 1,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "run_id": os.environ.get("AGENTMILL_RUN_ID", ""),
            "agent_id": os.environ.get("AGENT_ID", "agent"),
            "profile": os.environ.get("AGENTMILL_PROFILE_LEVEL", "trusted"),
            "iteration": int(os.environ.get("ITERATION", "0") or "0"),
            "type": "policy.denied",
            "payload": {"source": "pretool", **safe},
        }
        with event_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(line, sort_keys=True, separators=(",", ":")) + "\n")
    except OSError:
        return


def shell_words(value: str) -> list[str]:
    try:
        return shlex.split(value, posix=True)
    except ValueError:
        return value.split()


def normalize_pattern(pattern: str) -> tuple[str, list[str]]:
    raw = str(pattern or "").strip()
    if raw.startswith("Bash(") and raw.endswith(")"):
        raw = raw[5:-1].strip()
    if raw in {"", "*"}:
        return pattern, ["*"]
    if raw.endswith(":*"):
        raw = raw[:-2].strip()
    elif raw.endswith("*"):
        raw = raw[:-1].strip()
    if raw.endswith(":"):
        raw = raw[:-1].strip()
    return pattern, shell_words(raw) if raw else ["*"]


def pattern_matches(pattern_tokens: list[str], command_tokens: list[str]) -> bool:
    if pattern_tokens == ["*"]:
        return True
    if not pattern_tokens or len(command_tokens) < len(pattern_tokens):
        return False
    return command_tokens[: len(pattern_tokens)] == pattern_tokens


def command_policy(command: str) -> tuple[str, str]:
    profile = os.environ.get("AGENTMILL_PROFILE_LEVEL", "trusted").strip().lower()
    network = os.environ.get("AGENTMILL_NETWORK", "").strip().lower()
    allow_shell_network = truthy(os.environ.get("AGENTMILL_ALLOW_SHELL_NETWORK"))
    shell_allowlist = items(os.environ.get("AGENTMILL_SHELL_ALLOWLIST"))
    shell_denylist = items(os.environ.get("AGENTMILL_SHELL_DENYLIST"))

    deny_patterns = list(shell_denylist)
    if profile != "trusted":
        deny_patterns.extend(HIGH_RISK_SHELL_DENY)
        effective_network = network or ("deny" if profile == "untrusted" else "allowlist")
        if not allow_shell_network and effective_network in {"", "deny", "allowlist"}:
            deny_patterns.extend(SHELL_NETWORK_DENY)
        if effective_network == "deny":
            deny_patterns.extend(STRICT_NETWORK_DENY)

    if profile == "untrusted" and not shell_allowlist:
        shell_default = "deny"
    elif shell_allowlist:
        shell_default = "allowlist"
    else:
        shell_default = "allow"

    tokens = shell_words(command)
    if not tokens:
        return "", ""

    for raw, pattern_tokens in (normalize_pattern(pattern) for pattern in deny_patterns):
        if pattern_matches(pattern_tokens, tokens):
            return "denylist", raw
    if shell_default in {"deny", "allowlist"}:
        for raw, pattern_tokens in (normalize_pattern(pattern) for pattern in shell_allowlist):
            if pattern_matches(pattern_tokens, tokens):
                return "", ""
        return "allowlist", ",".join(shell_allowlist) or "*"
    return "", ""


def mcp_parts(name: str) -> tuple[str, str]:
    if name.startswith("mcp__"):
        parts = name.split("__", 2)
        if len(parts) == 3:
            return parts[1], parts[2]
    if name.startswith("mcp.") and name.count(".") >= 2:
        _, server, tool = name.split(".", 2)
        return server, tool
    return "", ""


def norm_rel(value: str, cwd: str) -> str | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    path = Path(raw)
    if path.is_absolute():
        try:
            raw = str(path.resolve().relative_to(Path(cwd).resolve()))
        except (OSError, ValueError):
            return None
    raw = raw.replace(os.sep, "/")
    posix = PurePosixPath(raw)
    parts = []
    for part in posix.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            return None
        parts.append(part)
    return "/".join(parts) if parts else "."


def path_allowed(path: str, roots: list[str]) -> bool:
    if "." in roots:
        return True
    normalized_roots = [root.strip().strip("/") for root in roots if root.strip()]
    return any(path == root or path.startswith(root + "/") for root in normalized_roots)


def tool_paths(tool_input: Any) -> list[str]:
    if not isinstance(tool_input, dict):
        return []
    values: list[str] = []
    for key in ("file_path", "path", "notebook_path"):
        value = tool_input.get(key)
        if isinstance(value, str):
            values.append(value)
    edits = tool_input.get("edits")
    if isinstance(edits, list):
        for edit in edits:
            if isinstance(edit, dict) and isinstance(edit.get("file_path"), str):
                values.append(edit["file_path"])
    return values


def high_risk_category(path: str) -> str:
    for category, pattern in HIGH_RISK_PATHS:
        if re.search(pattern, path):
            return category
    return ""


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0

    profile = os.environ.get("AGENTMILL_PROFILE_LEVEL", "trusted").strip().lower()
    tool_name = str(data.get("tool_name") or "")
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}

    if tool_name == "Bash":
        command = str(tool_input.get("command") or "")
        policy, matched = command_policy(command)
        if policy:
            deny(
                "shell_command_denied",
                tool_name=tool_name,
                policy=policy,
                matched_pattern=matched,
                argv0=(shell_words(command) or [""])[0],
                command=command,
            )
            return 0

    server, mcp_tool = mcp_parts(tool_name)
    if server:
        allowlist = items(os.environ.get("AGENTMILL_MCP_ALLOWLIST"))
        if profile != "trusted" and (not allowlist or server not in allowlist):
            deny("mcp_tool_denied", tool_name=tool_name, mcp_server=server, mcp_tool=mcp_tool)
            return 0

    if profile != "trusted" and tool_name in {"WebFetch", "WebSearch"}:
        deny("web_tool_denied", tool_name=tool_name)
        return 0

    if profile == "untrusted" and tool_name in {"Agent", "Task", "TaskCreate"}:
        deny("subagent_denied", tool_name=tool_name)
        return 0

    write_tools = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
    if profile != "trusted" and tool_name in write_tools:
        cwd = str(data.get("cwd") or os.environ.get("REPO_DIR") or os.getcwd())
        roots = items(os.environ.get("AGENTMILL_WRITE_ROOTS"))
        for raw_path in tool_paths(tool_input):
            path = norm_rel(raw_path, cwd)
            if path is None:
                deny("write_root_violation", tool_name=tool_name, path=str(raw_path), write_roots=",".join(roots))
                return 0
            if roots and not path_allowed(path, roots):
                deny("write_root_violation", tool_name=tool_name, path=path, write_roots=",".join(roots))
                return 0
            category = high_risk_category(path)
            if category and not truthy(os.environ.get("AGENTMILL_ALLOW_HIGH_RISK_CHANGES")):
                deny("high_risk_path", tool_name=tool_name, path=path, category=category)
                return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
