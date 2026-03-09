import queue
import unittest
from pathlib import Path

from codex_preview_server import FileWatcher


class FileWatcherTests(unittest.TestCase):
    def test_broadcast_uses_subscriber_snapshot(self) -> None:
        watcher = FileWatcher(Path("."))
        watcher._running = False
        watcher._thread.join(timeout=1)

        first = queue.Queue(maxsize=1)
        second = queue.Queue(maxsize=1)
        watcher.subscribers = [first, second]

        original_put = first.put_nowait

        def mutate_live_subscriber_list(message: str) -> None:
            watcher.subscribers.remove(first)
            original_put(message)

        first.put_nowait = mutate_live_subscriber_list  # type: ignore[method-assign]

        watcher._broadcast("status", '{"ok": true}')

        expected = 'event: status\ndata: {"ok": true}\n\n'
        self.assertEqual(first.get_nowait(), expected)
        self.assertEqual(second.get_nowait(), expected)
        self.assertEqual(watcher.subscribers, [second])


if __name__ == "__main__":
    unittest.main()
