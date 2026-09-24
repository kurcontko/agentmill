"""The run contract. Provider claims are never authoritative outcomes."""

from dataclasses import asdict, dataclass, field
import math
from pathlib import Path
import re


REPLY_SCHEMA = {
    "type": "object",
    "properties": {
        "status": {"type": "string", "enum": ["done", "continue", "blocked"]},
        "summary": {"type": "string"},
        "next_step": {"type": ["string", "null"]},
        "question": {"type": ["string", "null"]},
    },
    "required": ["status", "summary", "next_step", "question"],
    "additionalProperties": False,
}


class RunStopped(Exception):
    def __init__(self, reason, exit_code=1, detail=None):
        super().__init__(reason)
        self.reason = reason
        self.exit_code = exit_code
        self.detail = detail


def preserve_failure(primary, error, diagnostics, message=None):
    """Record a secondary fault without replacing an existing primary failure."""
    if message is not None:
        diagnostics.append(message)
    return primary if primary is not None else error


@dataclass(frozen=True)
class RunSpec:
    source: str
    task: str
    checks: tuple[str, ...]
    revision: str = "HEAD"
    agent: str = "codex"
    model: str | None = None
    profile: str | None = None
    setup: str = "true"
    max_sessions: int = 3
    max_duration: float = 1800
    setup_timeout: float = 300
    session_timeout: float = 900
    check_timeout: float = 300
    image: str = "agentmill:latest"
    credential_env: tuple[str, ...] | None = None
    agent_config: str | None = None
    auth_file: str | None = None
    check_dir: str | None = None

    def __post_init__(self):
        for name in ("source", "task", "revision", "setup", "image"):
            value = getattr(self, name)
            if not isinstance(value, str) or not value.strip() or "\0" in value:
                raise ValueError(f"{name} must be a nonempty string")
        if self.agent not in ("codex", "claude"):
            raise ValueError("agent must be codex or claude")
        if not isinstance(self.checks, (list, tuple)) or not self.checks:
            raise ValueError("at least one check is required")
        if any(not isinstance(c, str) or not c.strip() or "\0" in c for c in self.checks):
            raise ValueError("checks must be nonempty command strings")
        object.__setattr__(self, "checks", tuple(self.checks))
        if type(self.max_sessions) is not int or self.max_sessions < 1:
            raise ValueError("max_sessions must be a positive integer")
        for name in ("max_duration", "setup_timeout", "session_timeout", "check_timeout"):
            value = getattr(self, name)
            if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
                raise ValueError(f"{name} must be a positive finite duration in seconds")
        for name in ("model", "profile", "agent_config", "auth_file", "check_dir"):
            value = getattr(self, name)
            if value is not None and (not isinstance(value, str) or not value or "\0" in value):
                raise ValueError(f"{name} must be a nonempty string or null")
        if self.profile and (self.agent != "codex" or not re.fullmatch(r"[A-Za-z0-9_-]+", self.profile)):
            raise ValueError("profile is a Codex profile name (letters, digits, _ and -)")
        if self.profile and not self.agent_config:
            raise ValueError("profile requires an explicitly selected agent_config file")
        if self.auth_file and self.agent != "codex":
            raise ValueError("auth_file is a Codex auth.json file; use native environment auth for Claude")
        if self.credential_env is None:
            names = ("CODEX_API_KEY",) if self.agent == "codex" else (
                "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")
        else:
            names = self.credential_env
            if not isinstance(names, (list, tuple)):
                raise ValueError("credential_env must be a list of environment variable names")
        if any(not isinstance(n, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", n) for n in names):
            raise ValueError("credential_env must contain environment variable names, not values")
        # These control the container boundary and must never be inherited from the host.
        if any(n in {"HOME", "PATH", "BASH_ENV", "ENV", "LD_PRELOAD", "PYTHONPATH", "CODEX_HOME"}
               or n.startswith("GIT_") for n in names):
            raise ValueError("credential_env cannot override runtime environment controls")
        object.__setattr__(self, "credential_env", tuple(dict.fromkeys(names)))

    def to_dict(self):
        return asdict(self)


@dataclass(frozen=True)
class AgentReply:
    status: str
    summary: str
    next_step: str | None
    question: str | None

    @classmethod
    def parse(cls, value):
        if not isinstance(value, dict) or set(value) != set(REPLY_SCHEMA["required"]):
            raise RunStopped("invalid_agent_reply")
        if value["status"] not in ("done", "continue", "blocked") or not isinstance(value["summary"], str):
            raise RunStopped("invalid_agent_reply")
        if any(value[n] is not None and not isinstance(value[n], str) for n in ("next_step", "question")):
            raise RunStopped("invalid_agent_reply")
        return cls(**value)


@dataclass(frozen=True)
class SessionRequest:
    model: str | None = None
    profile: str | None = None
    agent_config: bool = False


@dataclass(frozen=True)
class Command:
    argv: tuple[str, ...]
    stdin: str = "/inputs/prompt.txt"


@dataclass
class ProcessOutput:
    returncode: int | None
    stdout: Path
    stderr: Path
    elapsed: float
    stop_reason: str | None = None


@dataclass
class RunOutcome:
    run_id: str
    status: str = "failed"
    stop_reason: str = "startup_failed"
    exit_code: int = 1
    base_revision: str | None = None
    latest_candidate_sha: str | None = None
    last_passing_candidate_sha: str | None = None
    candidate_check_status: str = "unchecked"
    agent_reply: dict | None = None
    sessions: int = 0
    checks: list[dict] = field(default_factory=list)
    artifacts: dict = field(default_factory=dict)
    environment: dict = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)
    schema_version: int = 1

    def finish(self, failure=None, *, cancellation=None):
        """Construct the terminal result once, after required preservation work."""
        if failure is None:
            reason, code = "checked_complete", 0
        elif isinstance(failure, RunStopped):
            reason, code = failure.reason, failure.exit_code
        else:
            reason, code = "runtime_error", 1
            self.errors.append(f"{type(failure).__name__}: {failure}")
        if cancellation is not None:
            if reason != "cancelled":
                self.errors.append(f"cancelled while handling: {reason}")
            reason, code = cancellation.reason, cancellation.exit_code
        self.status = "cancelled" if cancellation is not None else {
            0: "checked_complete", 2: "incomplete", 3: "blocked",
            130: "cancelled", 143: "cancelled"}.get(code, "failed")
        self.stop_reason, self.exit_code = reason, code

    def to_dict(self):
        return asdict(self)
