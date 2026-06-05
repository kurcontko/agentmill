# AgentMill as a Researcher Agent

AgentMill's core loop — "mount a git repo, run Claude in a fresh context, commit, repeat" — is not specific to code. With three swaps it becomes a respawning research engine:

| Swap | Coding mode | Research mode |
|---|---|---|
| Repo contents | Source tree | Knowledge base (markdown notes, citations, report) |
| Loop goal | Ship features, pass tests | Expand breadth and depth until coverage criteria met |
| Tools | Bash, Edit, tests | WebFetch, WebSearch, Brightdata MCP |

Same infrastructure. Same memory layer. Same respawn-to-avoid-context-rot discipline. Just a different `PROMPT.md`.

---

## 1. Why AgentMill fits research

- **No context rot**: every iteration starts fresh, re-reads findings from disk. A 100-iteration research run doesn't accumulate a 500k-token conversation.
- **Markdown memory layer** (`memory/*.md`, flock-guarded) is purpose-built for append-only notes, sources, open questions.
- **Iteration log** (`logs/results.tsv`) gives you a quantitative audit trail — sources added per iteration, which section was touched.
- **Multi-agent mode** parallelizes cleanly: one agent scans breadth, one drills depth, one red-teams claims.
- **Typed completion gate** (`research_saturation`) stops only after a zero-new-source streak and no unresolved open questions.

> **Prior art**: Anthropic's "Long-running Claude" post (Mar 2026) and the `smsharma/clax` CLAUDE.md are the canonical rationale for this pattern. See [`LONG_RUNNING.md`](LONG_RUNNING.md) for how AgentMill's design maps to their recommendations.

## 2. The repo-as-knowledge-base layout

```
~/research/<topic>/
├── TASK.md                    # research brief + done-when criteria
├── REPORT.md                  # the deliverable — evolves each iteration
├── memory/
│   ├── findings.md            # per-source notes (append-only, timestamped)
│   ├── sources.md             # dedup URL list
│   ├── hypotheses.md          # competing explanations + confidence updates
│   ├── open_questions.md      # worklist — items get converted to findings
│   ├── contradictions.md      # sources that disagree — signals "more research"
│   └── decisions.md           # methodological choices (scope cuts, source-class filters)
└── logs/
    └── results.tsv            # iteration | agent | sources_added | section | status
```

Create once:
```bash
./mill init --research "my topic"
cd ~/research/my-topic
$EDITOR TASK.md    # fill in topic, scope, done-when
git add -A && git commit -m "init research brief"
```

## 3. Tool enablement

### Brightdata MCP (preferred for scraping)

AgentMill inherits your host's MCP servers via `setup-claude-config.sh`. If `claude mcp list` shows Brightdata on your host, it'll be available inside the container. Verify once after container start:

```bash
./mill shell ~/research/my-topic
> /mcp list
```

If missing, add Brightdata to `~/.claude.json` on the host (not inside the container).

### Permissions

Research needs network tools. Default AgentMill settings already allow `WebFetch`, `WebSearch`, `mcp__*`. Confirm:

```bash
grep -A3 permissions .claude/settings.local.json
```

### Recommended env for research

```bash
# .env additions for research mode
MODEL=sonnet                    # opus only on final synthesis
MAX_ITERATIONS=25               # research saturates; don't leave it unbounded
LOOP_DELAY=30                   # give Brightdata / rate limits breathing room
AUTO_COMMIT=on                  # always commit, even partial — audit trail matters
PROMPT_FILE=/prompts/PROMPT_RESEARCH.md
AGENTMILL_COMPLETION_GATE=research_saturation
AGENTMILL_RESEARCH_SATURATION_ITERATIONS=3
AGENTMILL_RESEARCH_OPEN_QUESTIONS_MAX=0
```

## 4. Three variants

### 4a. Single-agent sweep (start here)

```bash
PROMPT_FILE=/prompts/PROMPT_RESEARCH.md \
  ./mill run ~/research/my-topic --model sonnet --iterations 20 --delay 30
```

One agent, linear iterations. Best for: a defined topic, a report as the deliverable, budget ≤ $10.

### 4b. Multi-agent specialization

```bash
PROMPT_FILE_1=/prompts/PROMPT_RESEARCH_BREADTH.md \
PROMPT_FILE_2=/prompts/PROMPT_RESEARCH_DEPTH.md \
PROMPT_FILE_3=/prompts/PROMPT_RESEARCH_REDTEAM.md \
  ./mill multi ~/research/my-topic 3 --model sonnet --iterations 10
```

Three agents, each pushing to its own branch (`agent-1`, `agent-2`, `agent-3`), rebasing on conflict. Best for: large topics where triangulation matters. Merge branches manually when they saturate.

### 4c. Continuous-watch researcher

```bash
# Prompt variant tells the agent "check sources for new material since last commit"
RESPAWN=true LOOP_DELAY=3600 PROMPT_FILE=/prompts/PROMPT_RESEARCH.md \
  ./mill watch ~/research/my-topic
```

Runs indefinitely, one iteration per hour. Best for: tracking an evolving topic over weeks. Adjust the prompt to emphasize "delta since last iteration."

## 5. Citation discipline (the non-negotiable rule)

Research agents hallucinate citations more than coding agents ship bad code — the feedback loop is weaker (no test suite says "this claim is false"). Six rules in the prompt keep it honest:

1. **Every claim in REPORT.md has a `[^n]` footnote** pointing to an entry in `sources.md`.
2. **Every material source records a source class** from the task's
   source-class filter table, such as peer-reviewed paper, preprint, vendor
   docs, vendor blog, standards/government guidance, news, community forum, or
   personal blog.
3. **Every entry in `sources.md` has a URL the agent actually fetched** (the prompt enforces this via "do not add to sources.md unless you called scrape_as_markdown / WebFetch on it in the current iteration").
4. **Every material source records class and date** when available, so current-state claims can be audited for staleness.
5. **Quotes > paraphrases.** `findings.md` requires 1-3 verbatim quotes per source — paraphrasing is where drift happens.
6. **Competing hypotheses stay visible.** `memory/hypotheses.md` records what evidence would change the answer and which fetched URL moved confidence.

The `PROMPT_RESEARCH.md` files enforce these rules.

Inspect the current audit state at any time:

```bash
./mill report status ~/research/my-topic
```

This summarizes unique source URLs, unresolved open questions, per-section
citation counts, and recent `results.tsv` rows including `sources_added` and
`section` when those columns are present.

## 6. When is it done?

Research has no test suite, so we define saturation explicitly:

- **N consecutive zero-new-source iterations** (default: 3). Agent is no longer finding fresh material.
- **`open_questions.md` has ≤ K unresolved items** (default: 0), so open questions must be answered, closed, or explicitly converted into caveats.
- **Every `REPORT.md` section has ≥ M citations** (default: 3, with ≥1 primary source).
- **Hypotheses are resolved or explicitly caveated** in `REPORT.md`; unresolved hypotheses are not silently dropped.

With `AGENTMILL_COMPLETION_GATE=research_saturation`, AgentMill accepts
completion only when the zero-source streak and unresolved-open-question
threshold pass, then records the decision in `logs/convergence.tsv`. The
citation and hypothesis checks stay in the prompt and report-status audit.

## 7. Memory topics worth creating

AgentMill's markdown memory layer (`./mill memory <topic>`) is underused in coding mode but load-bearing here:

| Topic | Purpose | Grow rate |
|---|---|---|
| `findings` | Source notes with quotes | ~500-2000 lines over a full run |
| `sources` | URL dedup | 1 line per scraped page |
| `hypotheses` | Competing explanations and confidence updates | 5-30 entries |
| `open_questions` | Worklist | Grows early, shrinks late |
| `contradictions` | Disagreements between sources | Usually 5-20 entries |
| `decisions` | "Scoped out X because Y" | 3-10 entries |
| `failed_approaches` | Dead ends, with 1-line reason (prevents re-trying) | 5-15 entries per run |
| `in_progress` | Flock-guarded task claims in multi-agent mode | Small; clears at exit |
| `vocabulary` | Domain terms + definitions | Optional; useful for unfamiliar fields |

Check progress at any time:
```bash
./mill memory                           # list all topics
./mill memory findings --tail 50        # read recent findings
./mill memory --search "error rate"     # grep across memory
./mill history                          # per-iteration stats
```

## 8. Tradeoffs to know before running

- **Cost ≠ quality.** 40 iterations on Sonnet ≈ 4x the spend of 10 iterations but often only 1.5x the report quality. Saturation is real — stop when `results.tsv` shows `sources_added=0` three times running.
- **Model choice matters here.** Sonnet is fine for extraction. Opus is worth paying for on the final synthesis iteration (run a one-off `--iterations 1 --model opus` after the Sonnet sweep saturates).
- **Prompt injection is sharper in research than in coding.** Every scraped page is attacker-controlled untrusted content — the full [lethal trifecta](HARNESS_SECURITY.md#threat-model-for-agentmill) applies. Mitigation: route scraping through Brightdata MCP (returns structured content), not raw `curl` in `Bash`. Deny `WebFetch`/`WebSearch` in settings if you don't need them.
- **Rate limits.** Brightdata's free tier is generous for a single sweep but not for continuous-watch. Upgrade or add `LOOP_DELAY=60` minimum.
- **Legal.** Some publishers prohibit scraping in ToS. Brightdata handles this for most public-web sources; arXiv/ACL are fine; paywalled journals are a minefield — have the agent use abstracts + open-access mirrors only.

## 9. The files

- [`prompts/PROMPT_RESEARCH.md`](../prompts/PROMPT_RESEARCH.md) — single-agent Ralph-style research loop
- [`prompts/PROMPT_RESEARCH_BREADTH.md`](../prompts/PROMPT_RESEARCH_BREADTH.md) — breadth scanner for multi-agent
- [`prompts/PROMPT_RESEARCH_DEPTH.md`](../prompts/PROMPT_RESEARCH_DEPTH.md) — depth driller for multi-agent
- [`prompts/PROMPT_RESEARCH_REDTEAM.md`](../prompts/PROMPT_RESEARCH_REDTEAM.md) — critic / fact-checker for multi-agent
- [`prompts/TASK_TEMPLATE.md`](../prompts/TASK_TEMPLATE.md) — seed brief to copy into a fresh research repo

## 10. Dogfooding: re-running the hardening research

The safe-harness source set in [`HARNESS_SECURITY.md`](HARNESS_SECURITY.md) was produced by hand via Brightdata MCP in a single Claude Code session. You can reproduce that style of work as an autonomous research run:

```bash
mkdir -p ~/research/agent-security && cd $_
git init
cat > TASK.md <<'EOF'
# Research: security of ephemeral AI coding agents

## Scope
Sandbox patterns, prompt-injection defenses, credential isolation,
cost controls, container escape, supply-chain risks. 2024-2026 material.

## Done when
- REPORT.md covers the 8 sections listed in open_questions.md
- sources.md has >=30 unique URLs, >=10 from vendor docs or first-party repos
- 3 consecutive iterations add 0 new sources
EOF
mkdir memory logs
echo -e "- Which container boundaries hold against agent-generated code?\n- How do vendors handle credential injection today?\n- What are the published attack chains (s1ngularity, Clinejection)?\n- ..." > memory/open_questions.md
git add -A && git commit -m "init"

PROMPT_FILE=/prompts/PROMPT_RESEARCH.md \
  /path/to/agentmill/mill run . --model sonnet --iterations 25 --delay 30
```

Compare the resulting `REPORT.md` to [`HARNESS_SECURITY.md`](HARNESS_SECURITY.md) as a quality baseline for source quality, citation discipline, and security-control coverage.
