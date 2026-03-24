#!/usr/bin/env python3
"""
Thin agent runner for AgentMill.

Single run(command="...") tool, any OpenAI-compatible API, ~2-3k token overhead.
Stdlib only — no third-party dependencies.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from argparse import ArgumentParser

# — Configuration ——————————————————————————————————————————————
MAX_OUTPUT_LINES = 200
MAX_OUTPUT_BYTES = 50_000
BINARY_CHECK_BYTES = 512
COMMAND_TIMEOUT = 120

SYSTEM_PROMPT = """\
You are a coding agent. You have one tool: run(command="...") which executes shell commands.

Use standard Unix tools to explore and modify code:
  ls, find, cat, head, tail, grep, sed, awk     — read & search
  tee, patch, ed                                  — write & edit
  python3, node, bash                             — run code
  git diff, git log, git add, git commit          — version control
  curl, wget                                      — fetch URLs

Compose commands with pipes and operators:
  |   pipe stdout    &&  run if success    ||  run if failure    ;  run always

Tips:
- Start by exploring: ls, then cat key files
- Use grep to search across files: grep -rn "pattern" .
- For large files, use head/tail/grep instead of cat
- Write files with: cat > path <<'EOF' ... EOF
- Check your work: run tests, git diff
- Commit when done: git add -A && git commit -m "description"
"""

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "run",
            "description": "Execute a shell command and return stdout/stderr",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Shell command to execute (supports pipes, &&, ||, ;)",
                    }
                },
                "required": ["command"],
            },
        },
    }
]


# — Layer 1: Unix execution ———————————————————————————————————
def execute_command(command: str, cwd: str) -> tuple[bytes, bytes, int, float]:
    """Execute command, return (stdout, stderr, exit_code, duration_seconds)."""
    start = time.monotonic()
    try:
        # NOSONAR — shell=True is intentional: this tool's purpose is executing arbitrary shell commands
        proc = subprocess.run(
            command,
            shell=True,  # noqa: S603
            cwd=cwd,
            capture_output=True,
            timeout=COMMAND_TIMEOUT,
        )
        elapsed = time.monotonic() - start
        return proc.stdout, proc.stderr, proc.returncode, elapsed
    except subprocess.TimeoutExpired:
        elapsed = time.monotonic() - start
        return b"", f"Command timed out after {COMMAND_TIMEOUT}s".encode(), 124, elapsed


# — Layer 2: LLM presentation —————————————————————————————————
def is_binary(data: bytes) -> bool:
    """Check if data looks like binary content."""
    if not data:
        return False
    chunk = data[:BINARY_CHECK_BYTES]
    if b"\x00" in chunk:
        return True
    # High ratio of non-text control characters
    control_count = sum(1 for b in chunk if b < 32 and b not in (9, 10, 13))
    return control_count / max(len(chunk), 1) > 0.10


def format_size(n: int) -> str:
    """Human-readable byte size."""
    if n < 1024:
        return f"{n}B"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f}KB"
    return f"{n / (1024 * 1024):.1f}MB"


def present_output(stdout: bytes, stderr: bytes, exit_code: int, elapsed: float) -> str:
    """Layer 2: transform raw output for LLM consumption."""
    parts = []

    # Binary guard
    if is_binary(stdout):
        parts.append(f"[binary output, {format_size(len(stdout))}]")
    elif stdout:
        text = stdout.decode("utf-8", errors="replace")
        lines = text.splitlines(keepends=True)

        if len(lines) > MAX_OUTPUT_LINES or len(stdout) > MAX_OUTPUT_BYTES:
            # Overflow: truncate and provide exploration hints
            truncated = "".join(lines[:MAX_OUTPUT_LINES])
            if len(truncated.encode()) > MAX_OUTPUT_BYTES:
                truncated = truncated[:MAX_OUTPUT_BYTES]
            parts.append(truncated.rstrip())
            parts.append(
                f"\n--- output truncated ({len(lines)} lines, {format_size(len(stdout))}) ---"
            )
        else:
            parts.append(text.rstrip())

    # Stderr attachment (on failure, or if stderr has content and stdout is empty)
    if stderr and (exit_code != 0 or not stdout):
        stderr_text = stderr.decode("utf-8", errors="replace")[:2000]
        if parts:
            parts.append(f"\n[stderr] {stderr_text.rstrip()}")
        else:
            parts.append(stderr_text.rstrip())

    # Metadata footer
    if elapsed >= 1.0:
        duration = f"{elapsed:.1f}s"
    else:
        duration = f"{elapsed * 1000:.0f}ms"

    result = "\n".join(parts) if parts else "(no output)"
    return f"{result}\n[exit:{exit_code} | {duration}]"


# — API client (stdlib only) ——————————————————————————————————
def chat_completion(
    messages: list[dict],
    model: str,
    base_url: str,
    api_key: str,
    tools: list[dict] | None = None,
    max_tokens: int = 16384,
) -> dict:
    """POST to /v1/chat/completions, return parsed response."""
    url = f"{base_url.rstrip('/')}/chat/completions"

    body: dict = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
    }
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"

    data = json.dumps(body).encode()
    req = urllib.request.Request(  # NOSONAR — URL is user-configured API endpoint
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",  # NOSONAR — API key from env/CLI, not hardcoded
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=300) as resp:  # NOSONAR
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8", errors="replace")[:1000]
        raise RuntimeError(f"API error {e.code}: {error_body}") from e


def extract_tool_calls(message: dict) -> list[dict]:
    """Extract tool calls from an assistant message."""
    return message.get("tool_calls") or []


def extract_text(message: dict) -> str:
    """Extract text content from an assistant message."""
    return message.get("content") or ""


# — Agent loop ————————————————————————————————————————————————
def run_agent(
    prompt: str,
    model: str,
    base_url: str,
    api_key: str,
    cwd: str,
    max_rounds: int = 50,
    verbose: bool = False,
) -> str:
    """Run the agent loop. Returns the final text response."""
    messages: list[dict] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": prompt},
    ]

    final_text = ""

    for round_num in range(max_rounds):
        if verbose:
            print(f"[thin] round {round_num + 1}/{max_rounds}", file=sys.stderr)

        try:
            response = chat_completion(messages, model, base_url, api_key, tools=TOOLS)
        except Exception as e:
            print(f"[thin] API error: {e}", file=sys.stderr)
            break

        choice = response.get("choices", [{}])[0]
        msg = choice.get("message", {})
        finish_reason = choice.get("finish_reason", "")

        # Extract text
        text = extract_text(msg)
        if text:
            final_text = text
            if verbose:
                print(f"[thin] text: {text[:200]}...", file=sys.stderr)

        # Extract tool calls
        tool_calls = extract_tool_calls(msg)

        if not tool_calls:
            # Model is done
            break

        # Append assistant message (with tool calls) to history
        messages.append(msg)

        # Execute each tool call
        for tc in tool_calls:
            fn = tc.get("function", {})
            tc_id = tc.get("id", "")
            fn_name = fn.get("name", "")

            try:
                args = json.loads(fn.get("arguments", "{}"))
            except json.JSONDecodeError:
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc_id,
                    "content": "[error] Invalid JSON arguments",
                })
                continue

            command = args.get("command", "")
            if not command:
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc_id,
                    "content": "[error] run: usage: run <command>",
                })
                continue

            if verbose:
                print(f"[thin] run: {command[:120]}", file=sys.stderr)

            # Layer 1: execute
            stdout, stderr, exit_code, elapsed = execute_command(command, cwd)

            # Layer 2: present
            result = present_output(stdout, stderr, exit_code, elapsed)

            messages.append({
                "role": "tool",
                "tool_call_id": tc_id,
                "content": result,
            })

        # Log usage if available
        usage = response.get("usage", {})
        if usage and verbose:
            print(
                f"[thin] tokens: in={usage.get('prompt_tokens', '?')} "
                f"out={usage.get('completion_tokens', '?')}",
                file=sys.stderr,
            )

    return final_text


# — CLI entrypoint ————————————————————————————————————————————
def main():
    parser = ArgumentParser(description="Thin agent runner for AgentMill")
    parser.add_argument("--prompt", "-p", required=True, help="Task prompt")
    parser.add_argument("--model", "-m", default=os.environ.get("MODEL", "gpt-4o-mini"))
    parser.add_argument(
        "--base-url",
        default=os.environ.get("THIN_BASE_URL", os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1")),
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("THIN_API_KEY", os.environ.get("OPENAI_API_KEY", "")),
    )
    parser.add_argument("--max-rounds", type=int, default=int(os.environ.get("THIN_MAX_ROUNDS", "50")))
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--verbose", "-v", action="store_true", default=os.environ.get("THIN_VERBOSE", "") != "")

    args = parser.parse_args()

    if not args.api_key:
        print("[thin] ERROR: No API key. Set --api-key, THIN_API_KEY, or OPENAI_API_KEY", file=sys.stderr)
        sys.exit(1)

    result = run_agent(
        prompt=args.prompt,
        model=args.model,
        base_url=args.base_url,
        api_key=args.api_key,
        cwd=args.cwd,
        max_rounds=args.max_rounds,
        verbose=args.verbose,
    )

    # Print final response to stdout (captured by entrypoint.sh)
    if result:
        print(result)


if __name__ == "__main__":
    main()
