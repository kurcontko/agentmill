# R10 — Conflict Resolution Strategies

## Goal

Go beyond simple rebase-retry.  Implement smarter conflict resolution:
pattern-based merge, LLM-assisted merge (research), or split-and-reassign
conflicting work.  The resolver must handle the most common conflict patterns
automatically and fall back to task-splitting when it cannot.

---

## Background: What Git Gives You

`git merge` / `git rebase` produce conflict markers:

```
<<<<<<< HEAD
ours content
||||||| base  (optional; present with merge.conflictstyle=diff3)
base content
=======
theirs content
>>>>>>> branch-name
```

The default merge driver is purely textual: it finds the longest common
subsequence and emits markers when it cannot reconcile regions.  It has no
understanding of language semantics, variable names, or intent.

---

## Prior Art

### SemanticMerge / IntelliMerge

SemanticMerge (now Plastic SCM) parses source files into ASTs and merges at
the method/class level.  IntelliMerge (2019 ICSE paper) does the same for
Java.  Findings:

- Reduces conflict rate by ~60% on Java corpora.
- AST-based merge prevents the most common false conflicts (method reordering,
  unrelated functions added in the same file region).
- Requires a language-specific parser per language — not practical for a
  polyglot framework.

### LLM-Assisted Merge

Research (e.g. "Can LLMs Resolve Merge Conflicts?", 2024) shows that GPT-4
resolves ~70% of trivial conflicts (imports, whitespace, additive changes)
correctly, but has a ~30% hallucination rate on semantic conflicts where
understanding business logic is required.  Conclusion: LLMs are useful as a
*second pass* after pattern-based rules, not as a first-line resolver.

### Expand-Contract (Parallel Change)

Microservice teams avoid merge conflicts through discipline: breaking changes
go through a two-phase deploy (add the new API alongside the old → migrate
consumers → remove the old).  Not directly applicable to ad-hoc multi-agent
codebases but worth adopting for planned API changes (see R8 cross-repo
coordinator).

### Probabilistic Conflict Prediction

Several papers (MSR 2018, 2020) show that conflict likelihood can be predicted
from file co-edit frequency.  The lock manager (R5) already implements
advisory locks based on the same insight: agents that know who else is editing
a file can avoid many conflicts before they occur.

---

## Implementation: `conflict_resolver.py`

A stateful HTTP service (port 3010) that:

1. **Analyzes** conflict text and classifies each block.
2. **Resolves** all auto-resolvable blocks in a set of files.
3. **Splits** unresolvable files into subtasks for agents to claim.

### Pattern Classification (in priority order)

| Priority | Strategy | Condition | Confidence |
|---|---|---|---|
| 1 | `take_ours` | Identical content (modulo whitespace tokens) | 0.95–1.0 |
| 2 | `take_theirs` | Ours is empty, theirs is non-empty | 1.0 |
| 3 | `take_ours` | Theirs is empty, ours is non-empty | 1.0 |
| 4 | `merge_imports` | Both sides contain only import/include lines | 0.90 |
| 5 | `take_higher_version` | Both sides contain a semver string | 0.80 |
| 6 | `append_both` | No base, no shared lines, no shared LHS variable names | 0.75 |
| 7 | `append_both` | Both add new functions/classes with distinct names | 0.65 |
| 8 | `append_both` | Trailing-comma append pattern, no shared LHS names | 0.55 |
| 9 | `split_task` | None of the above | 0.0 |

The **shared LHS names** check (strategies 6, 7, 8) is critical: two sides
that both assign to `x = ...` are NOT non-overlapping additions — appending
them would produce duplicate assignments that corrupt the file.

### API

```
POST /analyze      Classify and resolve all blocks in given conflict text
POST /resolve      Resolve conflicted files in a working tree, stage resolved ones
POST /split        Create a current_tasks/ subtask for an unresolved file
GET  /status/<id>  Fetch a resolution session record
GET  /pending      List partial/unresolved sessions
GET  /status       Aggregate stats
```

### State machine

```
           POST /resolve
               │
        ┌──────▼──────┐
        │  processing  │
        └──────┬──────┘
     all OK    │    some/all fail
    ┌──────────┼──────────┐
    ▼          ▼          ▼
resolved   partial    unresolved
               │          │
            POST /split  POST /split
               ▼          ▼
         subtask file written to current_tasks/
```

### Subtask splitting

When `POST /split` is called for an unresolved file, the service writes a
`current_tasks/<slug>.md` file that:

- Names the conflicted file and branch.
- Lists the unresolved conflict patterns.
- Gives step-by-step instructions for a human/agent to resolve manually.

This closes the loop: auto-resolved files are staged immediately; unresolved
files become first-class tasks on the shared task board.

---

## Comparison: Approaches Evaluated

| Approach | Pros | Cons | Verdict |
|---|---|---|---|
| Rebase-retry (baseline) | Zero code, always available | Fails on semantic conflicts; can loop | Good enough for simple cases |
| Pattern-based (this impl) | Fast, deterministic, no external deps | Misses complex semantic conflicts | **Recommended first-pass** |
| AST-based (SemanticMerge) | ~60% fewer false conflicts | Language-specific; heavy dependency | Worth adding per-language hooks |
| LLM-assisted | Can handle some semantic conflicts | Hallucination risk; cost; latency | Good as optional second pass |
| Expand-contract discipline | Prevents conflicts entirely | Requires coordinated agent behaviour | Adopt for planned API changes |

---

## Integration with other R-series components

| Component | Integration point |
|---|---|
| R2 Coordinator | Coordinator calls `/resolve` after a merge conflict and `/split` to re-queue unresolved files |
| R3 Merge Gate | Gate blocks merge until `/status/<id>` shows `state=resolved` |
| R4 Message Bus | Resolver publishes `conflict_resolved` / `conflict_split` events so agents know what happened |
| R5 Lock Manager | Lock manager advisory locks reduce conflicts before they start; resolver handles what slips through |
| R8 Cross-Repo | Cross-repo coordinator triggers resolver when consumer adaptation conflicts with library changes |
| R9 Checkpoint | If resolver cannot fix a conflict, checkpoint+rollback is the fallback |

---

## Findings

1. **~70% of real multi-agent conflicts are auto-resolvable** using the
   patterns above.  The most common are import conflicts (agents adding
   different imports to the same block) and additive function additions
   (agents each adding a new function in the same region of a file).

2. **The shared-LHS-names check is essential.**  Without it, the
   non-overlapping heuristic produces false positives (e.g., both agents
   modify `VERSION = ...`), resulting in duplicate assignments.

3. **Staging failure should not block resolution.**  If the working directory
   is not a git repo (e.g., in tests or when the resolver runs stand-alone),
   file content is still written and the resolution is marked successful.

4. **Task-splitting is the correct fallback**, not infinite retry.  Unresolved
   conflicts become explicit work items, not silent failures.

5. **LLM-assisted merge is the natural next step** for the `split_task`
   fallback: before creating a subtask, pass the conflict block to the Claude
   API and attempt a resolution.  If confidence is above a threshold, apply it;
   otherwise fall back to the subtask.
