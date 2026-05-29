#!/usr/bin/env python3
from __future__ import annotations

import ipaddress
import os
import select
import socket
import socketserver
import sys
import urllib.parse
from dataclasses import dataclass


HEADER_LIMIT = 64 * 1024
BUFFER_SIZE = 64 * 1024
DEFAULT_CONNECT_TIMEOUT = 15.0
DEFAULT_IDLE_TIMEOUT = 300.0


@dataclass(frozen=True)
class AllowRule:
    kind: str
    host: str
    port: int | None = None


def normalize_host(host: str) -> str:
    host = host.strip().lower()
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    return host.rstrip(".")


def parse_port(value: str | None) -> int | None:
    if not value:
        return None
    try:
        port = int(value)
    except ValueError:
        return None
    if 1 <= port <= 65535:
        return port
    return None


def split_authority(authority: str, default_port: int) -> tuple[str, int] | None:
    authority = authority.strip()
    if not authority:
        return None
    if "@" in authority:
        authority = authority.rsplit("@", 1)[1]
    parsed = urllib.parse.urlsplit("//" + authority)
    if not parsed.hostname:
        return None
    port = parsed.port or default_port
    if not 1 <= port <= 65535:
        return None
    return normalize_host(parsed.hostname), port


def parse_allowlist(value: str) -> list[AllowRule]:
    rules: list[AllowRule] = []
    for raw in value.replace("\n", ",").split(","):
        entry = raw.strip()
        if not entry:
            continue
        if entry in {"*", "*:*"}:
            continue
        if "://" in entry:
            parsed = urllib.parse.urlsplit(entry)
        else:
            parsed = urllib.parse.urlsplit("//" + entry.split("/", 1)[0])
        host = normalize_host(parsed.hostname or "")
        if not host or host == "*":
            continue
        port = parsed.port
        if host.startswith("*.") and len(host) > 2:
            rules.append(AllowRule("wildcard", host[2:], port))
        elif host.startswith(".") and len(host) > 1:
            rules.append(AllowRule("suffix", host[1:], port))
        else:
            rules.append(AllowRule("exact", host, port))
    return rules


def literal_ip(host: str) -> ipaddress._BaseAddress | None:
    try:
        return ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return None


def is_public_ip(address: ipaddress._BaseAddress) -> bool:
    return address.is_global


def allowlist_matches(host: str, port: int, rules: list[AllowRule]) -> bool:
    host = normalize_host(host)
    for rule in rules:
        if rule.port is not None and rule.port != port:
            continue
        if rule.kind == "exact" and host == rule.host:
            return True
        if rule.kind == "wildcard" and host.endswith("." + rule.host):
            return True
        if rule.kind == "suffix" and (host == rule.host or host.endswith("." + rule.host)):
            return True
    return False


def resolve_public_target(host: str, port: int) -> list[tuple[int, int, int, tuple]]:
    literal = literal_ip(host)
    if literal is not None:
        if not is_public_ip(literal):
            raise PermissionError(f"target resolves to non-public address: {host}")
        family = socket.AF_INET6 if literal.version == 6 else socket.AF_INET
        sockaddr = (str(literal), port, 0, 0) if literal.version == 6 else (str(literal), port)
        return [(family, socket.SOCK_STREAM, 0, sockaddr)]

    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    if not infos:
        raise OSError(f"could not resolve target: {host}")
    results: list[tuple[int, int, int, tuple]] = []
    for family, socktype, proto, _canonname, sockaddr in infos:
        address = ipaddress.ip_address(str(sockaddr[0]).split("%", 1)[0])
        if not is_public_ip(address):
            raise PermissionError(f"target resolves to non-public address: {host} -> {address}")
        results.append((family, socktype, proto, sockaddr))
    return results


def open_public_connection(host: str, port: int, timeout: float) -> socket.socket:
    last_error: BaseException | None = None
    for family, socktype, proto, sockaddr in resolve_public_target(host, port):
        upstream = socket.socket(family, socktype, proto)
        upstream.settimeout(timeout)
        try:
            upstream.connect(sockaddr)
            upstream.settimeout(None)
            return upstream
        except OSError as exc:
            last_error = exc
            upstream.close()
    if last_error is not None:
        raise last_error
    raise OSError(f"could not connect to target: {host}:{port}")


def target_allowed(host: str, port: int, rules: list[AllowRule]) -> bool:
    if not allowlist_matches(host, port, rules):
        return False
    resolve_public_target(host, port)
    return True


def read_headers(client: socket.socket) -> tuple[bytes, bytes]:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = client.recv(4096)
        if not chunk:
            break
        data.extend(chunk)
        if len(data) > HEADER_LIMIT:
            raise ValueError("request headers exceed limit")
    marker = data.find(b"\r\n\r\n")
    if marker == -1:
        raise ValueError("incomplete request headers")
    split_at = marker + 4
    return bytes(data[:split_at]), bytes(data[split_at:])


def parse_header_lines(header_bytes: bytes) -> tuple[str, list[str]]:
    text = header_bytes.decode("iso-8859-1")
    lines = text.split("\r\n")
    return lines[0], [line for line in lines[1:] if line]


def header_value(headers: list[str], name: str) -> str | None:
    prefix = name.lower() + ":"
    for header in headers:
        if header.lower().startswith(prefix):
            return header.split(":", 1)[1].strip()
    return None


def send_error(client: socket.socket, code: int, reason: str) -> None:
    body = f"{code} {reason}\n".encode("utf-8")
    response = (
        f"HTTP/1.1 {code} {reason}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        "\r\n"
    ).encode("iso-8859-1") + body
    try:
        client.sendall(response)
    except OSError:
        pass


def relay_bidirectional(left: socket.socket, right: socket.socket, idle_timeout: float) -> None:
    sockets = [left, right]
    for sock in sockets:
        sock.setblocking(False)
    while sockets:
        readable, _writable, exceptional = select.select(sockets, [], sockets, idle_timeout)
        if exceptional or not readable:
            break
        for sock in readable:
            peer = right if sock is left else left
            try:
                data = sock.recv(BUFFER_SIZE)
            except OSError:
                data = b""
            if not data:
                if sock in sockets:
                    sockets.remove(sock)
                try:
                    peer.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                continue
            try:
                peer.sendall(data)
            except OSError:
                return


class ProxyHandler(socketserver.BaseRequestHandler):
    rules: list[AllowRule] = []
    connect_timeout: float = DEFAULT_CONNECT_TIMEOUT
    idle_timeout: float = DEFAULT_IDLE_TIMEOUT

    def handle(self) -> None:
        try:
            header_bytes, remainder = read_headers(self.request)
            request_line, headers = parse_header_lines(header_bytes)
            parts = request_line.split()
            if len(parts) != 3:
                send_error(self.request, 400, "Bad Request")
                return
            method, target, version = parts
            if method.upper() == "CONNECT":
                self.handle_connect(target)
            else:
                self.handle_http(method, target, version, headers, remainder)
        except PermissionError as exc:
            print(f"denied: {exc}", file=sys.stderr, flush=True)
            send_error(self.request, 403, "Forbidden")
        except Exception as exc:
            print(f"proxy error: {exc}", file=sys.stderr, flush=True)
            send_error(self.request, 502, "Bad Gateway")

    def checked_connect(self, host: str, port: int) -> socket.socket:
        if not allowlist_matches(host, port, self.rules):
            raise PermissionError(f"target not in AGENTMILL_EGRESS_ALLOWLIST: {host}:{port}")
        return open_public_connection(host, port, self.connect_timeout)

    def handle_connect(self, target: str) -> None:
        parsed = split_authority(target, 443)
        if parsed is None:
            send_error(self.request, 400, "Bad Request")
            return
        host, port = parsed
        upstream = self.checked_connect(host, port)
        with upstream:
            self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            relay_bidirectional(self.request, upstream, self.idle_timeout)

    def handle_http(
        self,
        method: str,
        target: str,
        version: str,
        headers: list[str],
        remainder: bytes,
    ) -> None:
        parsed_url = urllib.parse.urlsplit(target)
        if parsed_url.scheme:
            if parsed_url.scheme.lower() != "http" or not parsed_url.hostname:
                send_error(self.request, 400, "Bad Request")
                return
            host = normalize_host(parsed_url.hostname)
            port = parsed_url.port or 80
            path = parsed_url.path or "/"
            if parsed_url.query:
                path += "?" + parsed_url.query
        else:
            host_header = header_value(headers, "Host")
            parsed = split_authority(host_header or "", 80)
            if parsed is None:
                send_error(self.request, 400, "Bad Request")
                return
            host, port = parsed
            path = target or "/"

        upstream = self.checked_connect(host, port)
        with upstream:
            upstream.sendall(f"{method} {path} {version}\r\n".encode("iso-8859-1"))
            wrote_host = False
            for header in headers:
                name = header.split(":", 1)[0].strip().lower()
                if name in {"proxy-connection", "proxy-authorization"}:
                    continue
                if name == "host":
                    upstream.sendall(f"Host: {host}:{port}\r\n".encode("iso-8859-1"))
                    wrote_host = True
                else:
                    upstream.sendall((header + "\r\n").encode("iso-8859-1"))
            if not wrote_host:
                upstream.sendall(f"Host: {host}:{port}\r\n".encode("iso-8859-1"))
            upstream.sendall(b"\r\n")
            if remainder:
                upstream.sendall(remainder)
            relay_bidirectional(self.request, upstream, self.idle_timeout)


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> int:
    rules = parse_allowlist(os.environ.get("AGENTMILL_EGRESS_ALLOWLIST", ""))
    port = parse_port(os.environ.get("AGENTMILL_EGRESS_PROXY_PORT")) or 18080
    ProxyHandler.rules = rules
    ProxyHandler.connect_timeout = float(os.environ.get("AGENTMILL_EGRESS_CONNECT_TIMEOUT", DEFAULT_CONNECT_TIMEOUT))
    ProxyHandler.idle_timeout = float(os.environ.get("AGENTMILL_EGRESS_IDLE_TIMEOUT", DEFAULT_IDLE_TIMEOUT))
    with ThreadingTCPServer(("0.0.0.0", port), ProxyHandler) as server:
        print(f"agentmill egress proxy listening on :{port} with {len(rules)} allow rule(s)", file=sys.stderr, flush=True)
        server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
