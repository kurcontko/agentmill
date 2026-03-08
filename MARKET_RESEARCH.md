# AgentMill Market Research & Strategy

## Competitive Landscape

| Project | Stars | Docker | Loop | Multi-Agent | Notes |
|---------|-------|--------|------|-------------|-------|
| **Auto-Claude** | ~13k | No | Yes | Claude only | Full Electron GUI app, heavy, Kanban board |
| **Dify** | ~18.7k | No | Yes | Claude only | Enterprise multi-agent orchestration platform |
| **Cline** | ~11k | No | Yes | Yes (openrouter, claude, etc) | TS CLI, REPL loop orchestrator, no Docker |
| **aider** | ~10k | Yes | No | Yes (claude, codex) | Sandboxing focus, single-run, no loop |
| **Autonoe** | ~3 | Yes | Yes | Claude only | Stalled due to SDK token limits |
| **Codeloop** | new | No | Yes | Yes | Orchestration layer, very recent |

## AgentMill's Unique Position

**Niche:** Lightweight, Docker-native, zero-config autonomous loop for AI coding agents.

- Cline = loop but no Docker
- aider = Docker but no loop
- Auto-Claude = loop but GUI-heavy and Claude-only
- **AgentMill = Docker + loop + simple `docker compose up`**

## Multi-Agent Expansion (Planned)

Adding support for OpenRouter, Gemini API, and Qwen would:
- Make AgentMill model-agnostic (unique among competitors)
- Open the door to local LLM support via OpenRouter + Ollama
- Unlock r/LocalLLaMA as a marketing channel

Implementation: core loop logic (git pull, run agent, commit, push) is agent-agnostic. Need configurable CLI command, per-agent base images.

## Ephemeral Positioning

- Current: persistent container with ephemeral Claude sessions (fresh `claude -p` per iteration)
- Each iteration starts a clean Claude context - no bleed between runs
- Long-lived container is a feature: no cold start, graceful shutdown, flexibility
- **Marketing language:** "Ephemeral agent sessions" - not "ephemeral containers"
- Avoid "ephemeral containers" on r/DevOps (they'll nitpick), fine for AI subs

## Marketing Channels

| Channel | Fit | Lead With |
|---------|-----|-----------|
| **r/ClaudeAI** | Perfect | Autonomous Claude Code in Docker |
| **r/LocalLLaMA** | Good (after multi-agent) | "Works with local models via OpenRouter/Ollama" |
| **r/AICoding** | Good | Simplest autonomous coding agent setup |
| **r/SideProject** | Good | Docker simplicity angle |
| **r/DevOps** | Decent | Containerized autonomous agent workflow |
| **r/LocalLLaMA** | Skip (until multi-agent) | Claude-only won't resonate |

## Pre-Launch Checklist

- [ ] Polish README with demo GIF
- [ ] Commit `.gitignore`
- [ ] Clean up uncommitted changes (Dockerfile, docker-compose, entrypoints)
- [ ] Consider adding multi-agent support before broader push