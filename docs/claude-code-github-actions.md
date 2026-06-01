# Claude Code PR Review in GitHub Actions

This repository includes `.github/workflows/claude-code-review.yml`, a disabled-by-default PR review workflow that runs Claude Code through DeepSeek's Anthropic-compatible API.

## Enable DeepSeek-backed reviews

1. Install the Claude GitHub App for this repository: https://github.com/apps/claude
2. Add an Actions secret named `DEEPSEEK_API_KEY` with a key from the DeepSeek Platform.
3. Add an Actions repository variable named `CLAUDE_CODE_REVIEW_ENABLED` with value `true`.
4. Open, update, reopen, or mark a same-repository PR ready for review.

The workflow is skipped unless `CLAUDE_CODE_REVIEW_ENABLED=true`, so it does not make CI red before the review path is intentionally enabled. If the variable is enabled before `DEEPSEEK_API_KEY` exists, the job exits successfully without running Claude Code. It also skips fork PRs so repository secrets are not exposed to untrusted branches.

The workflow uses:

```yaml
ANTHROPIC_BASE_URL: https://api.deepseek.com/anthropic
anthropic_api_key: ${{ secrets.DEEPSEEK_API_KEY }}
--model "deepseek-v4-pro[1m]"
```

`anthropic_api_key` is intentional for GitHub Actions: the Claude Code action maps it to the Anthropic `x-api-key` path that DeepSeek supports. For local Claude Code shells, DeepSeek also documents the `ANTHROPIC_AUTH_TOKEN` form.

## Provider notes

- OpenAI Codex GitHub Actions require an OpenAI Platform API key in `OPENAI_API_KEY`; a ChatGPT subscription is not a GitHub Actions credential.
- ChatGPT Plus/Pro/Team can still use Codex through the hosted Codex GitHub integration, such as `@codex review`, outside this workflow.
- Claude Code GitHub Actions can use an Anthropic API key or a Claude Code OAuth token. Pro and Max users can generate the OAuth token locally with `claude setup-token`.
- DeepSeek is viable with Claude Code because it exposes an Anthropic-compatible API. It is not a safe drop-in backend for the OpenAI Codex action, which expects OpenAI API behavior rather than only Chat Completions compatibility.
