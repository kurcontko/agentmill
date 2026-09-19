"""Private checkouts and supervisor-owned Git snapshots.

Never invoke host Git against worker-controlled Git metadata or hooks.
"""

from fnmatch import fnmatchcase
import os
from pathlib import Path

from .contracts import RunStopped


CAPTURE_EXCLUDES = """.env
.env.*
!.env.example
!.env.sample
*.pem
*.key
*.p12
*.pfx
credentials.json
credentials.yaml
.ssh/
.aws/
.codex/
"""


def capture_allowed(path):
    """Apply the fixed exclusion policy even when .gitignore negates it."""
    parts = Path(os.fsdecode(path)).parts
    if any(part in (".ssh", ".aws", ".codex") for part in parts[:-1]):
        return False
    if parts[-1] in (".env.example", ".env.sample"):
        return True
    patterns = [p for p in CAPTURE_EXCLUDES.splitlines() if not p.startswith("!")]
    return not any(fnmatchcase(part, pattern.rstrip("/")) for part in parts for pattern in patterns)


class Workspace:
    def __init__(self, executor, directory):
        self.executor = executor
        self.directory = Path(directory)
        self.store = self.directory / "snapshots.git"
        self.path = self.directory / "workspace"
        self.excludes = self.directory / "capture-excludes"
        self.excludes.write_text(CAPTURE_EXCLUDES)
        self.base = None
        self.latest = None
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_TERMINAL_PROMPT="0", GIT_ATTR_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="AgentMill", GIT_AUTHOR_EMAIL="agentmill@localhost",
                        GIT_COMMITTER_NAME="AgentMill", GIT_COMMITTER_EMAIL="agentmill@localhost")

    def git(self, *args, maintenance=False, worktree=None, index=None, repo=True):
        argv = ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                "-c", "core.attributesFile=/dev/null", "-c", "core.autocrlf=false",
                "-c", "core.excludesFile=" + str(self.excludes), "-c", "protocol.ext.allow=never"]
        if repo:
            argv += ["--git-dir", str(self.store)]
        if worktree:
            argv += ["--work-tree", str(worktree)]
        env = dict(self.env)
        if index:
            env["GIT_INDEX_FILE"] = str(index)
        return self.executor.control([*argv, *map(str, args)], timeout=None, env=env, maintenance=maintenance)

    def prepare(self, source, revision):
        local = Path(source).expanduser()
        if local.exists():
            source = str(local.resolve())
            if local.is_dir() and (not (local / ".git").is_dir() or (local / ".git").is_symlink()):
                raise ValueError("source must be a regular checkout; linked worktrees are not supported")
            if local.is_dir() and self.directory.is_relative_to(local.resolve()):
                raise ValueError("run directory must be outside the source checkout")
        self.git("clone", "--bare", "--no-local", "--", source, self.store, repo=False)
        self.base = self.git("rev-parse", "--verify", "--end-of-options", revision + "^{commit}").decode().strip()
        self.latest = self.base
        # Override repository attributes for byte-for-byte capture and checkout.
        (self.store / "info/attributes").write_text("* -filter -ident -text\n")
        self.reject_gitlinks(self.base)
        self.git("update-ref", "refs/heads/agentmill-base", self.base)
        self.checkout(self.base, self.path)
        return self.base

    def reject_gitlinks(self, revision, maintenance=False):
        entries = self.git("ls-tree", "-rz", revision, maintenance=maintenance).split(b"\0")
        if any(entry.startswith(b"160000 ") for entry in entries):
            raise RunStopped("unsupported_submodule_or_nested_repository")

    def checkout(self, revision, destination):
        # Copy the trusted store's object files without repacking. Never share
        # writable objects with worker/check code via hardlinks or alternates.
        self.git("clone", "--local", "--no-hardlinks", "--no-checkout", "--", self.store, destination, repo=False)
        (destination / ".git/info/attributes").write_text("* -filter -ident -text\n")
        self.git("-C", destination, "checkout", "--detach", revision, repo=False)
        self.git("-C", destination, "remote", "remove", "origin", repo=False)

    def capture(self, session, *, maintenance=False):
        if not self.executor.worker_stopped:
            raise RunStopped("capture_unsafe_worker_running")
        index = self.directory / "capture.index"
        self.git("read-tree", self.latest, index=index, maintenance=maintenance)
        self.git("add", "--update", "--", ".", worktree=self.path, index=index, maintenance=maintenance)
        untracked = self.git("ls-files", "--others", "--exclude-standard", "-z",
                             worktree=self.path, index=index, maintenance=maintenance)
        eligible = b"".join(path + b"\0" for path in untracked.split(b"\0") if path and capture_allowed(path))
        if eligible:
            paths = self.directory / "capture.paths"
            paths.write_bytes(eligible)
            self.git("--literal-pathspecs", "add", "--force", "--pathspec-from-file", paths,
                     "--pathspec-file-nul", worktree=self.path, index=index, maintenance=maintenance)
        tree = self.git("write-tree", index=index, maintenance=maintenance).decode().strip()
        self.reject_gitlinks(tree, maintenance=maintenance)
        previous = self.git("rev-parse", self.latest + "^{tree}", maintenance=maintenance).decode().strip()
        candidate = self.latest
        if tree != previous:
            candidate = self.git("commit-tree", tree, "-p", self.latest, "-m",
                                 f"AgentMill candidate after session {session}",
                                 maintenance=maintenance).decode().strip()
        self.git("update-ref", "refs/heads/agentmill-candidate", candidate, maintenance=maintenance)
        self.latest = candidate
        return self.latest

    def unchanged(self, revision, path):
        index = self.directory / "check.index"
        self.git("read-tree", revision, index=index)
        changes = self.git("diff", "--name-only", "--no-ext-diff", "--no-textconv", revision, "--",
                           worktree=path, index=index)
        return not changes.strip()

    def export(self, passing):
        artifacts = self.directory / "artifacts"
        artifacts.mkdir(exist_ok=True)
        patch = artifacts / "result.patch"
        patch.write_bytes(self.git("diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv",
                                   self.base, self.latest, "--", maintenance=True))
        self.git("update-ref", "refs/heads/agentmill-candidate", self.latest, maintenance=True)
        self.git("symbolic-ref", "HEAD", "refs/heads/agentmill-candidate", maintenance=True)
        refs = ["HEAD", "refs/heads/agentmill-base", "refs/heads/agentmill-candidate"]
        if passing:
            self.git("update-ref", "refs/heads/agentmill-passing", passing, maintenance=True)
            refs.append("refs/heads/agentmill-passing")
        bundle = artifacts / "result.bundle"
        self.git("bundle", "create", bundle, *refs, maintenance=True)
        return {"patch": str(patch), "bundle": str(bundle)}
