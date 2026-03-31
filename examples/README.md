# Example TASK.md Templates

AgentMill agents read a `TASK.md` file from the root of your target repository
to know what to work on. These examples show the format for common task types.

## Usage

1. Copy the template closest to your task into your repo as `TASK.md`:
   ```bash
   cp examples/tasks/bugfix.md /path/to/your-repo/TASK.md
   ```
2. Edit the mission, definition of done, and verifier commands to match your
   actual codebase.
3. Run AgentMill:
   ```bash
   REPO_PATH=/path/to/your-repo docker compose up headless
   ```

A blank starter template is also available at `prompts/TASK.md.example`.

## Templates

| File | Use when you need to... |
|------|------------------------|
| `tasks/bugfix.md` | Fix a specific bug with a known reproduction path |
| `tasks/feature.md` | Add a new user-facing feature or endpoint |
| `tasks/refactor.md` | Restructure code without changing behavior |
| `tasks/tests.md` | Improve test coverage for an existing module |

## Tips

- **Keep the mission to 1-2 sentences.** The agent works best with a focused goal.
- **Make verifier commands fast.** A "fast check" under 10 seconds lets the agent
  iterate quickly; the "full check" runs once before the final commit.
- **Be specific about constraints.** If the agent should not touch the database
  schema or add dependencies, say so in the Context section.
