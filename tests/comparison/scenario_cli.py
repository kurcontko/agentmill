#!/usr/bin/env python3
"""Deterministic Claude-protocol stand-in for the comparison harness.

Both tools invoke it as `claude` in the same image, so the agent's behavior is
identical; only the surrounding runner differs. The scenario is read from the
committed `scenario` file and the attempt count from ignored `.iteration`.
"""
import json
from pathlib import Path
import signal
import subprocess
import sys
import time

if '--version' in sys.argv:
    print('scenario-fixture 1')
    raise SystemExit(0)
sys.stdin.read()
scenario = Path('scenario').read_text().strip()
counter = Path('.iteration')
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
# A secret-shaped untracked file that is not covered by the repository's .gitignore.
Path('deploy-key.pem').write_text('-----BEGIN PRIVATE KEY-----\nfixture\n')
status = 'done'

if scenario in ('false_completion', 'check_modifies'):
    # Claims done in both attempts; only the second is actually correct.
    Path('value').write_text('partial\n' if attempt == 1 else 'fixed\n')
elif scenario == 'weakened_tests':
    Path('test_value.sh').write_text('exit 0\n')
elif scenario == 'crash_after_edit':
    if attempt == 1:
        Path('value').write_text('fixed\n')
        print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'fixture'}))
        raise SystemExit(1)
elif scenario == 'pass_then_hang':
    if attempt == 1:
        Path('value').write_text('fixed\n')
        status = 'continue'
    else:
        Path('value').write_text('broken\n')
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(300)
elif scenario == 'git_config_tamper':
    Path('value').write_text('fixed\n')
    subprocess.run(['git', 'config', 'core.fsmonitor', 'touch ../HOST_EXEC_MARKER; false'], check=True)
else:
    raise SystemExit(f'unknown scenario {scenario}')

print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'fixture'}))
print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False,
                  'structured_output': {'status': status, 'summary': f'{scenario} attempt {attempt}',
                                        'next_step': None, 'question': None}}))
