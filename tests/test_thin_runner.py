"""Tests for the thin agent runner."""

import json
import os
import sys
import tempfile
import unittest
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from thin_runner import (
    is_binary,
    present_output,
    format_size,
    execute_command,
    chat_completion,
    extract_tool_calls,
    extract_text,
    run_agent,
    TOOLS,
    SYSTEM_PROMPT,
)


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
        data = bytes(range(0, 32)) * 10
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
        lines = "\n".join(f"line {i}" for i in range(500))
        result = present_output(lines.encode(), b"", 0, 0.5)
        self.assertIn("truncated", result)
        self.assertIn("500 lines", result)

    def test_overflow_byte_limit(self):
        # Single very long line exceeding byte limit
        line = "x" * 60_000
        result = present_output(line.encode(), b"", 0, 0.01)
        self.assertIn("truncated", result)

    def test_duration_milliseconds(self):
        result = present_output(b"ok\n", b"", 0, 0.050)
        self.assertIn("50ms", result)

    def test_duration_seconds(self):
        result = present_output(b"ok\n", b"", 0, 3.2)
        self.assertIn("3.2s", result)

    def test_stderr_shown_when_no_stdout_and_success(self):
        # stderr visible when stdout empty, even on exit 0
        result = present_output(b"", b"some info\n", 0, 0.01)
        self.assertIn("some info", result)


class TestExecuteCommand(unittest.TestCase):
    def test_simple_command(self):
        stdout, stderr, code, elapsed = execute_command("echo hello", "/tmp")
        self.assertEqual(code, 0)
        self.assertIn(b"hello", stdout)
        self.assertGreater(elapsed, 0)

    def test_failing_command(self):
        stdout, stderr, code, elapsed = execute_command("false", "/tmp")
        self.assertNotEqual(code, 0)

    def test_stderr_captured(self):
        stdout, stderr, code, elapsed = execute_command("echo err >&2", "/tmp")
        self.assertIn(b"err", stderr)

    def test_pipe_command(self):
        stdout, stderr, code, elapsed = execute_command(
            "echo 'hello world' | grep hello", "/tmp"
        )
        self.assertEqual(code, 0)
        self.assertIn(b"hello", stdout)

    def test_cwd_respected(self):
        with tempfile.TemporaryDirectory() as d:
            stdout, _, code, _ = execute_command("pwd", d)
            self.assertEqual(code, 0)
            self.assertIn(d.encode(), stdout)

    def test_timeout_returns_124(self):
        with patch("thin_runner.COMMAND_TIMEOUT", 1):
            _, stderr, code, _ = execute_command("sleep 10", "/tmp")
            self.assertEqual(code, 124)
            self.assertIn(b"timed out", stderr)


class TestExtractHelpers(unittest.TestCase):
    def test_extract_text(self):
        self.assertEqual(extract_text({"content": "hello"}), "hello")
        self.assertEqual(extract_text({"content": None}), "")
        self.assertEqual(extract_text({}), "")

    def test_extract_tool_calls(self):
        tc = [{"id": "1", "function": {"name": "run", "arguments": "{}"}}]
        self.assertEqual(extract_tool_calls({"tool_calls": tc}), tc)
        self.assertEqual(extract_tool_calls({"tool_calls": None}), [])
        self.assertEqual(extract_tool_calls({}), [])


class TestChatCompletion(unittest.TestCase):
    """Test chat_completion with a mock HTTP server."""

    @classmethod
    def setUpClass(cls):
        cls.response_body = {
            "choices": [
                {
                    "message": {"content": "I'm done", "tool_calls": None},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 100, "completion_tokens": 20},
        }

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self_handler):
                length = int(self_handler.headers["Content-Length"])
                body = json.loads(self_handler.rfile.read(length))
                cls.last_request = body
                resp = json.dumps(cls.response_body).encode()
                self_handler.send_response(200)
                self_handler.send_header("Content-Type", "application/json")
                self_handler.send_header("Content-Length", str(len(resp)))
                self_handler.end_headers()
                self_handler.wfile.write(resp)

            def log_message(self_handler, format, *args):
                pass  # suppress logs

        cls.server = HTTPServer(("127.0.0.1", 0), Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_basic_completion(self):
        result = chat_completion(
            messages=[{"role": "user", "content": "hi"}],
            model="test-model",
            base_url=f"http://127.0.0.1:{self.port}/v1",
            api_key="test-key",
        )
        self.assertEqual(result["choices"][0]["message"]["content"], "I'm done")

    def test_sends_correct_headers(self):
        chat_completion(
            messages=[{"role": "user", "content": "hi"}],
            model="test-model",
            base_url=f"http://127.0.0.1:{self.port}/v1",
            api_key="my-secret-key",
        )
        self.assertEqual(self.last_request["model"], "test-model")

    def test_tools_included(self):
        chat_completion(
            messages=[{"role": "user", "content": "hi"}],
            model="test-model",
            base_url=f"http://127.0.0.1:{self.port}/v1",
            api_key="test-key",
            tools=TOOLS,
        )
        self.assertIn("tools", self.last_request)
        self.assertEqual(self.last_request["tools"][0]["function"]["name"], "run")

    def test_api_error_raises(self):
        with self.assertRaises(Exception):
            chat_completion(
                messages=[{"role": "user", "content": "hi"}],
                model="test-model",
                base_url="http://127.0.0.1:1/v1",  # bad port
                api_key="test-key",
            )


class TestRunAgent(unittest.TestCase):
    """Test the full agent loop with a mock API."""

    @classmethod
    def setUpClass(cls):
        cls.call_count = 0
        cls.responses = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self_handler):
                idx = min(cls.call_count, len(cls.responses) - 1)
                resp_body = cls.responses[idx]
                cls.call_count += 1
                resp = json.dumps(resp_body).encode()
                self_handler.send_response(200)
                self_handler.send_header("Content-Type", "application/json")
                self_handler.send_header("Content-Length", str(len(resp)))
                self_handler.end_headers()
                self_handler.wfile.write(resp)

            def log_message(self_handler, format, *args):
                pass

        cls.server = HTTPServer(("127.0.0.1", 0), Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        TestRunAgent.call_count = 0

    def test_simple_no_tools(self):
        """Agent responds immediately without tool calls."""
        self.responses.clear()
        self.responses.append({
            "choices": [{"message": {"content": "Done!", "tool_calls": None}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 50, "completion_tokens": 10},
        })

        result = run_agent(
            prompt="Say done",
            model="test",
            base_url=f"http://127.0.0.1:{self.port}/v1",
            api_key="key",
            cwd="/tmp",
            max_rounds=5,
        )
        self.assertEqual(result, "Done!")
        self.assertEqual(self.call_count, 1)

    def test_tool_call_then_response(self):
        """Agent makes one tool call, then responds."""
        self.responses.clear()
        # Round 1: tool call
        self.responses.append({
            "choices": [{
                "message": {
                    "content": None,
                    "tool_calls": [{
                        "id": "tc_1",
                        "function": {
                            "name": "run",
                            "arguments": json.dumps({"command": "echo hello"}),
                        },
                    }],
                },
                "finish_reason": "tool_calls",
            }],
            "usage": {"prompt_tokens": 100, "completion_tokens": 20},
        })
        # Round 2: final response
        self.responses.append({
            "choices": [{"message": {"content": "Done with echo", "tool_calls": None}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 150, "completion_tokens": 15},
        })

        result = run_agent(
            prompt="Echo hello",
            model="test",
            base_url=f"http://127.0.0.1:{self.port}/v1",
            api_key="key",
            cwd="/tmp",
            max_rounds=5,
        )
        self.assertEqual(result, "Done with echo")
        self.assertEqual(self.call_count, 2)

    def test_max_rounds_respected(self):
        """Agent stops after max_rounds even if still calling tools."""
        self.responses.clear()
        # Always return a tool call
        for _ in range(10):
            self.responses.append({
                "choices": [{
                    "message": {
                        "content": "thinking...",
                        "tool_calls": [{
                            "id": "tc_loop",
                            "function": {
                                "name": "run",
                                "arguments": json.dumps({"command": "echo looping"}),
                            },
                        }],
                    },
                    "finish_reason": "tool_calls",
                }],
                "usage": {"prompt_tokens": 100, "completion_tokens": 20},
            })

        result = run_agent(
            prompt="Loop forever",
            model="test",
            base_url=f"http://127.0.0.1:{self.port}/v1",
            api_key="key",
            cwd="/tmp",
            max_rounds=3,
        )
        self.assertEqual(self.call_count, 3)

    def test_invalid_tool_args_handled(self):
        """Agent handles invalid JSON in tool call arguments."""
        self.responses.clear()
        self.responses.append({
            "choices": [{
                "message": {
                    "content": None,
                    "tool_calls": [{
                        "id": "tc_bad",
                        "function": {
                            "name": "run",
                            "arguments": "not json{{{",
                        },
                    }],
                },
                "finish_reason": "tool_calls",
            }],
            "usage": {"prompt_tokens": 100, "completion_tokens": 20},
        })
        self.responses.append({
            "choices": [{"message": {"content": "recovered", "tool_calls": None}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 150, "completion_tokens": 10},
        })

        result = run_agent(
            prompt="bad args",
            model="test",
            base_url=f"http://127.0.0.1:{self.port}/v1",
            api_key="key",
            cwd="/tmp",
            max_rounds=5,
        )
        self.assertEqual(result, "recovered")

    def test_empty_command_handled(self):
        """Agent handles tool call with empty command."""
        self.responses.clear()
        self.responses.append({
            "choices": [{
                "message": {
                    "content": None,
                    "tool_calls": [{
                        "id": "tc_empty",
                        "function": {
                            "name": "run",
                            "arguments": json.dumps({}),
                        },
                    }],
                },
                "finish_reason": "tool_calls",
            }],
            "usage": {"prompt_tokens": 100, "completion_tokens": 20},
        })
        self.responses.append({
            "choices": [{"message": {"content": "ok", "tool_calls": None}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 150, "completion_tokens": 10},
        })

        result = run_agent(
            prompt="empty cmd",
            model="test",
            base_url=f"http://127.0.0.1:{self.port}/v1",
            api_key="key",
            cwd="/tmp",
            max_rounds=5,
        )
        self.assertEqual(result, "ok")


class TestConstants(unittest.TestCase):
    def test_system_prompt_exists(self):
        self.assertGreater(len(SYSTEM_PROMPT), 100)

    def test_tools_has_run(self):
        self.assertEqual(len(TOOLS), 1)
        self.assertEqual(TOOLS[0]["function"]["name"], "run")
        self.assertIn("command", TOOLS[0]["function"]["parameters"]["properties"])


if __name__ == "__main__":
    unittest.main()
