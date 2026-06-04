# AgentMill Profiles

Profiles live in `agents/<role>.toml` and render to environment variables with
`scripts/profile-env.py`. Use them to keep prompts, budget limits, model
choices, branch policy, and trust settings role-specific.

See [`docs/AGENTS.md`](AGENTS.md) for the OpenClaw-inspired role-contract
patterns AgentMill uses and the larger agent patterns it intentionally avoids.

Inspect profiles:

```bash
./mill profiles
./mill profiles coder
```

Run with a profile:

```bash
./mill run /path/to/repo --agent coder --iterations 3
./mill multi /path/to/repo --roles researcher-breadth,researcher-depth
```

Supported fields include:

- `prompt_file`
- `model`
- `branch_pattern`
- `max_iterations`
- `loop_delay`
- `max_wall_seconds`
- `max_log_bytes`
- `profile_level`
- `auto_commit_mode`
- `ralph_max_iterations`
- `completion_gate`
- `verifier_command`
- `coder_open_questions_max`
- `refactor_loc_target`
- `refactor_loc_tolerance`
- `refactor_max_loc_delta`
- `research_saturation_iterations`
- `research_open_questions_max`
- `network`
- `write_roots`
- `shell_allowlist`
- `shell_denylist`
- `mcp_allowlist`
- `skill_allowlist`
- `forward_host_mcp`
- `forward_host_tools`
- `forward_host_hooks`
- `forward_host_env`
- `forward_host_extensions`

`profile_level` is `trusted`, `standard`, or `untrusted`. Standard and
untrusted profiles fail closed for host tools, hooks, env, MCP, plugins,
skills, agents, and commands unless the relevant forwarding or allowlist field
is explicit.

List fields render as comma-separated env vars. Boolean forwarding fields render
as `true` or `false`. `refactor_loc_target` and
`refactor_max_loc_delta` may be negative integers. Profiles are defaults:
non-empty values from `.env` or the shell override profile fields, and CLI
flags override both.

Typed completion gates are fail-closed. `coder_verified` requires a done
signal, a successful `verifier_command`, and unresolved open questions at or
below `coder_open_questions_max`. `refactor_verified` requires a done signal,
a successful `verifier_command`, and either `refactor_loc_target` + tolerance
or `refactor_max_loc_delta`.

## Built-In Role Evidence

| Role | Auto-commit default | Completion evidence |
| --- | --- | --- |
| `coder` | `wip` | `coder_verified`: done signal, successful verifier command, and open questions at or below the role threshold. |
| `refactor` | `wip` | `refactor_verified`: done signal, successful verifier command, and configured LOC delta bounds. |
| `reviewer` | `off` | `done_file`: review findings or explicit no-findings evidence; this role should not silently alter code. |
| `researcher-breadth` | `on` | `research_saturation`: configured zero-new-source streak and open questions at or below the role threshold. |
| `researcher-depth` | `on` | `research_saturation`: configured zero-new-source streak and open questions at or below the role threshold. |
| `researcher-redteam` | `on` | `research_saturation`: configured zero-new-source streak and open questions at or below the role threshold. |
| `memory-curator` | `wip` | `done_file`: durable memory cleanup or handoff artifact. Keep changes limited to memory and docs unless the task says otherwise. |

Write-capable profiles that use `done_file` are intentionally narrow. Prefer
`coder_verified` or `refactor_verified` for roles that change executable code.
