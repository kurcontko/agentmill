import io
import subprocess
import unittest
from contextlib import redirect_stderr
from unittest import mock

from codex_preview_supervisor import wait_for_process_exit


class WaitForProcessExitTests(unittest.TestCase):
    def test_kills_process_when_wait_times_out(self) -> None:
        process = mock.Mock()
        process.wait.side_effect = [
            subprocess.TimeoutExpired(cmd=["codex", "exec"], timeout=300),
            0,
        ]

        stderr = io.StringIO()
        with redirect_stderr(stderr):
            wait_timed_out = wait_for_process_exit(process, timeout=300)

        self.assertTrue(wait_timed_out)
        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=300), mock.call()])
        process.kill.assert_called_once_with()
        self.assertIn("ERROR: codex subprocess exceeded wait timeout (300s); killing process", stderr.getvalue())

    def test_returns_without_killing_when_process_exits(self) -> None:
        process = mock.Mock()

        wait_timed_out = wait_for_process_exit(process, timeout=300)

        self.assertFalse(wait_timed_out)
        process.wait.assert_called_once_with(timeout=300)
        process.kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()
