"""Byte-exact candidates, source isolation, and host Git metadata boundaries."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from agentmill import RunSpec, run
from agentmill.contracts import RunStopped
from agentmill.executor import Executor
from agentmill.workspace import Workspace


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        for args in (('init','-q'), ('config','user.name','Test'), ('config','user.email','test@example.com')):
            self.git(self.source,*args)
        (self.source / 'base.txt').write_bytes(b'original\r\n')
        self.git(self.source,'add','.')
        self.git(self.source,'commit','-qm','base')
        directory = self.root / 'run'
        directory.mkdir()
        self.spec = RunSpec(str(self.source),'task',('true',))
        self.executor = Executor(self.spec,directory)
        self.workspace = Workspace(self.executor,directory)
        self.base = self.workspace.prepare(str(self.source),'HEAD')

    def git(self, repo, *args):
        return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()

    def test_exclusions_cannot_be_overridden_by_gitignore_negation(self):
        path = self.workspace.path
        (path / '.gitignore').write_text('ignored/\n!.env\n!*.key\n')
        (path / 'ignored').mkdir()
        (path / 'ignored/build').write_text('build')
        for name in ('.env','.env.local','credentials.json','private.key'):
            (path / name).write_text('fixture-sensitive')
        (path / '.env.example').write_text('example')
        candidate = self.workspace.capture(1)
        files = self.workspace.git('ls-tree','-r','--name-only',candidate).decode().splitlines()
        self.assertEqual(set(files), {'.gitignore','.env.example','base.txt'})

    def test_snapshots_preserve_deletions_modes_symlinks_binary_and_literal_paths(self):
        path = self.workspace.path
        (path / 'base.txt').unlink()
        (path / 'run.sh').write_text('#!/bin/sh\nexit 0\n')
        (path / 'run.sh').chmod(0o755)
        (path / 'binary').write_bytes(bytes(range(256)))
        unusual = ':(glob)file\nwith-newline'
        (path / unusual).write_text('literal')
        (path / 'outside-link').symlink_to(self.root / 'outside')
        (self.root / 'outside').write_text('must never be copied')
        candidate = self.workspace.capture(1)
        checkout = self.root / 'import'
        self.workspace.checkout(candidate,checkout)
        self.assertFalse((checkout / 'base.txt').exists())
        self.assertEqual((checkout / 'binary').read_bytes(),bytes(range(256)))
        self.assertEqual((checkout / unusual).read_text(),'literal')
        self.assertEqual(os.readlink(checkout / 'outside-link'), str(self.root / 'outside'))
        self.assertTrue((checkout / 'run.sh').stat().st_mode & 0o111)
        self.assertEqual((self.source / 'base.txt').read_bytes(),b'original\r\n')

    def test_capture_ignores_worker_index_hooks_config_and_filters(self):
        path = self.workspace.path
        canary = self.root / 'host-command-executed'
        self.git(path,'config','filter.attack.clean',f'touch {canary}')
        self.git(path,'config','core.fsmonitor',f'touch {canary}')
        hook = path / '.git/hooks/pre-commit'
        hook.write_text(f'#!/bin/sh\ntouch {canary}\n')
        hook.chmod(0o755)
        (path / '.gitattributes').write_text('* filter=attack text eol=lf\n')
        (path / 'base.txt').write_bytes(b'candidate\r\n')
        (path / '.git/index').write_bytes(b'not a valid Git index')
        candidate = self.workspace.capture(1)
        self.assertFalse(canary.exists())
        content = self.workspace.git('show',candidate+':base.txt')
        self.assertEqual(content,b'candidate\r\n')

    def test_capture_cannot_run_while_worker_is_alive(self):
        self.executor.worker_stopped = False
        with self.assertRaisesRegex(RunStopped,'worker_running'):
            self.workspace.capture(1)

    def test_no_change_candidate_reuses_revision_and_exports_bundle(self):
        self.assertEqual(self.workspace.capture(1),self.base)
        artifacts = self.workspace.export(self.base)
        self.assertEqual(Path(artifacts['patch']).read_bytes(),b'')
        self.assertIn('refs/heads/agentmill-passing',subprocess.check_output(['git','bundle','list-heads',artifacts['bundle']],text=True))

    def test_exported_candidate_is_directly_usable_as_next_run_source(self):
        (self.workspace.path/'base.txt').write_text('candidate')
        candidate=self.workspace.capture(1)
        artifacts=self.workspace.export(candidate)
        directory=self.root/'next-run'
        directory.mkdir()
        next_workspace=Workspace(Executor(self.spec,directory),directory)
        self.assertEqual(next_workspace.prepare(artifacts['bundle'],'HEAD'),candidate)
        self.assertEqual((next_workspace.path/'base.txt').read_text(),'candidate')

    def test_reject_run_storage_inside_source_before_creating_any_files(self):
        with self.assertRaises(ValueError):
            run(self.spec,runs_dir=self.source / 'runs')
        self.assertFalse((self.source / 'runs').exists())

    def test_new_embedded_repository_is_rejected_and_preserved(self):
        nested = self.workspace.path / 'nested'
        nested.mkdir()
        self.git(nested,'init','-q')
        self.git(nested,'-c','user.name=Test','-c','user.email=test@example.com','commit','--allow-empty','-qm','nested')
        with self.assertRaisesRegex(RunStopped,'nested_repository'):
            self.workspace.capture(1)
        self.assertTrue(nested.exists())


if __name__=='__main__':
    unittest.main()
