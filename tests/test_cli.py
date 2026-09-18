import contextlib
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import signal
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
        atomic_json(directory/'outcome.json',outcome.to_dict())
        stdout=io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(main(['show',run_id,'--runs-dir',str(self.root)]),0)
        self.assertIn('checked_complete',stdout.getvalue())
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
