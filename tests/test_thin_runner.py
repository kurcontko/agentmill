"""Tests for the thin agent runner's presentation layer."""

import unittest
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from thin_runner import is_binary, present_output, format_size


class TestBinaryGuard(unittest.TestCase):
    def test_empty_is_not_binary(self):
        self.assertFalse(is_binary(b""))

    def test_text_is_not_binary(self):
        self.assertFalse(is_binary(b"hello world\nline two\n"))

    def test_null_bytes_are_binary(self):
        self.assertTrue(is_binary(b"hello\x00world"))

    def test_png_header_is_binary(self):
        self.assertTrue(is_binary(b"\x89PNG\r\n\x1a\n" + b"\x00" * 100))

    def test_high_control_ratio_is_binary(self):
        # >10% control characters
        data = bytes(range(0, 32)) * 10  # lots of control chars
        self.assertTrue(is_binary(data))

    def test_utf8_text_is_not_binary(self):
        self.assertFalse(is_binary("héllo wörld\n".encode("utf-8")))


class TestFormatSize(unittest.TestCase):
    def test_bytes(self):
        self.assertEqual(format_size(500), "500B")

    def test_kilobytes(self):
        self.assertEqual(format_size(2048), "2.0KB")

    def test_megabytes(self):
        self.assertEqual(format_size(1048576), "1.0MB")


class TestPresentOutput(unittest.TestCase):
    def test_simple_success(self):
        result = present_output(b"hello\n", b"", 0, 0.005)
        self.assertIn("hello", result)
        self.assertIn("[exit:0 |", result)

    def test_empty_output(self):
        result = present_output(b"", b"", 0, 0.001)
        self.assertIn("(no output)", result)
        self.assertIn("[exit:0", result)

    def test_stderr_on_failure(self):
        result = present_output(b"", b"command not found\n", 127, 0.01)
        self.assertIn("command not found", result)
        self.assertIn("[exit:127", result)

    def test_stderr_attached_on_failure_with_stdout(self):
        result = present_output(b"partial output\n", b"warning: something\n", 1, 0.1)
        self.assertIn("partial output", result)
        self.assertIn("[stderr]", result)
        self.assertIn("warning: something", result)

    def test_stderr_hidden_on_success_with_stdout(self):
        result = present_output(b"output\n", b"debug noise\n", 0, 0.01)
        self.assertNotIn("debug noise", result)
        self.assertIn("output", result)

    def test_binary_guard(self):
        result = present_output(b"\x89PNG\x00\x00", b"", 0, 0.01)
        self.assertIn("[binary output", result)
        self.assertNotIn("\x89", result)

    def test_overflow_truncation(self):
        # Generate >200 lines
        lines = "\n".join(f"line {i}" for i in range(500))
        result = present_output(lines.encode(), b"", 0, 0.5)
        self.assertIn("truncated", result)
        self.assertIn("500 lines", result)

    def test_duration_milliseconds(self):
        result = present_output(b"ok\n", b"", 0, 0.050)
        self.assertIn("50ms", result)

    def test_duration_seconds(self):
        result = present_output(b"ok\n", b"", 0, 3.2)
        self.assertIn("3.2s", result)


if __name__ == "__main__":
    unittest.main()
