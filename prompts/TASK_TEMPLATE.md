# Research: <TOPIC>

## Question

<One-sentence statement of what you want to know. Make it answerable, not
open-ended. Good: "What are the currently-deployed container escape CVEs
affecting Docker in 2025-2026 and how are vendors mitigating them?"
Bad: "Tell me about container security.">

## Scope

Include:
- <what counts as "in scope" — domains, time windows, source types>
- <e.g. "published 2024 or later", "vendor docs, arXiv, Snyk/Wiz writeups">

Exclude:
- <what to skip even if interesting — keeps the loop from drifting>
- <e.g. "consumer AI products", "pre-2023 research", "Medium think-pieces without primary sources">

## Deliverables

Primary:
- `REPORT.md` — structured report with sections:
  1. <section 1>
  2. <section 2>
  3. <section 3>
  4. <section 4>
  5. <section 5>

Supporting:
- `memory/sources.md` — ≥ N unique URLs (set N based on scope; 20-40 is typical)
- `memory/findings.md` — ≥ 1 finding per source with verbatim quote
- `memory/contradictions.md` — documented disagreements between sources
- `memory/open_questions.md` — updated list; items are either answered or escalated

## Numeric success criteria (REQUIRED — do not leave as prose)

State at least one quantitative target the agent can self-evaluate against
without judgment. Vague targets ("comprehensive coverage", "high quality")
let agents declare victory early ("agentic laziness" — Anthropic, Mar 2026).

Examples — pick at least one shape:
- **Coverage**: ≥ 30 unique URLs in `sources.md`, ≥ 10 from primary sources
- **Accuracy**: every claim in `REPORT.md` has a `[^n]` footnote (target: 0 unfootnoted)
- **Saturation**: 3 consecutive iterations in `logs/results.tsv` show `sources_added=0`
- **Domain-specific**: e.g. "max relative error vs reference < 0.1%" for benchmarks

Fill in here:

- [ ] <numeric target 1>
- [ ] <numeric target 2 (optional)>

## Done when

- [ ] All numeric success criteria above are met
- [ ] Every section in `REPORT.md` has ≥ 3 `[^n]` footnotes backed by `sources.md` entries
- [ ] ≥ K primary sources (vendor docs / papers / RFCs) — set K ≥ 5 for well-documented topics, ≥ 2 for niche
- [ ] `memory/open_questions.md` has ≤ 5 unresolved items, each tagged with why (e.g. "needs paywalled access", "no public data")
- [ ] `memory/failed_approaches.md` has documented dead ends (so re-runs don't repeat them)
- [ ] Red-team iteration (if multi-agent) has challenged at least N claims — set N = number of REPORT.md sections

When all of the above are true, the agent appends `TASK_COMPLETE` to this file.

## Source policy

Preference order (highest first):
1. Primary — vendor docs, official repos, RFCs, NIST, OWASP, IETF drafts, arXiv preprints, peer-reviewed papers
2. Engineering blogs of named vendors (Anthropic, OpenAI, Google, AWS, Cloudflare, etc.)
3. Security vendors (Snyk, Wiz, Okta, Sysdig, Aqua, Upwind, Cremit)
4. Established tech press with primary reporting (The Hacker News, Ars Technica, HN if commentary points to primary)
5. Only if nothing better: Medium, community blogs, Reddit threads — and only when they link to something verifiable

Scrape with Brightdata MCP (`search_engine_batch`, `scrape_as_markdown`) before WebFetch. Never use raw `curl` in Bash — it bypasses the agent's ability to verify the content.

## Methodology notes

- Log scope cuts in `memory/decisions.md` so future iterations don't re-litigate them.
- When sources disagree, quote both and surface in `memory/contradictions.md`. Do not collapse to one.
- Paywalled sources: try open-access mirrors (arXiv, author's site, institutional repo). If still blocked, mark in `sources.md` with `(paywalled)` and use the abstract.
- Prefer dated content (`-2025`, `2026`) for fast-moving topics; static references (RFCs, textbooks) for foundational claims.

## Operator notes

- Intended model: <sonnet / opus>. Default sonnet; promote to opus only for final synthesis iteration.
- Expected iteration count: <20-40>. Revise after first 5 iterations based on `./mill history` trajectory.
- Multi-agent? <yes/no>. If yes: agent-1=breadth, agent-2=depth, agent-3=redteam. See `prompts/PROMPT_RESEARCH_*.md`.

---

<!-- The agent will append TASK_COMPLETE below this line when done. Do not edit past here. -->
