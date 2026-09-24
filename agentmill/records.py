"""Supervisor-only, versioned records. An outcome is written once."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import uuid


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(".tmp")
    with temporary.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def runs_root():
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "agentmill/runs"


class Records:
    def __init__(self, root=None, on_event=None):
        self.run_id = "r_" + uuid.uuid4().hex[:16]
        self.directory = (Path(root) if root else runs_root()).resolve() / self.run_id
        self.directory.mkdir(parents=True, mode=0o700)
        self.seq = 0
        self.on_event = on_event
        self.callback_error = None

    def emit(self, event, **data):
        self.seq += 1
        record = {"schema_version": 1, "run_id": self.run_id, "seq": self.seq,
                  "timestamp": datetime.now(timezone.utc).isoformat(), "event": event, **data}
        with (self.directory / "events.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, allow_nan=False) + "\n")
            stream.flush()
        if self.on_event:
            try:
                self.on_event(record)
            except Exception as error:
                # A disconnected display must not strand an execution container.
                self.callback_error = type(error).__name__
                self.on_event = None

    def finish(self, outcome):
        path = self.directory / "outcome.json"
        if path.exists():
            raise RuntimeError("outcome is already final")
        if self.callback_error:
            outcome.errors.append(f"event callback failed: {self.callback_error}")
        atomic_json(path, outcome.to_dict())
        self.emit("run.finished", status=outcome.status, stop_reason=outcome.stop_reason,
                  exit_code=outcome.exit_code, outcome=str(path),
                  latest_candidate_sha=outcome.latest_candidate_sha,
                  last_passing_candidate_sha=outcome.last_passing_candidate_sha,
                  candidate_check_status=outcome.candidate_check_status,
                  sessions=outcome.sessions, agent_reply=outcome.agent_reply,
                  artifacts=outcome.artifacts, errors=outcome.errors)
