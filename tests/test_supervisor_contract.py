"""Supervisor protocol and deadline decisions, without privileged execution."""

import importlib.util
from pathlib import Path
import signal
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("supervisor_contract", ROOT / "supervisor.py")
supervisor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(supervisor)


class SupervisorContractTests(unittest.TestCase):
    def test_control_request_shape(self):
        for operation in ("0", "TERM", "KILL"):
            request = ["control", operation, "123", "123", "456", "456"]
            self.assertEqual(supervisor.validate_request(request), request)

    def test_invalid_requests_are_rejected(self):
        for request in (None, [], {}, ["other"], ["control", "TERM"],
                        ["exec", 1], ["exec", "bad\0argument"]):
            with self.subTest(request=request):
                with self.assertRaises(ValueError):
                    supervisor.validate_request(request)

    def test_partial_frame_is_reassembled(self):
        connection = Mock()
        connection.recv.side_effect = [b"ab", b"c"]
        self.assertEqual(supervisor.read_exact(connection, 3), b"abc")

    def test_truncated_frame_is_rejected(self):
        connection = Mock()
        connection.recv.side_effect = [b"a", b""]
        with self.assertRaises(ConnectionError):
            supervisor.read_exact(connection, 3)

    def test_confined_deadline_returns_timeout(self):
        process = Mock(pid=123)
        process.wait.return_value = -signal.SIGKILL
        with patch.object(supervisor.os, "waitid", create=True,
                          side_effect=[None, object()]), \
             patch.object(supervisor.os, "P_PID", 1, create=True), \
             patch.object(supervisor.os, "WEXITED", 4, create=True), \
             patch.object(supervisor.os, "WNOHANG", 1, create=True), \
             patch.object(supervisor.os, "WNOWAIT", 8, create=True), \
             patch.object(supervisor.time, "monotonic", return_value=10), \
             patch.object(supervisor.select, "select", return_value=([], [], [])), \
             patch.object(supervisor, "kill_group") as kill:
            self.assertEqual(supervisor.wait_confined(process, Mock(), 5, 0), 124)
            kill.assert_any_call(123, signal.SIGTERM)
            kill.assert_any_call(123, signal.SIGKILL)

    def test_completed_process_preserves_exit_code(self):
        process = Mock(pid=123)
        process.wait.return_value = 7
        with patch.object(supervisor.os, "waitid", return_value=object(), create=True), \
             patch.object(supervisor.os, "P_PID", 1, create=True), \
             patch.object(supervisor.os, "WEXITED", 4, create=True), \
             patch.object(supervisor.os, "WNOHANG", 1, create=True), \
             patch.object(supervisor.os, "WNOWAIT", 8, create=True), \
             patch.object(supervisor, "kill_group"):
            self.assertEqual(supervisor.wait_confined(process, Mock(), 5, 0), 7)


if __name__ == "__main__":
    unittest.main()
