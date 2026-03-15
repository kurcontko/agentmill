# AgentMill Benchmark Plan

## Goal

Run SWE-bench Lite (5-task smoke test, then 50-task subset) across cheap coding models to show:
1. AgentMill works with the respawning loop pattern
2. Cost/performance tradeoffs across models
3. Multi-iteration value (does iteration 2+ actually help?)

## Models to Benchmark

### Via Claude Code CLI (`--model`)
These work directly with AgentMill's existing `claude` CLI:

| Model ID | $/M in | $/M out | Est. SWE-bench |
|----------|--------|---------|----------------|
| `haiku` | $1.00 | $5.00 | ~74% |
| `sonnet` | $3.00 | $15.00 | ~80% |

### Via OpenAI-compatible API (needs adapter)
These require a lightweight adapter that replaces `claude` CLI with direct API calls:

| Model | Provider | $/M in | $/M out | Est. SWE-bench |
|-------|----------|--------|---------|----------------|
| DeepSeek V3.2 | DeepSeek | $0.28 | $0.42 | ~72% |
| GLM-4.7-Flash | Zhipu/Z.AI | $0.07 | $0.40 | 59% |
| Gemini 3 Flash | Google | $0.50 | $3.00 | 78% |
| Qwen3 Coder Plus | Alibaba | $0.65 | $3.25 | ~70% |
| Codestral | Mistral | $0.30 | $0.90 | N/A |
| GPT-4o-mini | OpenAI | $0.15 | $0.60 | ~30% |

## Benchmark Configs

### Smoke test (5 tasks, all models)
```bash
python benchmarks/swe_bench_lite/run.py --limit 5 --model haiku
python benchmarks/swe_bench_lite/run.py --limit 5 --model sonnet
python benchmarks/swe_bench_lite/run.py --limit 5 --provider deepseek --model deepseek-chat
python benchmarks/swe_bench_lite/run.py --limit 5 --provider zhipu --model glm-4.7-flash
```

### 50-task subset (top 3 models)
```bash
python benchmarks/swe_bench_lite/run.py --limit 50 --model haiku --max-iterations 3
python benchmarks/swe_bench_lite/run.py --limit 50 --provider deepseek --model deepseek-chat --max-iterations 3
python benchmarks/swe_bench_lite/run.py --limit 50 --provider google --model gemini-3-flash-preview --max-iterations 3
```

### Iteration-value test (does loop help?)
Run same 20 tasks with 1, 3, 5 iterations:
```bash
for iters in 1 3 5; do
  python benchmarks/swe_bench_lite/run.py --limit 20 --model haiku --max-iterations $iters \
    --results-dir benchmark_results/iter_test/haiku_${iters}
done
```

## Expected Output

```
benchmark_results/
├── swe_lite/
│   ├── haiku/          # predictions.jsonl, metrics.jsonl, config.json
│   ├── sonnet/
│   ├── deepseek/
│   ├── glm4flash/
│   └── gemini3flash/
├── iter_test/
│   ├── haiku_1/
│   ├── haiku_3/
│   └── haiku_5/
└── summary.md          # Auto-generated comparison table
```

## Key Numbers to Report

1. **Resolve rate** per model (from SWE-bench eval)
2. **Cost per resolved issue** = total_cost / resolved_count
3. **Iteration value** = resolve_rate(3 iters) - resolve_rate(1 iter)
4. **Patch rate** = % of tasks that produced any diff
5. **Avg time per task**

## Architecture: Multi-Provider Support

AgentMill currently runs `claude` CLI. For non-Claude models, the benchmark runner
bypasses the entrypoint and calls APIs directly via a thin adapter:

```
Claude models:    entrypoint.sh → claude CLI → Anthropic API
Other models:     benchmark runner → provider adapter → Provider API
```

The adapter mimics the agent loop: read prompt, call API with tool use, apply edits,
commit, repeat for N iterations. This is lighter than full AgentMill but tests the
same core value: does multi-iteration looping improve results?
