import queue
import unittest
from pathlib import Path
from unittest import mock

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

    def test_poll_loop_retries_after_oserror(self) -> None:
        watcher = FileWatcher(Path("."), interval=0)
        watcher._running = False
        watcher._thread.join(timeout=1)

        attempts = 0

        def flaky_poll_once() -> None:
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise OSError("transient read failure")
            watcher._running = False

        watcher._poll_once = flaky_poll_once  # type: ignore[method-assign]
        watcher._running = True

        with mock.patch("codex_preview_server.time.sleep", return_value=None):
            watcher._poll_loop()

        self.assertEqual(attempts, 2)

    def test_poll_loop_does_not_swallow_keyboard_interrupt(self) -> None:
        watcher = FileWatcher(Path("."), interval=0)
        watcher._running = False
        watcher._thread.join(timeout=1)

        watcher._poll_once = mock.Mock(side_effect=KeyboardInterrupt)  # type: ignore[method-assign]
        watcher._running = True

        with mock.patch("codex_preview_server.time.sleep", return_value=None):
            with self.assertRaises(KeyboardInterrupt):
                watcher._poll_loop()


if __name__ == "__main__":
    unittest.main()
