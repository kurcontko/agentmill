# PR #38 security finding triage

The Sonar analysis of `9b5421b` reported seven security findings. This records
their dispositions; complexity/style findings are separate from the security gate.

## Package installation: fixed

`docker:S6505` (`AaC0jGQrrbNKvIICHnkm`) flagged npm lifecycle scripts running as
root during image construction. The Dockerfile now installs the pinned native
CLIs with `--ignore-scripts`. Claude 2.1.119 requires its own `install.cjs` to
replace the executable placeholder with the platform binary. We inspected that
pinned script: on Linux it selects an installed optional dependency, then links
or copies its binary and sets executable permissions; it does not fetch code.
The Dockerfile runs only that installer explicitly and checks both CLI versions.
Other dependency lifecycle scripts remain disabled. Re-review this exception
when updating Claude. The packaged native protocol smoke test must pass with
that image, including actual shell tool execution and structured replies.

## Release-candidate display command: false positive

`pythonsecurity:S8705` (`AaC3POdKddlVqJjXWv-Q`) flags the `shlex.join()` call
that formats a clean bundle-review checkout instruction in `cli.human_result()`.
Its trace labels argparse input as an HTTP request and the formatting call as
command execution. Neither description applies: there is no HTTP input or
subprocess invocation in this function.

The supervisor generates run IDs, and `show` validates the requested ID before
loading its local record. Worker containers cannot write that record. Each word
of the displayed command is shell-quoted by `shlex.join`; Git's `--` separates
options from the bundle/destination paths, and the destination starts with `./`.
The CLI regression test creates a real bundle with spaces, an apostrophe, and
shell metacharacters in its path, executes the printed instruction in a temporary
directory, and verifies the imported file and absence of the injection marker.
It passes locally and is included in the CI test suite.

The narrowly scoped `displayCommand` exclusion dismisses this rule only in
`agentmill/cli.py`. Revisit it if command formatting becomes execution, quoting or
the option delimiter changes, or records acquire a new untrusted writer. No
quality-gate threshold or other security rule is disabled.

## Explicit local file inputs: false positives

`agentmill/cli.py`:

- `pythonsecurity:S8707`: `AaC0jGP1rbNKvIICHnkk` (`--spec`) and
  `AaC0jGP1rbNKvIICHnkj` (`--task-file`).
- `pythonsecurity:S2083`: `AaC0jGP1rbNKvIICHnki` (optional source `MILL.md`).

These are intentionally caller-selected files, read with the local caller's
permissions. The CLI is not a privileged service, and the native worker cannot
set its arguments. Absolute paths and paths outside the current directory are
supported inputs, not escapes from a promised file jail. No LLM output is parsed
as launch arguments. An application exposing this CLI to untrusted callers must
authorize source/task/spec inputs at that application's boundary.

## Supervisor-owned check logs: false positives

`agentmill/checks.py`, `feedback()`:

- `pythonsecurity:S2083`: `AaC0jGPnrbNKvIICHnka` (open check log).
- `pythonsecurity:S6549`: `AaC0jGPnrbNKvIICHnkb` and `AaC0jGPnrbNKvIICHnkc`
  (check log existence/size).

The only runtime caller is `runner.session_prompt()`. Its results come directly
from `check_candidate()`, which takes stdout/stderr paths from the supervisor's
`ProcessOutput`. `Container.check()` constructs the log names under the run's
baseline/session directory. These dictionaries are not read from native output,
repository files, a client request, or a retained `checks.json`. Worker/check
containers cannot write the host records directory. Log content is untrusted
feedback, but log paths are supervisor-owned.

`sonar-project.properties` therefore dismisses these file-input/log-path rules
in these two exact files, plus the display-only command rule explained above.
It does not exclude the files from analysis or lower the gate. Revisit these dispositions if a server
accepts untrusted launch arguments or feedback starts loading external records.
