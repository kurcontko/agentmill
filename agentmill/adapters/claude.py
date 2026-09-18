import json

from . import events
from ..contracts import AgentReply, Command, REPLY_SCHEMA, RunStopped


class Claude:
    def build_command(self, request):
        argv = ["claude", "-p", "--output-format", "stream-json", "--verbose",
                "--json-schema", json.dumps(REPLY_SCHEMA), "--permission-mode", "dontAsk",
                "--allowedTools", "Bash,Read,Edit,Write,Glob,Grep"]
        if request.model:
            argv += ["--model", request.model]
        if request.agent_config:
            argv += ["--settings", "/native/config"]
        return Command(tuple(argv))

    def parse_result(self, output):
        terminal = None
        for event in events(output):
            if terminal is not None:
                raise RunStopped("output_after_native_terminal")
            if event.get("type") == "result":
                terminal = event
        if (terminal is None or terminal.get("subtype") != "success"
                or terminal.get("is_error") is not False):
            raise RunStopped("invalid_native_terminal")
        reply = AgentReply.parse(terminal.get("structured_output"))
        telemetry = {"source": "claude.result", "usage": terminal.get("usage"),
                     "model_usage": terminal.get("modelUsage"),
                     "cost_usd_estimate": terminal.get("total_cost_usd")}
        return reply, telemetry
