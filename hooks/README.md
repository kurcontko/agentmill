# AgentMill Hooks

Place executable hook scripts here to add harness-owned policy checks. This
directory is mounted into containers as `/hooks:ro`.

Supported hook names:

- `pre_iteration.sh`
- `post_iteration.sh`
- `on_complete.sh`
- `on_failure.sh`

Hook placement controls scope:

- `hooks/<name>.sh` runs for every role.
- `hooks/profiles/<profile>/<name>.sh` runs only for the active
  `AGENTMILL_PROFILE_LEVEL`, such as `standard`.
- `hooks/roles/<role>/<name>.sh` runs only for the active `AGENTMILL_ROLE`,
  such as `researcher-depth`.

When more than one hook matches, AgentMill runs global, profile, then role
hooks. The first deny/defer/failure stops the action. Allowed
`additional_context` values are joined and injected into the next prompt once.

Each hook receives a JSON object on stdin and may write a JSON decision on
stdout:

```json
{"decision":"allow","reason":"ok","additional_context":"Optional text for the next prompt"}
```

Valid decisions are `allow`, `deny`, and `defer`. Empty stdout means `allow`.
Non-zero exit, malformed JSON, timeout, `deny`, or `defer` fail closed for
side-effectful actions. `additional_context` is honored for allowed
`pre_iteration` hooks and prepended to the next prompt in a marked harness
section, capped by `AGENTMILL_HOOK_CONTEXT_MAX_BYTES`.
