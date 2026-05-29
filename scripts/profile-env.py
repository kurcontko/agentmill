#!/usr/bin/env python3
"""Render an AgentMill TOML role profile as shell-safe env exports."""

from __future__ import annotations

import argparse
import shlex
import sys
import tomllib
from pathlib import Path
from typing import Any


FIELD_MAP = {
    "client": "AGENTMILL_CLIENT",
    "provider": "AGENTMILL_PROVIDER",
    "prompt_file": "PROMPT_FILE",
    "model": "MODEL",
    "branch_pattern": "AGENT_BRANCH",
    "max_iterations": "MAX_ITERATIONS",
    "loop_delay": "LOOP_DELAY",
    "max_wall_seconds": "MAX_WALL_SECONDS",
    "max_log_bytes": "MAX_LOG_BYTES",
    "profile_level": "AGENTMILL_PROFILE_LEVEL",
    "auto_commit_mode": "AUTO_COMMIT",
    "ralph_max_iterations": "AUTO_RALPH_MAX_ITERATIONS",
    "completion_gate": "AGENTMILL_COMPLETION_GATE",
    "verifier_command": "AGENTMILL_VERIFIER_COMMAND",
    "coder_open_questions_max": "AGENTMILL_CODER_OPEN_QUESTIONS_MAX",
    "refactor_loc_target": "AGENTMILL_REFACTOR_LOC_TARGET",
    "refactor_loc_tolerance": "AGENTMILL_REFACTOR_LOC_TOLERANCE",
    "refactor_max_loc_delta": "AGENTMILL_REFACTOR_MAX_LOC_DELTA",
    "research_saturation_iterations": "AGENTMILL_RESEARCH_SATURATION_ITERATIONS",
    "research_open_questions_max": "AGENTMILL_RESEARCH_OPEN_QUESTIONS_MAX",
    "network": "AGENTMILL_NETWORK",
    "write_roots": "AGENTMILL_WRITE_ROOTS",
    "shell_allowlist": "AGENTMILL_SHELL_ALLOWLIST",
    "shell_denylist": "AGENTMILL_SHELL_DENYLIST",
    "mcp_allowlist": "AGENTMILL_MCP_ALLOWLIST",
    "skill_allowlist": "AGENTMILL_SKILL_ALLOWLIST",
    "forward_host_mcp": "AGENTMILL_FORWARD_HOST_MCP",
    "forward_host_tools": "AGENTMILL_FORWARD_HOST_TOOLS",
    "forward_host_hooks": "AGENTMILL_FORWARD_HOST_HOOKS",
    "forward_host_env": "AGENTMILL_FORWARD_HOST_ENV",
    "forward_host_extensions": "AGENTMILL_FORWARD_HOST_EXTENSIONS",
}

STRING_FIELDS = {
    "prompt_file",
    "client",
    "provider",
    "model",
    "branch_pattern",
    "profile_level",
    "auto_commit_mode",
    "completion_gate",
    "verifier_command",
    "network",
}
INT_FIELDS = {
    "max_iterations",
    "loop_delay",
    "max_wall_seconds",
    "max_log_bytes",
    "ralph_max_iterations",
    "coder_open_questions_max",
    "refactor_loc_tolerance",
    "research_saturation_iterations",
    "research_open_questions_max",
}
SIGNED_INT_FIELDS = {"refactor_loc_target", "refactor_max_loc_delta"}
LIST_FIELDS = {"mcp_allowlist", "skill_allowlist", "shell_allowlist", "shell_denylist", "write_roots"}
BOOL_FIELDS = {
    "forward_host_mcp",
    "forward_host_tools",
    "forward_host_hooks",
    "forward_host_env",
    "forward_host_extensions",
}
VALID_PROFILE_LEVELS = {"trusted", "standard", "untrusted"}


def die(message: str) -> None:
    print(f"profile-env: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_profile(path: Path) -> dict[str, Any]:
    if not path.is_file():
        die(f"profile not found: {path}")
    try:
        data = tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as exc:
        die(f"invalid TOML in {path}: {exc}")
    if not isinstance(data, dict):
        die(f"profile must be a TOML table: {path}")
    unknown = sorted(set(data) - set(FIELD_MAP) - {"description"})
    if unknown:
        die(f"unknown profile fields in {path}: {', '.join(unknown)}")
    return data


def normalize_value(key: str, value: Any, role: str, agent_id: str) -> str:
    if key in STRING_FIELDS:
        if not isinstance(value, str):
            die(f"{key} must be a string")
        rendered = value.format(role=role, agent_id=agent_id)
        if key == "profile_level" and rendered not in VALID_PROFILE_LEVELS:
            die(f"profile_level must be one of: {', '.join(sorted(VALID_PROFILE_LEVELS))}")
        return rendered

    if key in INT_FIELDS:
        if not isinstance(value, int) or value < 0:
            die(f"{key} must be a non-negative integer")
        return str(value)

    if key in SIGNED_INT_FIELDS:
        if not isinstance(value, int):
            die(f"{key} must be an integer")
        return str(value)

    if key in LIST_FIELDS:
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            die(f"{key} must be a list of strings")
        return ",".join(value)

    if key in BOOL_FIELDS:
        if not isinstance(value, bool):
            die(f"{key} must be a boolean")
        return "true" if value else "false"

    die(f"unsupported field: {key}")


def shell_export(name: str, value: str) -> str:
    return f"export {name}={shlex.quote(value)}"


def shell_default_export(name: str, value: str, fallback_name: str | None = None) -> str:
    if fallback_name:
        return (
            f'if [[ -z "${{{name}:-}}" && -z "${{{fallback_name}:-}}" ]]; '
            f"then export {name}={shlex.quote(value)}; fi"
        )
    return f'if [[ -z "${{{name}:-}}" ]]; then export {name}={shlex.quote(value)}; fi'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", type=Path)
    parser.add_argument("--role", required=True)
    parser.add_argument("--agent-id", default="1")
    parser.add_argument("--suffix", default="")
    parser.add_argument(
        "--defaults",
        action="store_true",
        help="emit conditional exports so existing env values override profile fields",
    )
    args = parser.parse_args()

    data = load_profile(args.profile)
    suffix = args.suffix
    role = args.role
    agent_id = args.agent_id

    print(shell_export(f"AGENTMILL_ROLE{suffix}", role))
    for key, env_name in FIELD_MAP.items():
        if key not in data:
            continue
        value = normalize_value(key, data[key], role, agent_id)
        target = f"{env_name}{suffix}"
        if args.defaults:
            print(shell_default_export(target, value, env_name if suffix else None))
        else:
            print(shell_export(target, value))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
