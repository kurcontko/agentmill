"""
Multi-provider support for benchmark runs.

Provides a unified interface to run coding tasks against different LLM providers.
Each provider adapter handles API auth, tool calling, and response parsing.
"""

import json
import logging
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class ProviderConfig:
    """Configuration for an LLM provider."""
    name: str
    model: str
    api_key_env: str  # env var name for API key
    base_url: str = ""
    input_cost_per_m: float = 0.0  # $/M input tokens
    output_cost_per_m: float = 0.0  # $/M output tokens


# Pre-configured providers
PROVIDERS: dict[str, ProviderConfig] = {
    "claude": ProviderConfig(
        name="claude",
        model="haiku",
        api_key_env="ANTHROPIC_API_KEY",
        base_url="https://api.anthropic.com",
        input_cost_per_m=1.00,
        output_cost_per_m=5.00,
    ),
    "claude-sonnet": ProviderConfig(
        name="claude",
        model="sonnet",
        api_key_env="ANTHROPIC_API_KEY",
        base_url="https://api.anthropic.com",
        input_cost_per_m=3.00,
        output_cost_per_m=15.00,
    ),
    "deepseek": ProviderConfig(
        name="deepseek",
        model="deepseek-chat",
        api_key_env="DEEPSEEK_API_KEY",
        base_url="https://api.deepseek.com/v1",
        input_cost_per_m=0.28,
        output_cost_per_m=0.42,
    ),
    "glm4-flash": ProviderConfig(
        name="zhipu",
        model="glm-4.7-flash",
        api_key_env="ZHIPU_API_KEY",
        base_url="https://open.bigmodel.cn/api/paas/v4",
        input_cost_per_m=0.07,
        output_cost_per_m=0.40,
    ),
    "gemini-flash": ProviderConfig(
        name="google",
        model="gemini-2.5-flash",
        api_key_env="GOOGLE_API_KEY",
        base_url="https://generativelanguage.googleapis.com/v1beta",
        input_cost_per_m=0.30,
        output_cost_per_m=2.50,
    ),
    "gemini3-flash": ProviderConfig(
        name="google",
        model="gemini-3-flash-preview",
        api_key_env="GOOGLE_API_KEY",
        base_url="https://generativelanguage.googleapis.com/v1beta",
        input_cost_per_m=0.50,
        output_cost_per_m=3.00,
    ),
    "qwen-coder": ProviderConfig(
        name="qwen",
        model="qwen3-coder-plus",
        api_key_env="DASHSCOPE_API_KEY",
        base_url="https://dashscope.aliyuncs.com/compatible-mode/v1",
        input_cost_per_m=0.65,
        output_cost_per_m=3.25,
    ),
    "codestral": ProviderConfig(
        name="mistral",
        model="codestral-latest",
        api_key_env="MISTRAL_API_KEY",
        base_url="https://api.mistral.ai/v1",
        input_cost_per_m=0.30,
        output_cost_per_m=0.90,
    ),
    "gpt4o-mini": ProviderConfig(
        name="openai",
        model="gpt-4o-mini",
        api_key_env="OPENAI_API_KEY",
        base_url="https://api.openai.com/v1",
        input_cost_per_m=0.15,
        output_cost_per_m=0.60,
    ),
}


def get_provider(name: str) -> ProviderConfig:
    """Get a provider config by name, with optional model override."""
    if name not in PROVIDERS:
        available = ", ".join(sorted(PROVIDERS.keys()))
        raise ValueError(f"Unknown provider '{name}'. Available: {available}")
    return PROVIDERS[name]


def list_providers() -> str:
    """Return a formatted table of available providers."""
    lines = [
        f"{'Provider':<16} {'Model':<24} {'$/M in':<8} {'$/M out':<8} {'API Key Env'}",
        f"{'-'*16} {'-'*24} {'-'*8} {'-'*8} {'-'*20}",
    ]
    for key, p in sorted(PROVIDERS.items()):
        lines.append(
            f"{key:<16} {p.model:<24} ${p.input_cost_per_m:<7.2f} ${p.output_cost_per_m:<7.2f} {p.api_key_env}"
        )
    return "\n".join(lines)


def run_with_claude_cli(
    prompt: str,
    model: str,
    cwd: str,
    timeout: int = 600,
) -> tuple[int, str]:
    """Run a task using the Claude CLI (for Claude models)."""
    proc = subprocess.run(
        [
            "claude", "--dangerously-skip-permissions",
            "-p", prompt,
            "--model", model,
        ],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout + proc.stderr


def run_with_openai_compat(
    prompt: str,
    provider: ProviderConfig,
    cwd: str,
    timeout: int = 600,
) -> tuple[int, str, dict]:
    """
    Run a coding task using an OpenAI-compatible API.

    Returns (exit_code, output_text, usage_dict).
    Uses tool calling to let the model edit files.
    """
    try:
        from openai import OpenAI
    except ImportError:
        logger.error("Install openai package: pip install openai")
        return 1, "openai package not installed", {}

    api_key = os.environ.get(provider.api_key_env, "")
    if not api_key:
        return 1, f"Set {provider.api_key_env} env var", {}

    client = OpenAI(api_key=api_key, base_url=provider.base_url)

    tools = [
        {
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "Read the contents of a file",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string", "description": "File path relative to repo root"}
                    },
                    "required": ["path"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "write_file",
                "description": "Write content to a file (creates or overwrites)",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string", "description": "File path relative to repo root"},
                        "content": {"type": "string", "description": "File content to write"},
                    },
                    "required": ["path", "content"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "run_command",
                "description": "Run a shell command in the repo directory",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "command": {"type": "string", "description": "Shell command to execute"},
                    },
                    "required": ["command"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "list_files",
                "description": "List files matching a glob pattern",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "pattern": {"type": "string", "description": "Glob pattern (e.g. 'src/**/*.py')"},
                    },
                    "required": ["pattern"],
                },
            },
        },
    ]

    messages = [{"role": "user", "content": prompt}]
    total_usage = {"input_tokens": 0, "output_tokens": 0}
    output_parts = []
    max_tool_rounds = 30  # prevent infinite loops

    for _round in range(max_tool_rounds):
        try:
            response = client.chat.completions.create(
                model=provider.model,
                messages=messages,
                tools=tools,
                tool_choice="auto",
                max_tokens=8192,
                timeout=timeout,
            )
        except Exception as e:
            return 1, f"API error: {e}", total_usage

        choice = response.choices[0]
        msg = choice.message

        if response.usage:
            total_usage["input_tokens"] += response.usage.prompt_tokens
            total_usage["output_tokens"] += response.usage.completion_tokens

        # Collect text content
        if msg.content:
            output_parts.append(msg.content)

        # No tool calls — model is done
        if not msg.tool_calls:
            break

        # Process tool calls
        messages.append(msg)
        for tc in msg.tool_calls:
            fn_name = tc.function.name
            try:
                args = json.loads(tc.function.arguments)
            except json.JSONDecodeError:
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": "Error: invalid JSON arguments",
                })
                continue

            result = _execute_tool(fn_name, args, cwd)
            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": result[:10000],  # truncate long outputs
            })

    return 0, "\n".join(output_parts), total_usage


def _execute_tool(name: str, args: dict, cwd: str) -> str:
    """Execute a tool call in the repo directory."""
    import glob as glob_mod

    try:
        if name == "read_file":
            path = Path(cwd) / args["path"]
            if not path.exists():
                return f"Error: file not found: {args['path']}"
            return path.read_text(errors="replace")[:50000]

        elif name == "write_file":
            path = Path(cwd) / args["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(args["content"])
            return f"Written {len(args['content'])} chars to {args['path']}"

        elif name == "run_command":
            proc = subprocess.run(
                args["command"],
                shell=True,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=120,
            )
            output = proc.stdout + proc.stderr
            return output[:10000] if output else "(no output)"

        elif name == "list_files":
            pattern = str(Path(cwd) / args["pattern"])
            matches = sorted(glob_mod.glob(pattern, recursive=True))
            # Return relative paths
            rel = [str(Path(m).relative_to(cwd)) for m in matches]
            return "\n".join(rel[:200]) if rel else "(no matches)"

        else:
            return f"Unknown tool: {name}"

    except subprocess.TimeoutExpired:
        return "Error: command timed out (120s)"
    except Exception as e:
        return f"Error: {e}"


def estimate_cost(usage: dict, provider: ProviderConfig) -> float:
    """Estimate cost in dollars from token usage."""
    input_cost = (usage.get("input_tokens", 0) / 1_000_000) * provider.input_cost_per_m
    output_cost = (usage.get("output_tokens", 0) / 1_000_000) * provider.output_cost_per_m
    return input_cost + output_cost
