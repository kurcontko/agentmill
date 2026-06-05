# AgentMill Hooks

Hooks are executable scripts in `hooks/`, mounted read-only at `/hooks`.
Supported hook names are:

- `pre_iteration.sh`
- `post_iteration.sh`
- `on_complete.sh`
- `on_failure.sh`

Hooks may be global, profile-scoped, or role-scoped:

- `hooks/<name>.sh`
- `hooks/profiles/<profile>/<name>.sh`
- `hooks/roles/<role>/<name>.sh`

Matching hooks run in that order. Any timeout, non-zero exit, malformed JSON,
`deny`, or `defer` fails closed for the current side effect.

Each hook receives JSON on stdin. Empty stdout means allow. JSON stdout may use:

```json
{
  "decision": "allow",
  "reason": "checked",
  "additional_context": "Short context to prepend to the next prompt.",
  "prompt_file": "/prompts/PROMPT_RESEARCH_DEPTH.md"
}
```

`decision` is `allow`, `deny`, or `defer`. `additional_context` is bounded by
`AGENTMILL_HOOK_CONTEXT_MAX_BYTES`. `prompt_file` is accepted only from
`pre_iteration`, must be under the prompt root, and must exist before Claude is
invoked.

Relevant settings:

- `AGENTMILL_HOOK_DIR=/hooks`
- `AGENTMILL_HOOK_TIMEOUT_SECONDS=30`
- `AGENTMILL_HOOK_CONTEXT_MAX_BYTES=16384`
