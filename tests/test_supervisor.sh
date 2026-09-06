#!/usr/bin/env bash
set -euo pipefail
# Run through the image entrypoint with ITER_TIMEOUT=1 SHUTDOWN_GRACE=1.
# Exercises the broker's own deadline, without loop.sh or caller-side timeout.
fixture="$(mktemp -d /tmp/agentmill-supervisor-test.XXXXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
chmod 777 "$fixture"
rpc=/usr/local/bin/reviewer-rpc

if "$rpc" unknown-operation; then
    echo 'FAIL: supervisor accepted an unknown operation' >&2
    exit 1
fi
/usr/local/bin/agentmill-reviewer-exec --write-root "$fixture" -- \
    /usr/bin/python3 -c '
import os
from pathlib import Path
import pwd
assert os.geteuid() == pwd.getpwnam("agentmill-reviewer").pw_uid
status = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines())
assert status["NoNewPrivs"].strip() == "1"
for key in ("CapEff", "CapPrm", "CapAmb"):
    assert int(status[key].strip(), 16) == 0
assert not os.access("/run/agentmill/reviewer.sock", os.W_OK)
'
started="$(date +%s)"
status=0
/usr/local/bin/agentmill-reviewer-exec --write-root "$fixture" -- \
    /usr/bin/python3 -c 'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' \
    || status=$?
[[ "$status" -eq 124 && "$(( $(date +%s) - started ))" -lt 5 ]] \
    || { echo "FAIL: broker deadline returned $status" >&2; exit 1; }
echo 'PASS: broker restricts requests, drops reviewer privileges, and enforces its own deadline'
