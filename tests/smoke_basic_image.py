"""Test the public CLI with real Docker and both deterministic native adapters.

No provider credentials or paid model calls. Set AGENTMILL_SMOKE_IMAGE to the
built image. All Docker resources created here have unique names.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def command(*args, **kwargs):
    return subprocess.run(list(args), check=True, **kwargs)


def main():
    image = f'agentmill-contract-test:{uuid.uuid4().hex}'
    base = os.environ.get('AGENTMILL_SMOKE_IMAGE', 'agentmill:ci')
    # Keep bind mounts in a shared host directory on Docker Desktop and Colima.
    with tempfile.TemporaryDirectory(prefix='agentmill-smoke-', dir=ROOT / 'tests') as directory:
        root = Path(directory)
        shutil.copy(ROOT / 'tests/fixtures/native_cli.py', root / 'native_cli.py')
        (root / 'Dockerfile').write_text(
            f'FROM {base}\nUSER root\nCOPY native_cli.py /opt/fixture/native_cli.py\n'
            'RUN chmod +x /opt/fixture/native_cli.py && rm /usr/local/bin/claude /usr/local/bin/codex '
            '&& ln -s /opt/fixture/native_cli.py /usr/local/bin/claude '
            '&& ln -s /opt/fixture/native_cli.py /usr/local/bin/codex\nUSER agent\n')
        command('docker','build','-q','-t',image,str(root))
        try:
            repo = root / 'source with spaces'
            repo.mkdir()
            for args in (('init','-q','-b','main'), ('config','user.name','Test'),
                         ('config','user.email','test@example.com')):
                command('git','-C',str(repo),*args)
            (repo / '.gitignore').write_text('ignored.tmp\n')
            (repo / 'expect-setup').write_text('prepared')
            (repo / 'expect-auth').write_text('fixture-only')
            runs = root / 'runs'
            for backend in ('codex','claude'):
                for mode, expected in (('repair',0), ('regress',2), ('blocked',3), ('missing_terminal',1), ('hang',2), ('hang',143)):
                    (repo / 'mode').write_text(mode)
                    (repo / 'value').write_text('broken\n')
                    command('git','-C',str(repo),'add','.')
                    command('git','-C',str(repo),'commit','--allow-empty','-qm',f'{backend}-{mode}')
                    head = subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
                    (repo / 'value').write_text('keep my unstaged changes\n')
                    (repo / 'staged').write_text('keep my staged file\n')
                    command('git','-C',str(repo),'add','staged')
                    index = (repo / '.git/index').read_bytes()
                    before = set(runs.glob('r_*')) if runs.exists() else set()
                    argv = [sys.executable,'-I',str(ROOT / 'basic_loop.py'),'run',str(repo),
                            '--agent',backend,'--task','Repair value.','--setup','export AGENTMILL_SETUP_FLAG=prepared','--check',
                            'test "$AGENTMILL_SETUP_FLAG" = prepared; test -z "${CODEX_API_KEY:-}${ANTHROPIC_API_KEY:-}"; test "$(cat value)" = fixed',
                            '--max-sessions','2','--max-duration','90s','--session-timeout','1s' if expected==2 and mode=='hang' else '20s',
                            '--image',image,'--runs-dir',str(runs),'--json']
                    stdout = root / 'stdout.jsonl'
                    stderr = root / 'stderr.log'
                    with stdout.open('w') as out, stderr.open('w') as err:
                        process = subprocess.Popen(argv,stdout=out,stderr=err, env={**os.environ, 'CODEX_API_KEY':'fixture-only', 'ANTHROPIC_API_KEY':'fixture-only', 'CLAUDE_CODE_OAUTH_TOKEN':''})
                        try:
                            if mode == 'hang' and expected == 143:
                                deadline = time.monotonic()+60
                                while not any((path / 'workspace/started').exists() for path in set(runs.glob('r_*'))-before):
                                    if process.poll() is not None or time.monotonic() >= deadline:
                                        raise AssertionError('worker did not start: '+stderr.read_text()+stdout.read_text())
                                    time.sleep(0.05)
                                process.send_signal(signal.SIGTERM)
                            actual = process.wait(timeout=100)
                            assert actual == expected, (backend,mode,actual,stderr.read_text(),stdout.read_text())
                        finally:
                            if process.poll() is None:
                                process.kill()
                            process.wait()
                    created = set(runs.glob('r_*'))-before
                    assert len(created)==1
                    run_dir = created.pop()
                    outcome = json.loads((run_dir / 'outcome.json').read_text())
                    events = [json.loads(line) for line in stdout.read_text().splitlines()]
                    assert events[-1]['event']=='run.finished'
                    assert outcome['exit_code']==expected, outcome
                    assert subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()==head
                    assert (repo / 'value').read_text()=='keep my unstaged changes\n'
                    assert (repo / '.git/index').read_bytes()==index
                    assert (repo / 'staged').read_text()=='keep my staged file\n'
                    assert not (repo / 'new.txt').exists()
                    containers = subprocess.check_output(['docker','ps','-aq','--filter',f'label=agentmill.run={run_dir.name}'],text=True)
                    assert not containers.strip(), 'execution container survived'
                    patch = Path(outcome['artifacts']['patch'])
                    assert patch.stat().st_size > 0
                    shown = subprocess.check_output([sys.executable,'-I',str(ROOT / 'basic_loop.py'),'show',run_dir.name,'--runs-dir',str(runs),'--json'],text=True)
                    assert json.loads(shown)==outcome
                    diff = subprocess.check_output([sys.executable,'-I',str(ROOT / 'basic_loop.py'),'diff',run_dir.name,'--runs-dir',str(runs)])
                    assert diff==patch.read_bytes()
                    if mode == 'repair':
                        assert outcome['sessions']==2
                        assert [c['status'] for c in outcome['checks']]==['failed','failed','passed']
                        assert outcome['latest_candidate_sha']==outcome['last_passing_candidate_sha']
                    elif mode == 'regress':
                        assert outcome['last_passing_candidate_sha'] is not None
                        assert outcome['last_passing_candidate_sha']!=outcome['latest_candidate_sha']
                    elif mode == 'blocked':
                        assert outcome['agent_reply']['question']
                        assert [c['session'] for c in outcome['checks']] == [0]
                        assert not (run_dir / 'checks/0001').exists()
                    print(f'PASS Docker {backend}: {mode} (exit {expected})', flush=True)
        finally:
            containers = subprocess.check_output(['docker','ps','-aq','--filter',f'ancestor={image}'],text=True).split()
            if containers:
                command('docker','rm','-f',*containers)
            command('docker','image','rm',image)


if __name__ == '__main__':
    main()
