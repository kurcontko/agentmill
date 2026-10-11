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
from agentmill.contracts import Check, RunStopped
from agentmill.ledger import Ledger
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

    def session(self, command, directory, progress=None):
        result = self.executor.command([sys.executable, str(FIXTURE), *command.argv],
                                       directory / 'native.log', directory / 'native.stderr.log',
                                       self.executor.spec.session_timeout, cwd=self.workspace,
                                       env=self.env, stdin=self.inputs / 'prompt.txt', progress=progress)
        result.stdout = result.stdout.rename(directory / 'native.jsonl')
        return result


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
                subprocess.run(['bash', '-ec', self.spec.checks[0].run], cwd=imported, check=True)
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
        def cancel_after_export(workspace, passing, **kwargs):
            artifacts = export(workspace, passing, **kwargs)
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
        def after_deadline(workspace, passing, **kwargs):
            workspace.executor.deadline = 0
            return export(workspace, passing, **kwargs)
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
                    # One retry from captured work; the second consecutive failure stops.
                    outcome = self.launch(backend)
                    self.assertEqual((outcome.status, outcome.sessions), ('failed', 2), outcome.to_dict())
                    self.assertEqual(outcome.exit_code, 1)
                    self.assertIn('session 1 ended without a valid reply', ' '.join(outcome.errors))
                    self.assertNotEqual(outcome.latest_candidate_sha, outcome.base_revision)
                    self.assertIsNone(outcome.agent_reply)
                    # Session 1's work was checked for feedback and evidence; the final failed
                    # session's work is captured but unchecked, and never completes a run.
                    self.assertIsNotNone(outcome.last_passing_candidate_sha)
                    self.assertNotEqual(outcome.last_passing_candidate_sha, outcome.latest_candidate_sha)
                    self.assertEqual(outcome.candidate_check_status, 'unchecked')
                    self.assertTrue(Path(outcome.artifacts['patch']).stat().st_size)

    def test_native_failure_on_final_session_is_not_retried(self):
        self.set_mode('crash')
        outcome = self.launch(max_sessions=1)
        self.assertEqual((outcome.stop_reason, outcome.exit_code, outcome.sessions), ('session_failed', 1, 1))
        self.assertFalse(any('ended without a valid reply' in error for error in outcome.errors))

    def test_both_adapters_continue_from_work_captured_before_a_native_crash(self):
        self.set_mode('crash_once')
        for backend in ('codex', 'claude'):
            with self.subTest(backend=backend):
                outcome = self.launch(backend, max_sessions=3)
                self.assertEqual((outcome.status, outcome.sessions), ('checked_complete', 2), outcome.to_dict())
                self.assertEqual(outcome.latest_candidate_sha, outcome.last_passing_candidate_sha)
                # The crashed session's changed work was checked, then carried into session 2.
                self.assertEqual([c['session'] for c in outcome.checks], [0, 1, 2])
                prompt = (self.run_dir / 'sessions/0002/prompt.txt').read_text()
                self.assertIn('ended without a valid reply (session_failed)', prompt)
                self.assertIn('session 1 ended without a valid reply', ' '.join(outcome.errors))

    def test_source_must_be_a_checkout_root_before_any_run_is_created(self):
        plain = self.root / 'plain'
        plain.mkdir()
        linked = self.root / 'linked'
        linked.mkdir()
        (linked / '.git').write_text('gitdir: elsewhere\n')
        for source, message in ((plain, 'not the root of a Git checkout'), (linked, 'linked worktrees')):
            with self.subTest(source=source.name), self.assertRaisesRegex(ValueError, message):
                self.launch(source=str(source))
        self.assertFalse((self.root / 'runs').exists())

    def test_check_dir_is_snapshotted_for_checks_before_the_source_is_prepared(self):
        self.set_mode('done')
        held_out = self.root / 'held-out'
        held_out.mkdir()
        (held_out / 'check.sh').write_text('test "$(cat value)" = fixed\n')
        outcome = self.launch(check_dir=str(held_out))
        self.assertEqual(outcome.status, 'checked_complete', outcome.to_dict())
        self.assertEqual((self.run_dir / 'verifier/check.sh').read_text(), 'test "$(cat value)" = fixed\n')
        self.assertFalse((self.run_dir / 'workspace/check.sh').exists())
        with self.assertRaisesRegex(ValueError, 'check_dir must be a directory'):
            self.launch(check_dir=str(held_out / 'check.sh'))

    def test_prompt_hides_the_command_of_a_held_out_check_only(self):
        checks = (Check('unit', 'pytest -q tests'), Check('acceptance', 'pytest -q /checks/test_accept.py'))
        shown = Ledger(checks, self.root / 'ledger.json', held_out=True).render()
        self.assertIn('- [unchecked] unit: pytest -q tests', shown)
        self.assertIn('- [unchecked] acceptance: held out; runs after your session', shown)
        self.assertNotIn('test_accept.py', shown)
        self.assertIn('do not reply blocked', shown)
        # Without a check directory, /checks is an ordinary path the worker may have.
        plain = Ledger(checks, self.root / 'ledger.json').render()
        self.assertIn('pytest -q /checks/test_accept.py', plain)
        self.assertNotIn('Held-out', plain)

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

    def test_both_adapters_continue_after_a_session_timeout(self):
        self.set_mode('hang_once')
        for backend in ('codex', 'claude'):
            with self.subTest(backend=backend):
                outcome = self.launch(backend, session_timeout=0.5)
                self.assertEqual((outcome.status, outcome.sessions), ('checked_complete', 2), outcome.to_dict())
                self.assertIn('(session_timeout)', ' '.join(outcome.errors))
                self.assertIn('(session_timeout)', (self.run_dir / 'sessions/0002/prompt.txt').read_text())
                self.assert_child_stopped()

    def test_long_sessions_report_progress_without_affecting_the_run(self):
        self.set_mode('hang_once')
        with patch.object(Executor, 'progress_interval', 0.1):
            outcome = self.launch(session_timeout=0.6)
        self.assertEqual(outcome.status, 'checked_complete', outcome.to_dict())
        progress = [e for e in self.events if e['event'] == 'session.progress']
        self.assertTrue(progress)
        self.assertEqual({e['session'] for e in progress}, {1})
        self.assertTrue(all(isinstance(e['native_events'], int) for e in progress))
        with patch.object(Executor, 'progress_interval', 0.1), \
             patch.object(Records, 'emit', side_effect=OSError('events unavailable')):
            output = Executor(self.spec, self.root).command(
                [sys.executable, '-c', 'import time; time.sleep(0.4)'], self.root / 'out', self.root / 'err', 5,
                progress=lambda elapsed: Records.emit(None, 'session.progress'))
        self.assertEqual((output.returncode, output.stop_reason), (0, None))

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

    LEDGER_CHECKS = ({'id': 'a', 'run': 'test -f a'}, {'id': 'b', 'run': 'test -f b', 'describe': 'b exists'})

    def test_both_adapters_keep_the_best_candidate_through_a_regression(self):
        self.set_mode('ledger')
        for backend in ('codex', 'claude'):
            with self.subTest(backend=backend):
                outcome = self.launch(backend, checks=self.LEDGER_CHECKS, max_sessions=2, stall_sessions=1)
                self.assertEqual((outcome.stop_reason, outcome.exit_code), ('session_limit', 2))
                ledger = json.loads((self.run_dir / 'ledger.json').read_text())
                self.assertEqual([h['passed'] for h in ledger['history']], [[], ['a'], ['b']])
                self.assertEqual(ledger['history'][-1]['regressed'], ['a'])
                self.assertEqual(outcome.ledger['best_passed'], ['a'])
                self.assertEqual(outcome.ledger['latest'], {'a': 'failed', 'b': 'passed'})
                self.assertEqual(outcome.best_candidate_sha, ledger['history'][1]['candidate_sha'])
                self.assertNotEqual(outcome.best_candidate_sha, outcome.latest_candidate_sha)
                self.assertIn('diff --git a/a b/a', Path(outcome.artifacts['best_patch']).read_text())
                self.assertNotIn('diff --git a/a b/a', Path(outcome.artifacts['patch']).read_text())
                imported = self.root / f'best-{backend}'
                subprocess.run(['git', 'clone', '-q', '-b', 'agentmill-best', outcome.artifacts['bundle'],
                                str(imported)], check=True)
                self.assertTrue((imported / 'a').is_file())
                self.assertEqual([c['check_id'] for c in outcome.checks], ['a', 'b'] * 3)

                outcome = self.launch(backend, checks=self.LEDGER_CHECKS, max_sessions=3)
                self.assertEqual(outcome.status, 'checked_complete')
                self.assertEqual(outcome.best_candidate_sha, outcome.latest_candidate_sha)
                self.assertEqual(outcome.ledger['first_passed_session'], {'a': 1, 'b': 2})
                self.assertNotIn('best_patch', outcome.artifacts)

    def test_stalled_sessions_stop_before_the_session_limit(self):
        self.set_mode('ledger')
        outcome = self.launch(checks=self.LEDGER_CHECKS, max_sessions=3, stall_sessions=1)
        self.assertEqual((outcome.stop_reason, outcome.exit_code, outcome.sessions), ('stalled', 2, 2))
        self.assertEqual(outcome.ledger['best_passed'], ['a'])
        self.assertTrue(Path(outcome.artifacts['best_patch']).is_file())
        self.set_mode('continue_unchanged')
        outcome = self.launch(checks=('false',), max_sessions=4, stall_sessions=2)
        self.assertEqual((outcome.stop_reason, outcome.exit_code, outcome.sessions), ('stalled', 2, 2))
        self.assertIn('no new check passed and no measured number rose in 2 consecutive sessions', outcome.errors)

    def test_a_rising_measured_number_is_progress_for_the_stall_rule(self):
        self.set_mode('continue_unchanged')
        counter = self.root / 'counter'
        # Fails every time, but reports one more than the time before.
        rising = (f'n=$(cat "{counter}" 2>/dev/null || echo 0); echo $((n + 1)) > "{counter}"; '
                  'echo "speedup: $n.5x"; false')
        outcome = self.launch(checks=({'id': 'speed', 'run': rising, 'progress': r'speedup: ([\d.]+)x'},),
                              max_sessions=4, stall_sessions=2)
        self.assertEqual((outcome.stop_reason, outcome.sessions), ('session_limit', 4))
        self.assertEqual(outcome.ledger['values'], {'speed': 4.5})
        self.assertEqual(outcome.ledger['best_values'], {'speed': 4.5})
        self.assertEqual(outcome.best_candidate_sha, outcome.latest_candidate_sha)
        self.assertIn('(measured 3.5, best so far 3.5)', (self.run_dir / 'sessions/0004/prompt.txt').read_text())
        outcome = self.launch(checks=({'id': 'speed', 'run': 'echo "speedup: 7x"; false',
                                       'progress': r'speedup: ([\d.]+)x'},), max_sessions=4, stall_sessions=2)
        self.assertEqual((outcome.stop_reason, outcome.sessions), ('stalled', 2))

    def test_best_candidate_keeps_the_higher_measured_number_on_a_tie(self):
        checks = (Check('unit', 'true'), Check('speed', 'bench', None, r'speedup: ([\d.]+)x'))
        ledger = Ledger(checks, self.root / 'ledger.json')

        def record(session, speedup):
            output = self.root / f'speed-{session}.log'
            output.write_text(f'warmup speedup: 1x\nspeedup: {speedup}x\n')
            return ledger.record(session, f'candidate-{session}', [
                {'status': 'passed', 'stdout': str(self.root / 'absent.log')},
                {'status': 'failed', 'stdout': str(output)}])

        self.assertEqual([record(n, value) for n, value in enumerate((10, 1500, 3100, 3000, 3050, 3200))],
                         [True, True, True, False, False, True])
        self.assertEqual((ledger.best, ledger.best_values), ('candidate-5', {'speed': 3200.0}))
        self.assertFalse(record(6, 2900))
        self.assertEqual((ledger.best, ledger.values), ('candidate-5', {'speed': 2900.0}))
        self.assertIn('- [failed] speed: bench (measured 2900, best so far 3200)', ledger.render())
        self.assertEqual(json.loads((self.root / 'ledger.json').read_text())['history'][-1]['values'],
                         {'speed': 2900.0})
        # Output without the number is not a rise, and does not displace a measured best on a tie.
        self.assertFalse(ledger.record(7, 'candidate-7', [
            {'status': 'passed', 'stdout': str(self.root / 'absent.log')},
            {'status': 'failed', 'stdout': str(self.root / 'absent.log')}]))
        self.assertEqual((ledger.best, ledger.best_values), ('candidate-5', {'speed': 3200.0}))

    def test_check_progress_must_be_a_pattern_with_one_group(self):
        for pattern in ('speedup', r'(\d+) of (\d+)', '(', 7):
            with self.subTest(pattern=pattern), self.assertRaisesRegex(ValueError, 'exactly one group'):
                replace(self.spec, checks=({'run': 'true', 'progress': pattern},))
        spec = replace(self.spec, checks=({'run': 'true', 'progress': r'(\d+) passed'},))
        self.assertEqual(spec.to_dict()['checks'][0]['progress'], r'(\d+) passed')

    def test_both_adapters_reject_an_unchanged_done_claim_when_the_baseline_passes(self):
        self.set_mode('done_unchanged')
        for backend in ('codex', 'claude'):
            with self.subTest(backend=backend):
                outcome = self.launch(backend, checks=('true',))
                self.assertEqual((outcome.stop_reason, outcome.exit_code, outcome.sessions),
                                 ('unchanged_candidate', 2, 2))
                self.assertEqual(outcome.latest_candidate_sha, outcome.base_revision)
                self.assertIn('every check already passes at the base revision', ' '.join(outcome.errors))
                self.assertIn('identical to the base revision',
                              (self.run_dir / 'sessions/0002/prompt.txt').read_text())

    def test_verify_checks_one_revision_without_an_agent(self):
        from agentmill import verify
        checks = ({'id': 'value', 'run': 'test "$(cat value)" = fixed'}, {'id': 'mode', 'run': 'test -f mode'})
        spec = replace(self.spec, checks=checks)
        events = []
        outcome = verify(spec, events.append, runs_dir=self.root / 'runs')
        run_dir = Path(outcome.artifacts['run_directory'])
        self.assertEqual((outcome.status, outcome.stop_reason, outcome.exit_code, outcome.mode),
                         ('incomplete', 'checks_failed', 2, 'verify'))
        self.assertEqual(outcome.ledger['latest'], {'value': 'failed', 'mode': 'passed'})
        self.assertEqual((outcome.sessions, outcome.base_revision), (0, self.base))
        self.assertFalse((run_dir / 'sessions').exists())
        self.assertEqual([e['event'] for e in events][0], 'verify.started')
        self.assertEqual(json.loads((run_dir / 'outcome.json').read_text()), outcome.to_dict())

        (self.repo / 'value').write_text('fixed\n')
        self.git('commit', '-qam', 'fix value')
        outcome = verify(spec, runs_dir=self.root / 'runs')
        self.assertEqual((outcome.status, outcome.stop_reason, outcome.exit_code),
                         ('checked_complete', 'checks_passed', 0))
        self.assertEqual(outcome.last_passing_candidate_sha, self.git('rev-parse', 'HEAD'))
        outcome = verify(replace(spec, revision=self.base), runs_dir=self.root / 'runs')
        self.assertEqual(outcome.exit_code, 2)

    def test_verify_command_uses_only_check_fields_from_a_job_file(self):
        import contextlib
        import io
        from agentmill.cli import main
        (self.repo / 'value').write_text('fixed\n')
        self.git('commit', '-qam', 'fix value')
        job = self.root / 'job.toml'
        job.write_text('task = "not used"\nagent = "claude"\nmax_sessions = 9\ncheck_timeout = "1m"\n'
                       '[[checks]]\nid = "value"\nrun = \'test "$(cat value)" = fixed\'\n')
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = main(['verify', str(self.repo), '--spec', str(job), '--runs-dir', str(self.root / 'runs'),
                         '--json'])
        self.assertEqual(code, 0)
        events = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual(events[0]['checks'], ['value'])
        self.assertEqual(events[-1]['stop_reason'], 'checks_passed')
        spec = json.loads((Path(events[-1]['outcome']).parent / 'spec.json').read_text())
        self.assertEqual((spec['agent'], spec['max_sessions'], spec['check_timeout']), ('codex', 3, 60))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = main(['verify', str(self.repo), '--check', 'true', '--check', 'false',
                         '--runs-dir', str(self.root / 'runs')])
        self.assertEqual(code, 2)
        text = stderr.getvalue()
        self.assertIn('Result: incomplete (checks_failed)', text)
        self.assertIn('Checks: 1/2 pass (not passing: check-2)', text)
        self.assertNotIn('patch', text.lower())


if __name__ == '__main__':
    unittest.main()
