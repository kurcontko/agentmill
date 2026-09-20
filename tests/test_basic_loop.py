"""Behavioral contract for both adapters, using real Git and bounded processes.

Only the Docker transport is replaced here. smoke_basic_image.py exercises it
with the same native CLI fixture in real containers.
"""
from contextlib import contextmanager
from dataclasses import replace
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from agentmill import RunSpec, run
from agentmill.executor import Executor
from agentmill.contracts import RunStopped
from agentmill.records import Records, atomic_json
from agentmill.workspace import Workspace

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'tests/fixtures/native_cli.py'


class FixtureContainer:
    def __init__(self, executor, workspace, inputs):
        self.executor = executor
        self.workspace = workspace
        self.inputs = inputs
        self.name = 'fixture-container'
        self.home = Path(tempfile.mkdtemp(dir=executor.directory))
        self.env = {'PATH': os.environ['PATH'], 'HOME': str(self.home),
                    'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.com',
                    'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.com'}

    def execute(self, script, directory, label, timeout):
        if script.endswith(' --version'):
            argv = [sys.executable, str(FIXTURE), self.executor.spec.agent, '--version']
        else:
            argv = ['bash', '-ec', script]
        return self.executor.command(argv, directory / f'{label}.log', directory / f'{label}.stderr.log',
                                     timeout, cwd=self.workspace, env=self.env)

    def setup(self, directory):
        result = self.execute(self.executor.spec.setup, directory, 'setup', self.executor.spec.setup_timeout)
        self.executor.require(result, 'setup')

    def check(self, command, directory, number):
        return self.execute(command, directory, f'check-{number:02d}', self.executor.spec.check_timeout)

    def session(self, command, directory):
        return self.executor.command([sys.executable, str(FIXTURE), *command.argv],
                                     directory / 'native.jsonl', directory / 'native.stderr.log',
                                     self.executor.spec.session_timeout, cwd=self.workspace,
                                     env=self.env, stdin=self.inputs / 'prompt.txt')


@contextmanager
def fixture_container(executor, workspace, *, inputs=None, worker=False):
    if worker:
        executor.worker_stopped = False
    try:
        yield FixtureContainer(executor, workspace, inputs)
    finally:
        if worker:
            executor.worker_stopped = True


class BasicLoopTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'source with spaces'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.com')
        (self.repo / 'value').write_text('broken\n')
        (self.repo / 'mode').write_text('repair')
        (self.repo / '.gitignore').write_text('ignored.tmp\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD')
        self.spec = RunSpec(str(self.repo), 'Repair value.', ('test "$(cat value)" = fixed',),
                            max_sessions=2, max_duration=30, setup_timeout=2,
                            check_timeout=2, session_timeout=2)
        self.addCleanup(patch.stopall)
        patch.object(Executor, 'container', fixture_container).start()
        patch.object(Executor, 'inspect_image', lambda self: {'image_id': 'sha256:fixture'}).start()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True).strip()

    def set_mode(self, mode):
        (self.repo / 'mode').write_text(mode)
        self.git('add', 'mode')
        self.git('commit', '-qm', mode)

    def launch(self, backend='codex', **kwargs):
        self.events = []
        outcome = run(replace(self.spec, agent=backend, **kwargs), self.events.append, runs_dir=self.root / 'runs')
        self.run_dir = Path(outcome.artifacts['run_directory'])
        self.assertEqual(json.loads((self.run_dir / 'outcome.json').read_text()), outcome.to_dict())
        self.assertEqual([e['seq'] for e in self.events], list(range(1, len(self.events)+1)))
        self.assertEqual(self.events[-1]['event'], 'run.finished')
        return outcome

    def test_both_adapters_repair_red_baseline_preserve_dirty_source_and_export_exact_tree(self):
        (self.repo / 'value').write_text('my unstaged changes\n')
        (self.repo / 'staged').write_text('my staged changes\n')
        self.git('add', 'staged')
        (self.repo / 'untracked').write_text('my untracked file\n')
        (self.repo / 'ignored.tmp').write_text('my ignored file\n')
        status = self.git('status', '--porcelain')
        index = (self.repo / '.git/index').read_bytes()
        for backend in ('codex', 'claude'):
            with self.subTest(backend=backend):
                outcome = self.launch(backend)
                self.assertEqual(outcome.status, 'checked_complete', outcome.to_dict())
                self.assertEqual(outcome.sessions, 2)
                self.assertEqual(outcome.base_revision, self.base)
                self.assertEqual(outcome.latest_candidate_sha, outcome.last_passing_candidate_sha)
                self.assertEqual([c['status'] for c in outcome.checks], ['failed', 'failed', 'passed'])
                self.assertEqual(self.git('rev-parse', 'HEAD'), self.base)
                self.assertEqual(self.git('status', '--porcelain'), status)
                self.assertEqual((self.repo / '.git/index').read_bytes(), index)
                self.assertEqual((self.repo / 'value').read_text(), 'my unstaged changes\n')
                self.assertEqual((self.repo / 'ignored.tmp').read_text(), 'my ignored file\n')
                self.assertTrue((self.run_dir / 'workspace/.env').is_file())
                imported = self.root / f'import-{backend}'
                subprocess.run(['git', 'clone', '-q', '-b', 'agentmill-candidate', outcome.artifacts['bundle'], str(imported)], check=True)
                self.assertEqual((imported / 'value').read_text(), 'fixed\n')
                self.assertEqual((imported / 'new.txt').read_text(), 'new file\n')
                self.assertEqual((imported / 'binary.dat').read_bytes(), b'\x00\xff\x01')
                subprocess.run(['bash', '-ec', self.spec.checks[0]], cwd=imported, check=True)
                for excluded in ('.env', 'ignored.tmp', 'staged', 'untracked'):
                    self.assertFalse((imported / excluded).exists())
                subprocess.run(['git', '-C', str(imported), 'checkout', '-q', outcome.base_revision], check=True)
                subprocess.run(['git', '-C', str(imported), 'apply', '--index', outcome.artifacts['patch']], check=True)
                tree = subprocess.check_output(['git', '-C', str(imported), 'write-tree'], text=True).strip()
                expected = subprocess.check_output(['git', '-C', str(imported), 'rev-parse', outcome.latest_candidate_sha+'^{tree}'], text=True).strip()
                self.assertEqual(tree, expected)

    def test_both_adapters_preserve_last_passing_candidate_at_limit(self):
        self.set_mode('regress')
        for backend in ('codex', 'claude'):
            outcome = self.launch(backend)
            self.assertEqual((outcome.status, outcome.exit_code), ('incomplete', 2))
            self.assertNotEqual(outcome.latest_candidate_sha, outcome.last_passing_candidate_sha)
            self.assertIsNotNone(outcome.last_passing_candidate_sha)
            self.assertEqual(outcome.checks[-1]['status'], 'failed')

    def test_both_adapters_blocked_preserves_candidate_without_checking_it(self):
        self.set_mode('blocked')
        for backend in ('codex', 'claude'):
            outcome = self.launch(backend, checks=('true',))
            self.assertEqual((outcome.status, outcome.exit_code, outcome.sessions), ('blocked', 3, 1))
            self.assertTrue(outcome.agent_reply['question'])
            self.assertEqual([c['session'] for c in outcome.checks], [0])
            self.assertEqual(outcome.last_passing_candidate_sha, outcome.base_revision)
            self.assertNotEqual(outcome.latest_candidate_sha, outcome.base_revision)
            self.assertFalse((self.run_dir / 'checks/0001').exists())
            self.assertEqual(outcome.candidate_check_status, 'unchecked')

    def test_one_session_is_a_hard_limit_for_a_continuing_reply(self):
        self.set_mode('continue')
        for backend in ('codex', 'claude'):
            outcome = self.launch(backend, max_sessions=1)
            self.assertEqual((outcome.sessions, outcome.stop_reason, outcome.exit_code), (1, 'session_limit', 2))
            self.assertEqual((self.run_dir / 'workspace/iteration').read_text(), '1')

    def test_interrupted_capture_retries_once_with_finalization_budget(self):
        capture, git = Workspace.capture, Workspace.git
        for backend in ('codex', 'claude'):
            for cancel in (False, True):
                calls = []
                def record_capture(workspace, session, *, maintenance=False):
                    calls.append(maintenance)
                    return capture(workspace, session, maintenance=maintenance)
                def interrupt_git(workspace, *args, **kwargs):
                    result = git(workspace, *args, **kwargs)
                    if calls and args[0] == 'read-tree' and not kwargs.get('maintenance'):
                        if cancel:
                            workspace.executor.cancel(signal.SIGINT)
                        else:
                            workspace.executor.deadline = 0
                    return result
                with self.subTest(backend=backend, cancel=cancel), \
                     patch.object(Workspace, 'capture', record_capture), patch.object(Workspace, 'git', interrupt_git):
                    outcome = self.launch(backend)
                    self.assertEqual(calls, [False, True])
                    self.assertEqual((outcome.stop_reason, outcome.exit_code),
                                     ('cancelled', 130) if cancel else ('run_duration_limit', 2))
                    self.assertNotEqual(outcome.latest_candidate_sha, outcome.base_revision)
                    self.assertTrue(Path(outcome.artifacts['patch']).stat().st_size)
                    self.assertEqual([check['session'] for check in outcome.checks], [0])
                    self.assertFalse(any('capture failed' in error for error in outcome.errors))

    def test_capture_retry_failure_preserves_original_interruption(self):
        calls = []
        def fail_capture(workspace, session, *, maintenance=False):
            calls.append(maintenance)
            if not maintenance:
                workspace.executor.deadline = 0
                raise RunStopped('run_duration_limit', 2)
            raise OSError('retry storage unavailable')
        with patch.object(Workspace, 'capture', fail_capture):
            outcome = self.launch()
        self.assertEqual(calls, [False, True])
        self.assertEqual((outcome.stop_reason, outcome.exit_code), ('run_duration_limit', 2))
        self.assertIn('retry storage unavailable', ' '.join(outcome.errors))
        self.assertEqual(outcome.latest_candidate_sha, outcome.base_revision)

    def test_capture_already_finalizing_is_not_retried(self):
        self.set_mode('blocked')
        with patch.object(Workspace, 'capture', side_effect=RunStopped('run_duration_limit', 2)) as capture:
            outcome = self.launch()
        self.assertEqual(capture.call_count, 1)
        self.assertTrue(capture.call_args.kwargs['maintenance'])
        self.assertEqual(outcome.stop_reason, 'run_duration_limit')

    def test_unchanged_continuing_candidate_is_still_rechecked(self):
        self.set_mode('continue_unchanged')
        for backend in ('codex', 'claude'):
            outcome = self.launch(backend, checks=('true',), max_sessions=1)
            self.assertEqual(outcome.stop_reason, 'session_limit')
            self.assertEqual(outcome.latest_candidate_sha, outcome.base_revision)
            self.assertEqual([check['session'] for check in outcome.checks], [0, 1])

    def test_unchanged_blocked_candidate_retains_historical_check_evidence(self):
        self.set_mode('blocked_unchanged')
        for backend in ('codex', 'claude'):
            outcome = self.launch(backend, checks=('true',))
            self.assertEqual((outcome.stop_reason, outcome.exit_code), ('agent_blocked', 3))
            self.assertEqual(outcome.latest_candidate_sha, outcome.base_revision)
            self.assertEqual(outcome.last_passing_candidate_sha, outcome.base_revision)
            self.assertEqual(outcome.candidate_check_status, 'passed')
            self.assertEqual([check['session'] for check in outcome.checks], [0])

    def test_cancellation_during_export_keeps_evidence_and_signal_exit(self):
        self.set_mode('done')
        export = Workspace.export
        def cancel_after_export(workspace, passing):
            artifacts = export(workspace, passing)
            workspace.executor.cancel(signal.SIGTERM)
            return artifacts
        with patch.object(Workspace, 'export', cancel_after_export):
            outcome = self.launch()
        self.assertEqual((outcome.stop_reason, outcome.exit_code), ('cancelled', 143))
        self.assertEqual(outcome.latest_candidate_sha, outcome.last_passing_candidate_sha)
        self.assertEqual(outcome.candidate_check_status, 'passed')
        self.assertTrue(Path(outcome.artifacts['bundle']).is_file())
        self.assertIn('cancelled while handling: checked_complete', outcome.errors)

    def test_primary_native_failure_survives_capture_and_export_failures(self):
        for mode, reason in (('crash', 'session_failed'), ('missing_terminal', 'invalid_native_terminal')):
            self.set_mode(mode)
            for backend in ('codex', 'claude'):
                with self.subTest(mode=mode, backend=backend), \
                     patch.object(Workspace, 'capture', side_effect=OSError('capture unavailable')), \
                     patch.object(Workspace, 'export', side_effect=OSError('export unavailable')):
                    outcome = self.launch(backend)
                    self.assertEqual((outcome.stop_reason, outcome.exit_code), (reason, 1))
                    self.assertIn('capture unavailable', ' '.join(outcome.errors))
                    self.assertIn('export unavailable', ' '.join(outcome.errors))
                    self.assertEqual(outcome.latest_candidate_sha, outcome.base_revision)
                    self.assertEqual((self.run_dir / 'workspace/value').read_text(), 'fixed\n')
                    self.assertNotIn('patch', outcome.artifacts)

    def test_required_capture_and_export_failures_prevent_success(self):
        self.set_mode('done')
        for operation, reason in (('capture', 'candidate_capture_failed'), ('export', 'artifact_export_failed')):
            with self.subTest(operation=operation), patch.object(Workspace, operation, side_effect=OSError(operation)):
                outcome = self.launch()
                self.assertEqual((outcome.stop_reason, outcome.exit_code), (reason, 1))

    def test_run_deadline_at_success_boundary_is_not_success(self):
        self.set_mode('done')
        from agentmill.checks import check_candidate
        def expire_after_checks(spec, executor, *args, **kwargs):
            result = check_candidate(spec, executor, *args, **kwargs)
            if result[0]:
                executor.deadline = 0
            return result
        with patch('agentmill.runner.check_candidate', expire_after_checks):
            outcome = self.launch()
        self.assertEqual((outcome.stop_reason, outcome.exit_code), ('run_duration_limit', 2))
        self.assertEqual(outcome.checks[-1]['status'], 'passed')

    def test_success_decided_in_budget_can_export_during_finalization(self):
        self.set_mode('done')
        export = Workspace.export
        def after_deadline(workspace, passing):
            workspace.executor.deadline = 0
            return export(workspace, passing)
        with patch.object(Workspace, 'export', after_deadline):
            outcome = self.launch()
        self.assertEqual(outcome.status, 'checked_complete')
        self.assertTrue(Path(outcome.artifacts['bundle']).is_file())

    def test_expired_finalization_skips_export_but_writes_outcome(self):
        self.set_mode('crash')
        def expire_during_capture(workspace, *args, **kwargs):
            workspace.executor.finalize_deadline = 0
            raise OSError('capture exhausted finalization')
        with patch.object(Workspace, 'capture', expire_during_capture), patch.object(Workspace, 'export') as export:
            outcome = self.launch()
            export.assert_not_called()
        self.assertEqual(outcome.stop_reason, 'session_failed')
        self.assertIn('finalization', ' '.join(outcome.errors))

    def test_final_record_failure_still_restores_signal_handlers(self):
        self.set_mode('done')
        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        with patch.object(Records, 'finish', side_effect=OSError('storage unavailable')):
            with self.assertRaisesRegex(OSError, 'storage unavailable'):
                self.launch()
        self.assertEqual({sig: signal.getsignal(sig) for sig in handlers}, handlers)

    def test_uncertain_cleanup_skips_capture_and_remains_visible_on_cancellation(self):
        self.set_mode('done')
        @contextmanager
        def uncertain(executor, workspace, *, inputs=None, worker=False):
            with fixture_container(executor, workspace, inputs=inputs, worker=worker) as container:
                yield container
            if worker:
                executor.worker_stopped = False
                if cancel:
                    executor.cancel(signal.SIGTERM)
                raise RunStopped('container_cleanup_failed')
        for cancel in (False, True):
            with self.subTest(cancel=cancel), patch.object(Executor, 'container', uncertain), \
                 patch.object(Workspace, 'capture') as capture:
                outcome = self.launch()
                capture.assert_not_called()
            self.assertEqual(outcome.exit_code, 143 if cancel else 1)
            self.assertEqual(outcome.latest_candidate_sha, outcome.base_revision)
            self.assertIn('capture_unsafe_worker_running', ' '.join(outcome.errors))
            if cancel:
                self.assertIn('container_cleanup_failed', ' '.join(outcome.errors))

    def test_check_record_failure_does_not_mask_unavailable_check(self):
        with patch('agentmill.checks.atomic_json', side_effect=OSError('check record unavailable')):
            outcome = self.launch(checks=('exec agentmill-nonexistent-command',))
        self.assertEqual(outcome.stop_reason, 'check_command_unavailable')
        self.assertIn('check record unavailable', ' '.join(outcome.errors))

    def test_check_record_failure_after_passing_checks_still_fails(self):
        with patch('agentmill.checks.atomic_json', side_effect=OSError('check record unavailable')):
            outcome = self.launch(checks=('true',))
        self.assertEqual((outcome.stop_reason, outcome.exit_code), ('runtime_error', 1))
        self.assertEqual(outcome.checks[0]['status'], 'passed')
        self.assertIn('check record unavailable', ' '.join(outcome.errors))

    def test_failed_initial_checkout_does_not_publish_a_partial_revision(self):
        with patch.object(Workspace, 'checkout', side_effect=OSError('checkout unavailable')), \
             patch.object(Workspace, 'export') as export:
            outcome = self.launch()
        export.assert_not_called()
        self.assertEqual((outcome.stop_reason, outcome.exit_code), ('runtime_error', 1))
        self.assertIsNone(outcome.base_revision)
        self.assertIsNone(outcome.latest_candidate_sha)
        self.assertEqual(outcome.sessions, 0)

    def test_partial_check_set_is_not_a_passing_candidate(self):
        outcome = self.launch(checks=('true', 'exec agentmill-nonexistent-command'))
        self.assertEqual(outcome.stop_reason, 'check_command_unavailable')
        self.assertEqual(outcome.checks[0]['status'], 'passed')
        self.assertEqual(outcome.candidate_check_status, 'error')

    def test_both_adapters_protocol_and_process_failures_capture_work(self):
        for mode in ('malformed', 'deep_json', 'missing_terminal', 'native_error', 'bad_schema', 'crash'):
            self.set_mode(mode)
            for backend in ('codex', 'claude'):
                with self.subTest(mode=mode, backend=backend):
                    outcome = self.launch(backend)
                    self.assertEqual((outcome.status, outcome.sessions), ('failed', 1), outcome.to_dict())
                    self.assertNotEqual(outcome.latest_candidate_sha, outcome.base_revision)
                    self.assertIsNone(outcome.agent_reply)
                    self.assertIsNone(outcome.last_passing_candidate_sha)
                    self.assertTrue(Path(outcome.artifacts['patch']).stat().st_size)

    def test_checks_have_no_host_credentials_and_setup_runs_per_candidate(self):
        self.set_mode('done')
        with patch.dict(os.environ, {'CODEX_API_KEY': 'fixture-only', 'ANTHROPIC_API_KEY': 'fixture-only'}):
            outcome = self.launch(setup='test -z "${CODEX_API_KEY:-}${ANTHROPIC_API_KEY:-}"; cat value > ignored.tmp',
                                  checks=('test -z "${CODEX_API_KEY:-}${ANTHROPIC_API_KEY:-}"; cmp value ignored.tmp',))
        self.assertEqual(outcome.status, 'checked_complete', outcome.to_dict())
        self.assertEqual((self.run_dir / 'checks/0000/ignored.tmp').read_text(), 'broken\n')
        self.assertEqual((self.run_dir / 'checks/0001/ignored.tmp').read_text(), 'fixed\n')

    def test_setup_and_missing_check_stop_before_agent(self):
        for kwargs, reason in (({'setup':'exit 7'}, 'setup_failed'),
                               ({'checks': ('exec agentmill-nonexistent-command',)}, 'check_command_unavailable'),
                               ({'setup':'printf changed > value'}, 'check_setup_changed_candidate')):
            outcome = self.launch(**kwargs)
            self.assertEqual(outcome.stop_reason, reason)
            self.assertEqual(outcome.sessions, 0)

    def test_tracked_check_mutation_cannot_pass(self):
        outcome = self.launch(checks=('printf changed > value',))
        self.assertEqual(outcome.stop_reason, 'check_changed_candidate')
        self.assertIsNone(outcome.last_passing_candidate_sha)
        self.assertEqual(outcome.checks[-1]['status'], 'error')
        self.assertEqual([e for e in self.events if e['event']=='check.finished'][-1]['status'], 'error')

    def test_agent_commits_are_optional_and_not_trusted_for_capture(self):
        for mode in ('commit', 'git_tamper'):
            self.set_mode(mode)
            outcome = self.launch()
            self.assertEqual(outcome.status, 'checked_complete', outcome.to_dict())
            self.assertTrue(Path(outcome.artifacts['patch']).is_file())

    def assert_child_stopped(self):
        pid = (self.run_dir / 'workspace/child.pid').read_text()
        state = subprocess.run(['ps','-o','stat=','-p',pid], capture_output=True, text=True).stdout.strip()
        self.assertTrue(not state or state.startswith('Z'), state)

    def test_both_adapters_session_deadlines_preserve_and_kill_descendants(self):
        self.set_mode('hang')
        for backend in ('codex', 'claude'):
            outcome = self.launch(backend, session_timeout=0.3)
            self.assertEqual((outcome.status, outcome.stop_reason), ('incomplete', 'session_timeout'))
            self.assertNotEqual(outcome.latest_candidate_sha, outcome.base_revision)
            self.assert_child_stopped()

    def test_total_duration_bounds_setup(self):
        outcome = self.launch(setup='sleep 10', setup_timeout=20, max_duration=1.5)
        self.assertEqual((outcome.status, outcome.stop_reason), ('incomplete', 'run_duration_limit'))

    def test_both_adapters_cancel_preserves_work(self):
        self.set_mode('hang')
        for backend in ('codex', 'claude'):
            done = threading.Event()
            def cancel_when_started():
                while not done.wait(0.02):
                    if list((self.root / 'runs').glob('*/workspace/started')):
                        os.kill(os.getpid(), signal.SIGTERM)
                        return
            for started in (self.root / 'runs').glob('*/workspace/started'):
                started.unlink()
            thread = threading.Thread(target=cancel_when_started)
            thread.start()
            try:
                outcome = self.launch(backend)
            finally:
                done.set()
                thread.join()
            self.assertEqual((outcome.status, outcome.exit_code), ('cancelled', 143))
            self.assertNotEqual(outcome.latest_candidate_sha, outcome.base_revision)
            self.assert_child_stopped()

    def test_callback_failure_does_not_abandon_run(self):
        self.set_mode('done')
        def broken(_):
            raise BrokenPipeError()
        outcome = run(self.spec, broken, runs_dir=self.root / 'runs')
        self.assertEqual(outcome.status, 'checked_complete')
        self.assertIn('event callback failed: BrokenPipeError', outcome.errors)

    def test_native_inputs_are_validated_before_source_or_checks(self):
        fifo = self.root / 'config-pipe'
        os.mkfifo(fifo)
        for field in ('agent_config', 'auth_file'):
            for path in (self.root / 'missing', self.root, fifo):
                with self.subTest(field=field, path=path):
                    with patch('agentmill.runner.Workspace.prepare') as prepare:
                        with self.assertRaisesRegex(ValueError, f'{field} must be a regular file'):
                            self.launch(**{field: str(path)})
                        prepare.assert_not_called()
                    self.assertFalse((self.root / 'runs').exists())

    def test_outcome_is_final(self):
        self.set_mode('done')
        outcome = self.launch()
        records = Records(self.root / 'runs')
        records.finish(outcome)
        with self.assertRaises(RuntimeError):
            records.finish(outcome)


if __name__ == '__main__':
    unittest.main()
