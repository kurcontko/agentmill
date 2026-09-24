"""Best-effort CLI forwarding; the run's event file remains authoritative."""

import io
import os
import select
import time


class OutputSink:
    """Detach a stalled/closed stream after at most 100 ms per message.

    Use unbuffered writes so interpreter shutdown cannot flush into a full pipe.
    Restore descriptor flags after each write: pipes may be shared with a caller.
    A detached JSON stream can end with a partial line; read events.jsonl instead.
    """

    def __init__(self, stream):
        self.stream = stream
        self.detached = False

    def write(self, message):
        if self.detached:
            return
        # Support in-memory CLI embedding/tests without arbitrary stream callbacks.
        if isinstance(self.stream, io.StringIO):
            self.stream.write(message + "\n")
            return
        try:
            self._write((message + "\n").encode(self.stream.encoding or "utf-8", errors="replace"))
        except OSError:
            self.detached = True
            raise

    def _write(self, data):
        fd = self.stream.fileno()
        blocking = os.get_blocking(fd)
        deadline = time.monotonic() + 0.1
        try:
            os.set_blocking(fd, False)
            pending = memoryview(data)
            while pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([], [fd], [], remaining)[1]:
                    raise TimeoutError("CLI output stalled; read the run's events.jsonl")
                try:
                    written = os.write(fd, pending)
                except BlockingIOError:
                    continue
                if not written:
                    raise BrokenPipeError("CLI output closed")
                pending = pending[written:]
        finally:
            os.set_blocking(fd, blocking)
