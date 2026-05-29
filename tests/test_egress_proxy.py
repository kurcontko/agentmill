#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import ipaddress
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("agentmill_egress_proxy", ROOT / "scripts" / "egress-proxy.py")
assert spec and spec.loader
proxy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = proxy
spec.loader.exec_module(proxy)


rules = proxy.parse_allowlist(
    "api.anthropic.com,*.githubusercontent.com,.example.org,https://uploads.github.com:443"
)

assert proxy.allowlist_matches("api.anthropic.com", 443, rules)
assert proxy.allowlist_matches("raw.githubusercontent.com", 443, rules)
assert not proxy.allowlist_matches("githubusercontent.com", 443, rules)
assert proxy.allowlist_matches("example.org", 80, rules)
assert proxy.allowlist_matches("api.example.org", 80, rules)
assert proxy.allowlist_matches("uploads.github.com", 443, rules)
assert not proxy.allowlist_matches("uploads.github.com", 80, rules)
assert not proxy.allowlist_matches("evil.example.net", 443, rules)

assert proxy.split_authority("api.anthropic.com:8443", 443) == ("api.anthropic.com", 8443)
assert proxy.split_authority("[2606:4700:4700::1111]:443", 80) == ("2606:4700:4700::1111", 443)

assert proxy.is_public_ip(ipaddress.ip_address("8.8.8.8"))
assert not proxy.is_public_ip(ipaddress.ip_address("127.0.0.1"))
assert not proxy.is_public_ip(ipaddress.ip_address("10.0.0.5"))
assert not proxy.is_public_ip(ipaddress.ip_address("169.254.169.254"))
assert not proxy.is_public_ip(ipaddress.ip_address("::1"))

localhost_rules = proxy.parse_allowlist("127.0.0.1,localhost")
try:
    proxy.target_allowed("127.0.0.1", 80, localhost_rules)
except PermissionError:
    pass
else:
    raise AssertionError("literal loopback target should be denied even when allowlisted")

print("PASS test_egress_proxy")
