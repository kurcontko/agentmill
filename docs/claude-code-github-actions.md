# Claude Code PR Review in GitHub Actions

This repository includes `.github/workflows/claude-code-review.yml`, an optional PR review workflow that runs Claude Code through DeepSeek's Anthropic-compatible API when `ANTHROPIC_AUTH_TOKEN` is configured.

## Enable DeepSeek-backed reviews

1. Install the Claude GitHub App for this repository: https://github.com/apps/claude
2. Add an Actions secret named `ANTHROPIC_AUTH_TOKEN` with a key from the DeepSeek Platform.
3. Open, update, reopen, or mark a same-repository PR ready for review.

If `ANTHROPIC_AUTH_TOKEN` is absent, the job exits successfully without running Claude Code. It also skips fork PRs so repository secrets are not exposed to untrusted branches.

The workflow uses:

```yaml
ANTHROPIC_BASE_URL: https://api.deepseek.com/anthropic
ANTHROPIC_AUTH_TOKEN: ${{ secrets.ANTHROPIC_AUTH_TOKEN }}
ANTHROPIC_MODEL: "deepseek-v4-pro[1m]"
ANTHROPIC_DEFAULT_OPUS_MODEL: "deepseek-v4-pro[1m]"
ANTHROPIC_DEFAULT_SONNET_MODEL: "deepseek-v4-pro[1m]"
ANTHROPIC_DEFAULT_HAIKU_MODEL: deepseek-v4-flash
CLAUDE_CODE_SUBAGENT_MODEL: deepseek-v4-flash
CLAUDE_CODE_EFFORT_LEVEL: max
--model "deepseek-v4-pro[1m]"
```

The workflow also passes the same secret through the Claude Code action's `anthropic_api_key` input. That is needed because the action validates `ANTHROPIC_API_KEY` before launching Claude Code, while the Claude runtime still receives the DeepSeek-style `ANTHROPIC_AUTH_TOKEN` environment configuration.

The workflow passes the scoped repository `GITHUB_TOKEN` to the action so the review path can be validated before this workflow exists on the default branch. The job only runs on same-repository PRs and grants `contents: read`, `pull-requests: write`, `issues: write`, and `actions: read`.

After Claude succeeds, the workflow upserts a single PR summary comment marked with `<!-- agentmill-claude-code-review -->`. This keeps clean reviews visible on the pull request even when Claude has no inline findings to post.

## Provider notes

- OpenAI Codex GitHub Actions require an OpenAI Platform API key in `OPENAI_API_KEY`; a ChatGPT subscription is not a GitHub Actions credential.
- ChatGPT Plus/Pro/Team can still use Codex through the hosted Codex GitHub integration, such as `@codex review`, outside this workflow.
- Claude Code GitHub Actions can use an Anthropic API key or a Claude Code OAuth token. Pro and Max users can generate the OAuth token locally with `claude setup-token`.
- DeepSeek is viable with Claude Code because it exposes an Anthropic-compatible API. It is not a safe drop-in backend for the OpenAI Codex action, which expects OpenAI API behavior rather than only Chat Completions compatibility.
