#!/usr/bin/python3 -I
"""Unprivileged client for the fixed reviewer supervisor protocol.

Only standard I/O descriptors and an argument vector cross this socket. No
caller environment, executable path, uid, or working directory is accepted.
"""
from __future__ import annotations

import array
import json
import socket
import struct
import sys

SOCKET_PATH = "/run/agentmill/reviewer.sock"
MAX_REQUEST = 2 * 1024 * 1024


def read_exact(connection: socket.socket, length: int) -> bytes:
    parts = bytearray()
    while len(parts) < length:
        chunk = connection.recv(length - len(parts))
        if not chunk:
            raise ConnectionError("reviewer supervisor disconnected")
        parts.extend(chunk)
    return bytes(parts)


def main() -> int:
    request = json.dumps(sys.argv[1:]).encode("utf-8")
    if len(request) > MAX_REQUEST:
        raise ValueError("reviewer request too large")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(SOCKET_PATH)
        connection.sendmsg([b"R"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                    array.array("i", [0, 1, 2]))])
        connection.sendall(struct.pack("!I", len(request)) + request)
        status = struct.unpack("!I", read_exact(connection, 4))[0]
        return status if status <= 255 else 125


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, ConnectionError) as error:
        print(f"reviewer-rpc: {error}", file=sys.stderr)
        raise SystemExit(125)
