"""Only native command construction and terminal-result interpretation live here."""

import json
from typing import Protocol

from ..contracts import AgentReply, Command, ProcessOutput, RunStopped, SessionRequest


class Adapter(Protocol):
    def build_command(self, request: SessionRequest) -> Command: ...
    def parse_result(self, output: ProcessOutput) -> tuple[AgentReply, dict]: ...


def events(output):
    if output.returncode != 0 or output.stop_reason:
        raise RunStopped("native_session_failed")
    try:
        with output.stdout.open(encoding="utf-8") as stream:
            for line in stream:
                if line.strip():
                    event = json.loads(line)
                    if not isinstance(event, dict):
                        raise ValueError("native event must be an object")
                    yield event
    except (ValueError, UnicodeError, RecursionError) as error:
        raise RunStopped("invalid_native_output") from error


def get_adapter(name):
    from .claude import Claude
    from .codex import Codex
    return {"claude": Claude, "codex": Codex}[name]()
