"""The supervisor must bound the worker even if its own timer fails."""

from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from supervisor import wait_worker


class WorkerDeadlineTests(unittest.TestCase):
    def test_deadline_interrupts_a_real_worker(self):
        worker = subprocess.Popen([sys.executable, "-u", "-c",
            "import signal,time; signal.signal(signal.SIGUSR1, lambda *_: exit(0)); "
            "print('ready'); time.sleep(60)"], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(worker.stdout.readline().strip(), "ready")
            self.assertEqual(wait_worker(worker, .05, 0), 2)
            self.assertEqual(worker.poll(), 0)
        finally:
            if worker.poll() is None:
                worker.kill()
            worker.wait()
            worker.stdout.close()

    def test_a_wedged_worker_is_killed_after_bounded_cleanup(self):
        worker = Mock()
        worker.wait.side_effect = [subprocess.TimeoutExpired("worker", 1),
                                   subprocess.TimeoutExpired("worker", 25), -9]
        self.assertEqual(wait_worker(worker, 1, 0), 2)
        worker.send_signal.assert_called_once_with(signal.SIGUSR1)
        worker.kill.assert_called_once_with()
        self.assertEqual(worker.wait.call_args_list[1].kwargs["timeout"], 25)

    def test_natural_outcomes_are_preserved(self):
        for status, expected in ((0, 0), (3, 3), (-15, 143)):
            worker = Mock()
            worker.wait.return_value = status
            self.assertEqual(wait_worker(worker, 0, 1), expected)
            worker.kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()
