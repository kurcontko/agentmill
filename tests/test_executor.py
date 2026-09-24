"""Transport invariants; actual Docker behavior is covered by the smoke tests."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from agentmill.contracts import Command, ProcessOutput, RunSpec, RunStopped
from agentmill.executor import Container, Executor


class ExecutorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / 'workspace'
        self.workspace.mkdir()
        self.inputs = self.root / 'inputs'
        self.inputs.mkdir()
        self.config = self.root / 'config.toml'
        self.config.write_text('model="fixture"')
        self.auth = self.root / 'auth.json'
        self.auth.write_text('{}')
        self.spec = RunSpec(str(self.workspace),'task',('true',),profile='chosen',
                            agent_config=str(self.config),auth_file=str(self.auth),credential_env=('FIXTURE_KEY',))
        self.executor = Executor(self.spec,self.root)
        self.calls = []

    def control(self, argv, **kwargs):
        self.calls.append(argv)
        if argv[1:3]==['image','inspect']:
            return json.dumps([{'Id':'sha256:pinned','RepoDigests':['fixture@sha256:digest'],'Os':'linux','Architecture':'arm64'}]).encode()
        return b''

    def process(self, argv, stdout, stderr, timeout, **kwargs):
        self.calls.append(argv)
        stdout.parent.mkdir(parents=True,exist_ok=True)
        stdout.write_bytes(b'')
        stderr.write_bytes(b'')
        return ProcessOutput(0,stdout,stderr,0)

    def test_worker_mounts_narrow_inputs_and_cleanup_owns_container(self):
        with patch.object(self.executor,'control',self.control),patch.object(self.executor,'command',self.process):
            env=self.executor.inspect_image()
            self.assertEqual(env['image_id'],'sha256:pinned')
            with self.executor.container(self.workspace,inputs=self.inputs,worker=True):
                self.assertFalse(self.executor.worker_stopped)
            self.assertTrue(self.executor.worker_stopped)
        create=next(c for c in self.calls if c[1]=='create')
        mounts=[create[i+1] for i,x in enumerate(create) if x=='--mount']
        self.assertEqual(len(mounts),4)
        self.assertIn(f'type=bind,src={self.workspace},dst=/workspace',mounts)
        self.assertIn(f'type=bind,src={self.inputs},dst=/inputs,readonly',mounts)
        self.assertIn('sha256:pinned',create)
        self.assertFalse(any('docker.sock' in x or 'dst=/logs' in x for x in create))
        self.assertTrue(any(c[1:3]==['rm','--force'] for c in self.calls))
        self.assertTrue(any(c[1:3]==['ps','-aq'] for c in self.calls))

    def test_checks_have_no_native_config_auth_or_credentials(self):
        with patch.object(self.executor,'control',self.control),patch.object(self.executor,'command',self.process):
            with self.executor.container(self.workspace) as container:
                container.setup(self.root / 'baseline')
                container.check('true',self.root / 'baseline',1)
        create=next(c for c in self.calls if c[1]=='create')
        self.assertFalse(any('/native/' in x or 'FIXTURE_KEY' in x for x in create))
        for argv in self.calls:
            if argv[1]=='exec':
                self.assertNotIn('--env',argv)

    def test_credentials_only_on_native_exec_and_explicit_configuration_copy(self):
        container=Container(self.executor,'fixture')
        with patch.object(self.executor,'command',self.process),patch.dict(os.environ,{'FIXTURE_KEY':'not-recorded'}):
            output=container.session(Command(('codex','exec','-')),self.root / 'session')
        argv=self.calls[-1]
        self.assertEqual(argv[:4],['docker','exec','--env','FIXTURE_KEY'])
        self.assertNotIn('not-recorded',str(argv))
        self.assertIn('chosen.config.toml',argv[-1])
        self.assertIn('auth.json',argv[-1])
        self.assertEqual(output.stdout.name,'native.jsonl')

    def test_cleanup_failure_prevents_candidate_capture(self):
        with patch.object(self.executor,'control',self.control),patch.object(self.executor,'_remove_container',return_value=False):
            with self.assertRaisesRegex(RunStopped,'container_cleanup_failed'):
                with self.executor.container(self.workspace,worker=True):
                    pass
        self.assertFalse(self.executor.worker_stopped)

    def test_cleanup_failure_does_not_replace_execution_failure(self):
        primary = RunStopped('session_timeout', 2)
        with patch.object(self.executor, 'control', self.control), \
             patch.object(self.executor, '_remove_container', return_value=False):
            with self.assertRaises(RunStopped) as caught:
                with self.executor.container(self.workspace, worker=True):
                    raise primary
        self.assertIs(caught.exception, primary)
        self.assertFalse(self.executor.worker_stopped)
        self.assertIn('container_cleanup_failed', ' '.join(self.executor.errors))

    def test_failed_create_still_attempts_cleanup(self):
        with patch.object(self.executor, 'control', side_effect=RunStopped('runtime_timeout')), \
             patch.object(self.executor, '_remove_container', return_value=True) as remove:
            with self.assertRaisesRegex(RunStopped, 'runtime_timeout'):
                with self.executor.container(self.workspace, worker=True):
                    self.fail('create did not succeed')
        remove.assert_called_once()
        self.assertTrue(self.executor.worker_stopped)

    def test_no_subprocess_is_admitted_after_its_budget(self):
        for maintenance in (False, True):
            with self.subTest(maintenance=maintenance):
                self.executor.deadline = 0
                self.executor.finalize_deadline = 0
                with patch('agentmill.executor.subprocess.Popen', side_effect=AssertionError('admitted expired work')) as launch:
                    with self.assertRaises(RunStopped):
                        self.executor.command(['must-not-start'], self.root/'out', self.root/'err',
                                              10, maintenance=maintenance)
                    launch.assert_not_called()

    def test_delayed_poll_preserves_phase_timeout_and_cancellation_precedence(self):
        for cancel in (False, True):
            now = [0]
            def advance(_):
                now[0] = 10  # Both the 5s command cap and 7s run budget have expired.
                if cancel:
                    self.executor.cancel(15)
            process = Mock(returncode=0)
            process.poll.side_effect = [None, None]
            self.executor.deadline = 7
            self.executor.cancelled = 0
            self.executor.finalize_deadline = None
            with self.subTest(cancel=cancel), patch('agentmill.executor.time.monotonic', lambda: now[0]), \
                 patch('agentmill.executor.time.sleep', advance), \
                 patch('agentmill.executor.subprocess.Popen', return_value=process), \
                 patch.object(self.executor, 'kill_group'):
                output = self.executor.command(['fixture'], self.root/'out', self.root/'err', 5)
            self.assertEqual(output.stop_reason, 'cancelled' if cancel else 'timeout')

    def test_finalization_allowance_is_not_renewed(self):
        with patch('agentmill.executor.time.monotonic', return_value=10):
            self.executor.finalize()
        with patch('agentmill.executor.time.monotonic', return_value=100):
            self.executor.finalize()
        self.assertEqual(self.executor.finalize_deadline, 40)

    def test_cleanup_deadline_race_still_stops_and_removes_container(self):
        command = self.executor.command
        outputs = []
        def expire_before_admission(argv, *args, **kwargs):
            self.calls.append(argv)
            self.executor.deadline = 0
            # Exercise real admission and waiting without requiring a Docker daemon.
            output = command([os.sys.executable, '-c', 'import time; time.sleep(0.05)'],
                             *args, **kwargs)
            outputs.append(output)
            return output
        with patch.object(self.executor, 'command', expire_before_admission), \
             patch.object(self.executor, 'control', return_value=b''):
            self.assertTrue(self.executor._remove_container('fixture'))
        self.assertEqual([argv[1] for argv in self.calls], ['stop', 'rm'])
        self.assertEqual([output.stop_reason for output in outputs], [None, None])

    def test_maintenance_admission_starts_but_never_renews_finalization(self):
        self.executor.deadline = 10
        with patch('agentmill.executor.time.monotonic', return_value=11):
            self.executor.guard(maintenance=True)
        self.assertEqual(self.executor.finalize_deadline, 41)
        with patch('agentmill.executor.time.monotonic', return_value=42):
            with self.assertRaisesRegex(RunStopped, 'finalization_timeout'):
                self.executor.guard(maintenance=True)
            with self.assertRaisesRegex(RunStopped, 'run_duration_limit'):
                self.executor.guard()
        self.assertEqual(self.executor.finalize_deadline, 41)

    def test_uncertain_daemon_cleanup_is_not_reported_as_stopped(self):
        with patch.object(self.executor,'command',self.process),patch.object(self.executor,'control',side_effect=RunStopped('runtime_failed')):
            self.assertFalse(self.executor._remove_container('fixture'))
        with patch.object(self.executor,'command',self.process),patch.object(self.executor,'control',return_value=b'container-id'):
            self.assertFalse(self.executor._remove_container('fixture'))

    def test_phase_failures_and_signal_codes_are_distinct(self):
        self.executor.cancelled=15
        for reason,phase,expected in (('cancelled','session',143),('run_duration_limit','setup',2),
                                      ('timeout','session',2),('timeout','check',1),(None,'setup',1)):
            with self.assertRaises(RunStopped) as caught:
                self.executor.require(ProcessOutput(1,self.root/'out',self.root/'err',0,reason),phase)
            self.assertEqual(caught.exception.exit_code,expected)

    def failing_control(self, stderr, returncode=1, stop_reason=None):
        def command(argv, stdout, stderr_path, timeout, **kwargs):
            stdout.parent.mkdir(parents=True, exist_ok=True)
            stdout.write_bytes(b'')
            stderr_path.write_text(stderr)
            return ProcessOutput(returncode, stdout, stderr_path, 0, stop_reason)
        return patch.object(self.executor, 'command', command)

    def test_runtime_failures_report_the_tool_error_and_a_hint(self):
        cases = (('Error response from daemon: No such image: agentmill:latest', 'image_unavailable', 'mill build'),
                 ('failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is '
                  'correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file '
                  'or directory', 'docker_unavailable', 'Docker is not reachable'),
                 ('Error: No such object: agentmill:latest', 'image_unavailable', 'mill build'),
                 ('permission denied while trying to connect', 'runtime_failed', 'permission denied'))
        for stderr, reason, message in cases:
            self.executor.errors.clear()
            with self.subTest(reason=reason), self.failing_control(stderr), self.assertRaises(RunStopped) as caught:
                self.executor.inspect_image()
            self.assertEqual(caught.exception.reason, reason)
            self.assertIn(message, ' '.join(self.executor.errors))
            self.assertIn('docker image exited 1', self.executor.errors[0])

    def test_runtime_timeouts_and_unshared_mounts_are_explained(self):
        with self.failing_control('', None, 'timeout'), self.assertRaises(RunStopped):
            self.executor.control(['git', '-c', 'core.hooksPath=/dev/null', '--git-dir', '/x', 'clone', 'src'])
        self.assertIn('git clone timed out: no error output', self.executor.errors[-1])
        with self.failing_control('invalid mount config: bind source path does not exist: /tmp/x'), \
             self.assertRaises(RunStopped) as caught:
            self.executor.control(['docker', 'create', '--name', 'x'])
        self.assertIn('shared with the Docker VM', self.executor.errors[-1])
        self.assertEqual(caught.exception.reason, 'runtime_failed')

    def test_mount_rejects_ambiguous_paths_and_config_requires_file(self):
        with self.assertRaises(ValueError):
            Executor.mount(self.root/'path,with,commas','/workspace')
        self.config.unlink()
        with self.assertRaises(ValueError):
            with self.executor.container(self.workspace,worker=True):
                self.fail('invalid mount accepted')


if __name__=='__main__':
    unittest.main()
