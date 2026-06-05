# Principal Readiness Assessment

Assessment date: 2026-05-31.

Scope: current working tree across CLI, entrypoints, client adapters, runtime
policy, Docker/Compose, CI, docs, prompts, profiles, and tests. The repository
is already well past prototype quality: it has a broad local test suite,
profile-aware policy gates, structured events, budgets, clone-mode isolation,
multiple client adapters, and serious threat-modeling docs. The remaining gap
to principal-level code is less about adding features and more about making the
system easier to reason about, release, audit, and operate under change.

## Evidence Checked

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'`
  passed: 5 Python tests.
- Shell test loop over `tests/test_*.sh`, excluding
  `tests/test_smoke_integration.sh`, passed: 62 shell tests.
- Workflow and Dependabot YAML parsed successfully with Python `yaml`.
- `bash -n` passed for `mill`, `entrypoint-common.sh`, `entrypoint.sh`,
  `entrypoint-tui.sh`, `setup-claude-config.sh`, and `setup-repo-env.sh`.
- `python3 -m py_compile` passed for `scripts/*.py`, `agentmill/*.py`, and
  Python tests.

## Principal Bar

For this repo, "principal level" should mean:

- The harness has clear ownership boundaries and small enough modules that a
  risky behavior can be inspected without reading thousands of shell lines.
- Security policy has one source of truth and is projected consistently into
  Claude, Codex, OpenCode, Qwen, Gemini, ACP, hooks, shell gates, Docker, and
  docs.
- Release artifacts are reproducible, pinned, gated by a green proof path, and
  tied to an auditable tag SHA.
- Tests prove the behavior that matters, including negative/security paths and
  container/runtime behavior, not just happy-path string output.
- Docs match reality and distinguish implemented behavior from plans.
- Operational commands give clear diagnostics and fail closed when enforcement
  cannot be proven.

## What Is Already Strong

- Broad local tests exist for policies, hooks, client adapters, profile
  rendering, event parsing, budgets, memory, egress proxy, clone artifacts,
  JSON CLI output, doctor checks, and shell argument validation.
- `agents/*.toml` gives roles concrete budgets, prompts, branch policy,
  network policy, trust level, and completion gates.
- `mill doctor` validates many real risk surfaces: auth, Docker, profiles,
  MCP snapshots, network policy, workspace isolation, budgets, hooks, and
  host config forwarding.
- Standard/untrusted profiles are no longer just prompt guidance. They have
  workspace isolation, high-risk file gates, MCP allowlists, shell/tool policy,
  read-only clone mode, write-root mediation, and budget checks.
- `logs/events.jsonl`, `results.tsv`, `convergence.tsv`, status files, metrics,
  and web/status views give the harness an observable runtime spine.
- The docs include serious threat modeling and design lineage:
  `docs/SECURITY.md`, `docs/HARNESS_SECURITY.md`,
  `docs/GENERIC_CLIENT_ENGINE_PLAN.md`, `docs/CODEX_INTEGRATION_PLAN.md`, and
  `docs/AGENTS.md`.

## Priority 0: Release and Supply Chain Must Fail Closed

### Gap: unpinned client CLI installs

Current evidence: `Dockerfile` pins Claude and OpenCode, but leaves
`CODEX_CLI_VERSION`, `QWEN_CODE_VERSION`, and `GEMINI_CLI_VERSION` as `latest`.

Why it blocks principal level: this makes the image non-reproducible and lets
adapter behavior change without a code review. It also invalidates fixture
tests whenever upstream CLIs change JSON formats, permission flags, auth paths,
or sandbox semantics.

Path to principal:

- Pin every installed client CLI version.
- Add `mill version --json` fields for each client pin.
- Add `mill doctor` minimum-version checks for every enabled adapter.
- Record CLI bumps in `CHANGELOG.md` with the adapter behavior verified.

Done evidence:

- Docker build uses fixed versions for Claude, Codex, OpenCode, Qwen, and
  Gemini.
- A test fails when a client pin is missing or set to `latest`.
- Release notes name the exact client versions in the image.

### Gap: publish workflow can publish from the wrong commit

Current evidence: `publish-image.yml` accepts a manual `version` input, but it
does not resolve and checkout `refs/tags/v${version}` before building.

Why it blocks principal level: an operator can publish a semver image from an
arbitrary branch state. That breaks provenance and makes rollback/audit
ambiguous.

Path to principal:

- For manual dispatch, fetch and checkout the exact tag SHA.
- Fail if the tag is missing or does not point at the checked-out commit.
- Gate publish through a protected GitHub environment or protected tag policy.
- Either run required validation inside publish or publish only from a
  successful CI `workflow_run` for the same SHA.

Done evidence:

- Manual release from a branch cannot publish unless the matching tag exists.
- Image digest, provenance attestation, and source tag resolve to one commit.
- A release run cannot move `latest` unless an explicit promotion policy allows
  it.

### Gap: vulnerability scans are partly advisory

Current evidence: the Trivy workflow writes SARIF but does not enforce an
`exit-code: "1"` policy for HIGH/CRITICAL findings.

Why it blocks principal level: security tooling that reports but cannot block
creates false confidence. Principal-level CI must state which scanners are
blocking and enforce those gates mechanically.

Path to principal:

- Add an enforcing Trivy path for the chosen severity threshold.
- Keep SARIF upload with `if: always()` so failed scans still publish results.
- Document which findings are blocking, advisory, or temporarily accepted.

Done evidence:

- CI fails on a synthetic HIGH/CRITICAL finding or a known vulnerable fixture.
- `docs/CI.md` names blocking versus advisory scanners.

## Priority 1: Reduce Architectural Risk From Large Shell Modules

### Gap: core behavior is concentrated in very large shell files

Current evidence:

- `entrypoint-common.sh`: 5041 lines.
- `mill`: 3352 lines.
- `docker-compose.yml`: 439 lines.

Why it blocks principal level: the code is test-heavy, but the main modules are
large enough that unrelated concerns share state, globals, traps, and helper
names. That raises the cost of review and makes subtle policy regressions more
likely.

Path to principal:

- Use `docs/MONOLITH_SPLIT_PLAN.md` as the detailed migration plan.
- Split `entrypoint-common.sh` into sourced modules by responsibility:
  events/logging, hooks, runtime policy, git policy, client adapters, memory,
  completion gates, and settings generation.
- Split `mill` into small command modules or a minimal dispatcher plus
  command-specific scripts.
- Keep shell where it is valuable, but move schema-heavy transformations into
  Python stdlib helpers with fixture tests.

Done evidence:

- No single runtime source file exceeds roughly 1000-1500 lines unless it is
  generated.
- Each policy module has direct tests and can be sourced independently.
- CLI command parsing and container runtime policy do not share large mutable
  global blocks.

### Gap: policy constants are duplicated across projections

Current evidence: high-risk shell/path/network policy appears in multiple
places: `scripts/pretool-policy.py`, `entrypoint-common.sh`
`client_policy_ir_json`, Claude settings generation, shell session audit, and
doctor checks.

Why it blocks principal level: duplication is acceptable while bootstrapping,
but principal-level security policy needs one canonical data model. Otherwise a
new deny rule can be enforced for Claude but missed for Codex, or documented in
doctor but absent from PreToolUse.

Path to principal:

- Create a canonical policy manifest, for example `policy/defaults.json` or
  `policy/defaults.toml`.
- Generate client projections from that manifest.
- Make tests compare Claude, Codex, OpenCode, Qwen, Gemini, pretool, session
  audit, and doctor projections for semantic equivalence.

Done evidence:

- Adding a deny rule in one manifest updates all client projections.
- A test fails if a rule exists in one projection but not the others.

### Gap: configuration schema is not generated from one source

Current evidence: environment keys are repeated in `.env.example`,
`docker-compose.yml`, `mill doctor`, profile rendering, README tables, and
tests.

Why it blocks principal level: this repo has dozens of env vars and per-agent
variants. Manual duplication will drift as the client matrix grows.

Path to principal:

- Define an env schema with name, type, default, description, profile behavior,
  and whether per-agent suffixes are supported.
- Generate `.env.example`, README config tables, doctor known-key lists, and
  Compose env blocks from that schema.
- Add a schema drift test.

Done evidence:

- One new env var can be added in one schema file and generated everywhere.
- CI fails when docs, Compose, doctor, or profile rendering omit a schema key.

## Priority 2: Prove Runtime Isolation End To End

### Gap: most isolation tests stub Docker/client behavior

Current evidence: the lightweight suite is strong and fast, but it mostly
stubs Docker and client CLIs. `tests/test_smoke_integration.sh` is excluded
from the normal shell loop.

Why it blocks principal level: policy projection can pass unit tests while the
real container runtime, tmpfs mounts, read-only rootfs, bwrap behavior, client
binary flags, and network modes drift.

Path to principal:

- Keep fast tests as the PR default.
- Add an explicit integration lane for real Docker build plus one fake-client
  headless run in direct mode and read-only clone mode.
- Add a network-deny/allowlist container smoke test with a local HTTP endpoint
  and a blocked public/non-public target.
- Add one live-client canary only if credentials are intentionally configured;
  otherwise keep it skipped with a clear reason.

Done evidence:

- `docs/CI.md` defines fast, integration, and optional live-provider lanes.
- The integration lane proves rootfs/read-only/tmpfs/network/write-root behavior
  inside the built image.

### Gap: direct trusted mode remains the default in `.env.example`

Current evidence: `.env.example` sets `AGENTMILL_PROFILE_LEVEL=trusted` and
`AGENTMILL_WORKSPACE_MODE=auto`. Profiles such as `coder` default to
`standard`, but raw Compose/mill users can start from broad trusted authority.

Why it blocks principal level: the repo has excellent standard/untrusted
controls, but the first-run default still optimizes compatibility over least
privilege.

Path to principal:

- Decide whether the product default should move to `standard`.
- If compatibility requires trusted by default, make the first-run docs call
  out that `trusted` is for fully trusted repos only and show the standard
  profile command first.
- Make `mill init` default to bounded standard profile values unless explicitly
  asked for trusted.

Done evidence:

- Quick Start demonstrates a bounded standard run.
- `mill doctor` warns loudly when trusted direct mode is unbounded.

## Priority 3: Tighten Completion, Review, and Regression Evidence

### Gap: completion evidence is still optional for some write-capable roles

Current evidence: `coder` and `refactor` use typed verifier gates, while
`reviewer` and `memory-curator` still use `done_file`. That is reasonable for
some roles, but the policy is not written as an explicit evidence matrix.

Why it matters: principal-level autonomous systems need a clear answer to
"what proves this role is done?" and "which roles may write without a verifier?"

Path to principal:

- Add a role evidence matrix to `docs/PROFILES.md` or `docs/AGENTS.md`.
- State which roles may auto-commit and what artifact proves completion.
- Add doctor warnings for auto-commit write roles that use only `done_file`.

Done evidence:

- Every built-in role has documented completion evidence.
- Doctor flags unsafe role/profile combinations.

### Gap: no mutation or adversarial regression tests for policy bypasses

Current evidence: there are many negative tests, but no mutation-style harness
that proves common bypass attempts fail across all adapters.

Why it matters: this repo is a security-sensitive harness. Principal-level
confidence should include bypass attempts such as shell wrappers, path
traversal, symlink writes, changed MCP manifests, encoded secrets, unexpected
project config, and client-native subagent/autonomy modes.

Path to principal:

- Add a `tests/security_cases/` fixture set with expected allow/deny outcomes.
- Run each case through the canonical policy engine and every client projection
  that can represent it.
- Add symlink/path traversal/write-root tests for real repo layouts.

Done evidence:

- A table-driven test proves deny behavior across policy engine, pretool hook,
  session audit, and client config projections.

## Priority 4: Make Docs Match Implementation State

### Gap: task/docs contain stale or over-claimed items

Current evidence:

- `TASK.md` says published image digests use "Cosign / sigstore signing", while
  the current publish workflow uses GitHub provenance attestation.
- `CHANGELOG.md` says "sigstore keyless signing", which is not the same as a
  cosign signature in the current workflow.
- Planning docs still describe some now-implemented areas as future work.

Why it blocks principal level: users and reviewers need to know which controls
exist, which are plans, and which are intentionally omitted.

Path to principal:

- Split docs into `implemented`, `design target`, and `backlog` sections.
- Update release/signing wording to match actual attestation behavior.
- Add a docs drift check for completed TASK items that reference removed or
  changed mechanisms.

Done evidence:

- A reviewer can read `README.md`, `docs/CI.md`, `docs/SECURITY.md`, and
  `TASK.md` without finding contradictory claims about release, signing,
  sandboxing, or client support.

## Priority 5: Package and Operator Experience

### Gap: AgentMill is still mostly a repo-local shell product

Current evidence: `agentmill/__init__.py` is a thin subprocess wrapper around
  the local `mill` script. There is no packaging metadata, installer contract,
  command completion, or stable versioning beyond `mill version`.

Why it matters: this may be fine for a hackable harness, but principal-level
distribution needs a defined installation and upgrade story.

Path to principal:

- Decide whether AgentMill remains repo-local or becomes installable.
- If installable, add packaging metadata and a stable `agentmill` console
  script that finds its asset directory reliably.
- If repo-local by design, document that explicitly and keep the Python wrapper
  as automation glue only.

Done evidence:

- Operators have one supported install/update path and one supported local dev
  path.

### Gap: incident response is described more than executable

Current evidence: events, metrics, logs, status, and doctor exist, but there is
no single `mill incident`/`mill audit` command that bundles evidence after a
bad run.

Why it matters: a harness that can edit and push code should make forensic
review easy after policy denial, suspected prompt injection, cost exhaustion,
or accidental publish.

Path to principal:

- Add `mill audit <run-id>` to summarize events, policy denials, changed files,
  commits, usage, MCP manifest, client version, and patch artifacts.
- Add `mill quarantine <run-id>` or documented manual steps to stop services,
  preserve logs, and prevent further pushes.

Done evidence:

- One command produces a redacted run bundle suitable for review.

## Suggested Implementation Order

1. Pin every client CLI and add version/schema drift tests.
2. Fix release provenance: verified tag checkout, green-SHA gate, explicit
   `latest` policy, and accurate signing/attestation docs.
3. Create the canonical env schema and generate `.env.example`, README config,
   Compose env, doctor known keys, and profile docs.
4. Create the canonical policy manifest and projection-equivalence tests.
5. Split `entrypoint-common.sh` and `mill` along ownership boundaries.
6. Add Docker/runtime integration lane for rootfs, tmpfs, bwrap, network, and
   clone-mode behavior.
7. Add role completion evidence matrix and doctor warnings for weak evidence.
8. Add adversarial policy-bypass fixtures.
9. Reconcile docs so implemented controls, plans, and backlog do not mix.
10. Add `mill audit` for incident review.

## Non-Goals

- Do not copy large-project CI orchestration unless the repo actually grows to
  that scale.
- Do not replace all shell with Python just for style. Shell remains a good fit
  for process orchestration; the target is smaller modules and canonical
  schemas, not a rewrite.
- Do not make live provider tests required for every PR. Keep live tests
  opt-in and credential-gated.
