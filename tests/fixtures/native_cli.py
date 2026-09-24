#!/usr/bin/env python3
"""Deterministic native CLI fixture, also installed into the Docker smoke image."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

backend = Path(sys.argv[0]).name
if backend == 'native_cli.py':
    backend = sys.argv.pop(1)
if '--version' in sys.argv:
    print(f'{backend} fixture-1')
    raise SystemExit(0)
prompt = sys.stdin.read()
assert 'Task:' in prompt
assert '--json-schema' in sys.argv if backend == 'claude' else '--output-schema' in sys.argv
if Path('expect-setup').exists():
    assert os.environ.get('AGENTMILL_SETUP_FLAG') == Path('expect-setup').read_text()
if Path('expect-auth-file').exists():
    auth = Path(os.environ['CODEX_HOME']) / 'auth.json'
    assert json.loads(auth.read_text()) == {'OPENAI_API_KEY': 'fixture-only'}
    assert not os.environ.get('CODEX_API_KEY')
elif Path('expect-auth').exists():
    name = 'CODEX_API_KEY' if backend == 'codex' else 'ANTHROPIC_API_KEY'
    if Path('expect-auth-name').exists():
        name = Path('expect-auth-name').read_text()
    assert os.environ.get(name) == Path('expect-auth').read_text()
mode = Path('mode').read_text().strip()
if mode not in ('blocked_unchanged', 'continue_unchanged'):
    count = Path('iteration')
    iteration = int(count.read_text()) + 1 if count.exists() else 1
    count.write_text(str(iteration))
    Path('new.txt').write_text('new file\n')
    Path('binary.dat').write_bytes(b'\x00\xff\x01')
    Path('.env').write_text('FIXTURE_SECRET=excluded\n')
    Path('ignored.tmp').write_text('generated\n')
    if mode == 'repair':
        if iteration > 1:
            assert 'Status: failed' in prompt
        Path('value').write_text('fixed\n' if iteration == 2 else 'partial\n')
    elif mode == 'regress':
        Path('value').write_text('fixed\n' if iteration == 1 else 'broken\n')
    else:
        Path('value').write_text('fixed\n')
if mode == 'git_tamper':
    hook = Path('.git/hooks/post-checkout')
    hook.write_text('#!/bin/sh\ntouch /tmp/agentmill-hook-must-not-run\n')
    hook.chmod(0o755)
    subprocess.run(['git','config','filter.evil.clean','touch /tmp/agentmill-filter-must-not-run'], check=True)
    Path('.gitattributes').write_text('* filter=evil\n')
if mode == 'commit':
    subprocess.run(['git','add','value','new.txt'], check=True)
    subprocess.run(['git','commit','-qm','native commit'], check=True)
if mode == 'hang':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen([sys.executable,'-c',
        'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(120)'])
    Path('child.pid').write_text(str(child.pid))
    Path('started').touch()
    time.sleep(120)
if mode == 'crash':
    raise SystemExit(7)
if mode == 'deep_json':
    print('[' * 2000 + '0' + ']' * 2000)
    raise SystemExit(0)
if mode == 'malformed':
    print('done')
    raise SystemExit(0)
status = 'continue' if mode in ('continue', 'continue_unchanged', 'regress') else 'blocked' if mode in ('blocked', 'blocked_unchanged') else 'done'
reply = dict(status=status, summary='Changed value.', next_step=None,
             question='Need the API contract.' if status == 'blocked' else None)
if mode == 'bad_schema':
    reply['status'] = True
if backend == 'claude':
    print(json.dumps({'type':'system','subtype':'init','session_id':'fixture'}))
    if mode != 'missing_terminal':
        print(json.dumps({'type':'result','subtype':'error_max_turns' if mode == 'native_error' else 'success',
                          'is_error':mode == 'native_error','structured_output':reply,
                          'usage':{'input_tokens':12},'total_cost_usd':0.001}))
else:
    print(json.dumps({'type':'thread.started','thread_id':'fixture'}))
    print(json.dumps({'type':'turn.started'}))
    print(json.dumps({'type':'item.completed','item':{'id':'1','type':'agent_message','text':json.dumps(reply)}}))
    if mode != 'missing_terminal':
        print(json.dumps({'type':'turn.failed' if mode == 'native_error' else 'turn.completed',
                          'usage':{'input_tokens':12,'output_tokens':4}}))
