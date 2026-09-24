import contextlib
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import signal
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from agentmill.cli import duration, human_event, main, make_spec, parser
from agentmill.contracts import RunOutcome
from agentmill.records import atomic_json


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_spec_and_explicit_flags_have_predictable_precedence(self):
        task = self.root / 'task.md'
        task.write_text('from file')
        spec = self.root / 'run.json'
        spec.write_text(json.dumps({'source':str(self.root),'task':'from spec','checks':['false'],
                                    'agent':'claude','max_sessions':5}))
        args = parser().parse_args(['run','--spec',str(spec),'--task-file',str(task),'--agent','codex',
                                   '--check','true','--max-duration','2m'])
        value = make_spec(args)
        self.assertEqual((value.task,value.agent,value.checks,value.max_sessions,value.max_duration),
                         ('from file','codex',('true',),5,120))
        self.assertEqual(duration('1h'),3600)

    def test_optional_mission_and_explicit_native_files(self):
        (self.root / 'MILL.md').write_text('local optional task')
        config = self.root / 'config.toml'
        config.write_text('model="fixture"')
        with patch.dict(os.environ,{'REPO_PATH':str(self.root),'CHECK_CMD':'true'}):
            value = make_spec(parser().parse_args(['run','--agent-config',str(config),'--profile','review']))
        self.assertEqual(value.task,'local optional task')
        self.assertEqual(value.agent_config,str(config.resolve()))

    def test_invalid_spec_and_missing_task_return_one_with_stderr_only(self):
        for payload in ([],{'source':str(self.root)},
                        {'source':str(self.root),'task':'task','checks':['true'],'extra':'no'}):
            path = self.root / 'spec.json'
            path.write_text(json.dumps(payload))
            stdout,stderr = io.StringIO(),io.StringIO()
            with contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
                code = main(['run','--spec',str(path),'--json'])
            self.assertEqual(code,1)
            self.assertEqual(stdout.getvalue(),'')
            self.assertTrue(stderr.getvalue())

    def test_json_run_emits_only_supervisor_events(self):
        def fake_run(spec,on_event,runs_dir):
            on_event({'schema_version':1,'event':'run.started','run_id':'fixture'})
            return RunOutcome('fixture',exit_code=2,errors=['diagnostic'])
        stdout,stderr=io.StringIO(),io.StringIO()
        with patch('agentmill.cli.run',fake_run),contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
            code=main(['run',str(self.root),'--task','task','--check','true','--json'])
        self.assertEqual(code,2)
        self.assertEqual(json.loads(stdout.getvalue())['event'],'run.started')
        self.assertEqual(stderr.getvalue(),'diagnostic\n')

    def test_full_connected_output_pipe_does_not_prevent_cancellation(self):
        # Fill the pipe before launching; keep its reader connected without draining.
        # Exercise real CLI forwarding, Records, and the runner's signal handler.
        script = '''
import sys, time
from unittest.mock import patch
from agentmill.cli import main
def wait_for_cancel(workspace, *args):
    while True:
        workspace.executor.guard()
        time.sleep(0.01)
with patch('agentmill.runner.Workspace.prepare', wait_for_cancel):
    raise SystemExit(main(sys.argv[1:]))
'''
        for json_mode in (True, False):
            with self.subTest(json_mode=json_mode):
                read_fd, write_fd = os.pipe()
                process = None
                try:
                    os.set_blocking(write_fd, False)
                    try:
                        while True:
                            os.write(write_fd, b'x' * 4096)
                    except BlockingIOError:
                        pass
                    os.set_blocking(write_fd, True)
                    storage = self.root / ('json' if json_mode else 'human')
                    argv = [sys.executable, '-c', script, 'run', str(self.root / 'source'),
                            '--task', 'task', '--check', 'true', '--runs-dir', str(storage)]
                    if json_mode:
                        argv.append('--json')
                    process = subprocess.Popen(argv, cwd=Path(__file__).resolve().parents[1],
                        stdout=write_fd if json_mode else subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL if json_mode else write_fd)
                    deadline = time.monotonic() + 5
                    events = []
                    while time.monotonic() < deadline:
                        events = list(storage.glob('*/events.jsonl'))
                        if events and events[0].stat().st_size:
                            break
                        time.sleep(0.01)
                    self.assertTrue(events, 'supervisor never persisted its start event')
                    process.send_signal(signal.SIGTERM)
                    self.assertEqual(process.wait(timeout=3), 143)
                    outcome = json.loads((events[0].parent / 'outcome.json').read_text())
                    self.assertEqual(outcome['status'], 'cancelled')
                    self.assertIn('event callback failed: TimeoutError', outcome['errors'])
                    self.assertEqual(json.loads(events[0].read_text().splitlines()[-1])['event'], 'run.finished')
                    self.assertTrue(os.get_blocking(write_fd), 'shared descriptor flags must be restored')
                finally:
                    if process and process.poll() is None:
                        process.kill()
                        process.wait(timeout=3)
                    os.close(write_fd)
                    os.close(read_fd)

    def test_invalid_cli_usage_is_not_an_incomplete_run(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(['run','--not-a-flag']),1)
            self.assertEqual(main(['run','--max-duration','unbounded']),1)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(['--help']),0)

    def test_show_without_outcome_is_unknown_and_validates_run_ids(self):
        run_id='r_'+'a'*16
        (self.root / run_id).mkdir()
        stdout=io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(main(['show',run_id,'--runs-dir',str(self.root),'--json']),0)
        self.assertEqual(json.loads(stdout.getvalue())['status'],'unknown')
        for run in ('../escape','r_'+'b'*16):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main(['show',run,'--runs-dir',str(self.root)]),1)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(['diff',run_id,'--runs-dir',str(self.root)]),1)

    def test_show_and_diff_read_final_artifacts(self):
        run_id='r_'+'a'*16
        directory=self.root/run_id
        directory.mkdir()
        outcome=RunOutcome(run_id,status='checked_complete',stop_reason='checked_complete',exit_code=0)
        outcome.artifacts['patch'] = str(directory/'artifacts/result.patch')
        atomic_json(directory/'outcome.json',outcome.to_dict())
        stdout,stderr=io.StringIO(),io.StringIO()
        with contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
            self.assertEqual(main(['show',run_id,'--runs-dir',str(self.root)]),0)
        self.assertEqual(stdout.getvalue(), '')
        self.assertIn('checked_complete',stderr.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(['diff',run_id,'--runs-dir',str(self.root)]),1)
        (directory/'artifacts').mkdir()
        (directory/'artifacts/result.patch').write_bytes(b'fixture patch')
        class Output:
            buffer=io.BytesIO()
        output=Output()
        with patch('sys.stdout',output):
            self.assertEqual(main(['diff',run_id,'--runs-dir',str(self.root)]),0)
        self.assertEqual(output.buffer.getvalue(),b'fixture patch')

    def test_human_result_commands_use_real_storage_and_artifacts(self):
        root = self.root / "custom run's storage"
        run_id = 'r_' + 'c'*16
        directory = root / run_id
        artifacts = directory / 'artifacts'
        artifacts.mkdir(parents=True)
        patch_path = artifacts / 'result.patch'
        patch_path.write_bytes(b'actual patch')
        bundle = artifacts / 'result; touch PWNED; .bundle'
        source = self.root / 'bundle source'
        source.mkdir()
        (source/'proof.txt').write_text('reviewed candidate')
        for args in (['init', '-q', '-b', 'agentmill-candidate'], ['add', '.'],
                     ['-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'fixture'],
                     ['bundle', 'create', str(bundle), 'agentmill-candidate']):
            subprocess.run(['git', '-C', str(source), *args], check=True, capture_output=True, timeout=5)
        outcome = RunOutcome(run_id, status='checked_complete', stop_reason='checked_complete', exit_code=0,
            latest_candidate_sha='candidate', last_passing_candidate_sha='candidate', sessions=1,
            candidate_check_status='passed',
            agent_reply={'status':'done', 'summary':'Fixed the retry bug.', 'question':None, 'next_step':None},
            checks=[{'session':1, 'candidate_sha':'candidate', 'status':'passed'}],
            artifacts={'run_directory':str(directory), 'workspace':str(directory/'workspace'),
                       'patch':str(patch_path), 'bundle':str(bundle)})
        record = {'event':'run.finished', 'outcome':str(directory/'outcome.json'), **outcome.to_dict()}
        stdout,stderr=io.StringIO(),io.StringIO()
        with contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
            human_event(record)
        text = stderr.getvalue()
        self.assertEqual(stdout.getvalue(), '')
        for expected in ('Fixed the retry bug.', 'passed', str(patch_path), str(bundle), str(directory)):
            self.assertIn(expected, text)
        atomic_json(directory/'outcome.json', outcome.to_dict())
        commands = {}
        for line in text.splitlines():
            if line.startswith(('Show: ', 'Diff: ')):
                name, command = line.split(': ', 1)
                args = shlex.split(command)
                self.assertEqual(args[0], 'agentmill')
                self.assertIn(str(root.resolve()), args)
                commands[name] = args[1:]
        self.assertEqual(set(commands), {'Show', 'Diff'})
        review = next(line.removeprefix('Clean review checkout: ') for line in text.splitlines()
                      if line.startswith('Clean review checkout: '))
        self.assertEqual(shlex.split(review), ['git', 'clone', '--branch', 'agentmill-candidate', '--',
                                               str(bundle), f'./review-{run_id}'])
        # Exercise exactly what a user pastes, with metacharacters in a real bundle
        # filename. The shell must pass one path argument, not execute its contents.
        subprocess.run(['sh', '-c', review], cwd=self.root, check=True, capture_output=True, timeout=5)
        self.assertEqual((self.root/f'review-{run_id}'/'proof.txt').read_text(), 'reviewed candidate')
        self.assertFalse((self.root/'PWNED').exists())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(commands['Show']), 0)
        class Output:
            buffer = io.BytesIO()
        with patch('sys.stdout', Output()):
            self.assertEqual(main(commands['Diff']), 0)
            self.assertEqual(sys.stdout.buffer.getvalue(), b'actual patch')

    def test_blocked_result_shows_question_unchecked_candidate_and_missing_patch(self):
        event = dict(event='run.finished', run_id='r_'+'d'*16, outcome=str(self.root/'outcome.json'),
            status='blocked', stop_reason='agent_blocked', sessions=1,
            latest_candidate_sha='new', last_passing_candidate_sha='old',
            candidate_check_status='unchecked',
            agent_reply={'summary':'Need clarification.', 'question':'Which API contract?', 'next_step':None},
            checks=[{'candidate_sha':'old', 'session':0, 'status':'passed'}],
            artifacts={'workspace':str(self.root/'workspace')}, errors=['export unavailable'])
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            human_event(event)
        text = stderr.getvalue()
        for expected in ('Which API contract?', 'unchecked', 'export unavailable', str(self.root/'workspace')):
            self.assertIn(expected, text)
        self.assertNotIn('Diff:', text)
        self.assertNotIn('git clone', text)

    def test_source_only_launcher_prints_executable_inspection_commands(self):
        source = Path(__file__).resolve().parents[1]
        checkout = self.root / "source checkout's launcher"
        checkout.mkdir()
        for name in ('mill', 'basic_loop.py'):
            shutil.copy2(source/name, checkout/name)
        (checkout/'agentmill').symlink_to(source/'agentmill', target_is_directory=True)
        # No installed mill, native clients, or user environment on PATH.
        binaries = self.root/'bin'
        binaries.mkdir()
        for name, executable in (('bash', '/bin/bash'), ('dirname', '/usr/bin/dirname'),
                                 ('python3', sys.executable)):
            (binaries/name).symlink_to(executable)
        env = {'PATH':str(binaries), 'HOME':str(self.root)}
        self.assertIsNone(shutil.which('mill', path=env['PATH']))
        run_id = 'r_' + 'f'*16
        storage = self.root/"run storage's directory"
        directory = storage/run_id
        directory.mkdir(parents=True)
        patch_path = directory/'result.patch'
        patch_path.write_text('retained patch')
        outcome = RunOutcome(run_id, artifacts={'patch':str(patch_path)})
        atomic_json(directory/'outcome.json', outcome.to_dict())
        for launcher in ([str(checkout/'mill')], [sys.executable, '-m', 'agentmill'],
                         [sys.executable, '-m', 'agentmill.cli']):
            result = subprocess.run([*launcher, 'show', run_id, '--runs-dir', str(storage)],
                                    cwd=checkout, env=env, text=True, capture_output=True, check=True, timeout=5)
            commands = dict(line.split(': ', 1) for line in result.stderr.splitlines()
                            if line.startswith(('Show: ', 'Diff: ')))
            self.assertEqual(set(commands), {'Show', 'Diff'})
            for name, command in commands.items():
                with self.subTest(command=name):
                    inspected = subprocess.run(['/bin/sh', '-c', command], cwd=checkout, env=env,
                                               text=True, capture_output=True, timeout=5)
                    self.assertEqual(inspected.returncode, 0, inspected.stderr)
                    if name == 'Diff':
                        self.assertEqual(inspected.stdout, 'retained patch')

    def test_partial_export_is_not_advertised_as_a_final_patch(self):
        run_id = 'r_' + 'e'*16
        directory = self.root / run_id
        (directory/'artifacts').mkdir(parents=True)
        (directory/'artifacts/result.patch').write_text('partial export')
        outcome = RunOutcome(run_id, stop_reason='artifact_export_failed')
        atomic_json(directory/'outcome.json', outcome.to_dict())
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(main(['diff', run_id, '--runs-dir', str(self.root)]), 1)
        self.assertIn('no exported patch', stderr.getvalue())

    def test_human_events_do_not_write_stdout(self):
        events=[dict(event='run.started',run_id='fixture',source='source',revision='HEAD',workspace='workspace',
                     agent='codex',max_sessions=3,max_duration=30,setup_timeout=2,session_timeout=3,check_timeout=2,input_policy='committed only'),
                dict(event='session.started',session=1,max_sessions=3),
                dict(event='candidate.captured',session=1,candidate_sha='sha'),
                dict(event='check.finished',session=0,status='failed',command='check'),
                dict(event='run.finished',status='incomplete',stop_reason='session_limit',latest_candidate_sha='sha',
                     last_passing_candidate_sha=None,outcome='outcome.json',run_id='fixture'),
                dict(event='session.finished')]
        stdout,stderr=io.StringIO(),io.StringIO()
        with contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
            for event in events:
                human_event(event)
        self.assertEqual(stdout.getvalue(),'')
        self.assertIn('incomplete',stderr.getvalue())


if __name__=='__main__':
    unittest.main()
