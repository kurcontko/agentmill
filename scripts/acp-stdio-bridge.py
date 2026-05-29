#!/usr/bin/env python3
"""Minimal Agent Client Protocol stdio bridge for AgentMill.

This is intentionally small: it initializes an ACP agent subprocess, creates a
session, sends one text prompt, and mirrors raw JSON-RPC traffic to stdout for
AgentMill's existing session log/event extraction path. It does not expose
filesystem or terminal capabilities; requests for those are rejected.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--client-name", default="agentmill")
    parser.add_argument("--client-version", default="0.1.0")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("missing ACP agent command after --")
    return args


def write_json(proc: subprocess.Popen[str], message: dict[str, Any]) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    proc.stdin.flush()
    print(json.dumps({"direction": "client_to_agent", "message": message}, separators=(",", ":")), flush=True)


def respond_error(proc: subprocess.Popen[str], msg_id: Any, message: str) -> None:
    write_json(
        proc,
        {
            "jsonrpc": "2.0",
            "id": msg_id,
            "error": {"code": -32601, "message": message},
        },
    )


def respond_permission_cancelled(proc: subprocess.Popen[str], msg_id: Any) -> None:
    write_json(
        proc,
        {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"outcome": {"outcome": "cancelled"}},
        },
    )


def stderr_thread(proc: subprocess.Popen[str]) -> None:
    assert proc.stderr is not None
    for line in proc.stderr:
        print(json.dumps({"direction": "agent_stderr", "line": line.rstrip("\n")}, separators=(",", ":")), flush=True)


def read_message(proc: subprocess.Popen[str]) -> dict[str, Any]:
    assert proc.stdout is not None
    while True:
        line = proc.stdout.readline()
        if line == "":
            raise RuntimeError("ACP agent exited before responding")
        line = line.rstrip("\n")
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            print(json.dumps({"direction": "agent_stdout_invalid", "line": line}, separators=(",", ":")), flush=True)
            continue
        print(json.dumps({"direction": "agent_to_client", "message": message}, separators=(",", ":")), flush=True)
        return message


def wait_for_response(proc: subprocess.Popen[str], msg_id: int) -> dict[str, Any]:
    while True:
        message = read_message(proc)
        if message.get("id") == msg_id and ("result" in message or "error" in message):
            if "error" in message:
                raise RuntimeError(f"ACP request {msg_id} failed: {message['error']}")
            result = message.get("result")
            return result if isinstance(result, dict) else {}
        if "id" in message and "method" in message:
            method = str(message.get("method"))
            if method == "session/request_permission":
                respond_permission_cancelled(proc, message.get("id"))
            else:
                respond_error(proc, message.get("id"), f"AgentMill ACP bridge does not implement {method}")


def main() -> int:
    args = parse_args()
    proc = subprocess.Popen(
        args.command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        cwd=args.cwd,
    )
    threading.Thread(target=stderr_thread, args=(proc,), daemon=True).start()

    try:
        write_json(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 0,
                "method": "initialize",
                "params": {
                    "protocolVersion": 1,
                    "clientCapabilities": {
                        "fs": {"readTextFile": False, "writeTextFile": False},
                        "terminal": False,
                    },
                    "clientInfo": {
                        "name": args.client_name,
                        "title": "AgentMill",
                        "version": args.client_version,
                    },
                },
            },
        )
        init = wait_for_response(proc, 0)
        if init.get("authMethods"):
            raise RuntimeError("ACP authMethods are not supported by the minimal AgentMill bridge")

        write_json(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "session/new",
                "params": {"cwd": args.cwd, "mcpServers": []},
            },
        )
        session = wait_for_response(proc, 1)
        session_id = session.get("sessionId")
        if not session_id:
            raise RuntimeError("ACP session/new did not return sessionId")

        write_json(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "session/prompt",
                "params": {
                    "sessionId": session_id,
                    "prompt": [{"type": "text", "text": args.prompt}],
                },
            },
        )
        wait_for_response(proc, 2)
    except Exception as exc:
        print(json.dumps({"direction": "bridge_error", "error": str(exc)}, separators=(",", ":")), flush=True)
        proc.kill()
        return 2
    finally:
        try:
            proc.stdin.close()  # type: ignore[union-attr]
        except Exception:
            pass
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
    return proc.returncode or 0


if __name__ == "__main__":
    raise SystemExit(main())
