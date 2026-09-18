import json

from . import events
from ..contracts import AgentReply, Command, RunStopped


class Codex:
    def build_command(self, request):
        argv = ["codex", "exec", "--json", "--output-schema", "/inputs/reply.schema.json",
                "--output-last-message", "/scratch/reply.json", "--sandbox", "danger-full-access",
                "-c", 'approval_policy="never"', "--color", "never"]
        if request.model:
            argv += ["--model", request.model]
        if request.profile:
            argv += ["--profile", request.profile]
        return Command(tuple([*argv, "-"]), reply_path="/scratch/reply.json")

    def parse_result(self, output):
        terminal = None
        message = None
        started = False
        for event in events(output):
            kind = event.get("type")
            if terminal is not None:
                raise RunStopped("output_after_native_terminal")
            if kind in ("turn.failed", "error"):
                raise RunStopped("native_turn_failed")
            if kind == "turn.started":
                if started:
                    raise RunStopped("multiple_native_turns")
                started = True
            if kind == "item.completed":
                item = event.get("item")
                if isinstance(item, dict) and item.get("type") == "agent_message":
                    message = item.get("text")
            if kind == "turn.completed":
                terminal = event
        if not started or terminal is None or not isinstance(message, str):
            raise RunStopped("invalid_native_terminal")
        try:
            reply = AgentReply.parse(json.loads(message))
        except ValueError as error:
            raise RunStopped("invalid_agent_reply") from error
        # Interpret the message in the native stream, never a worker-writable reply file alone.
        return reply, {"source": "codex.turn.completed", "usage": terminal.get("usage"),
                       "cost_usd_estimate": None}
