# AgentMill Benchmark Plan

## Models

### API

| Label | Model | $/M in | $/M out | SWE-bench | Notes |
|-------|-------|--------|---------|-----------|-------|
| `gemini3-flash` | Gemini 3 Flash Preview | $0.50 | $3.00 | 78% | Best cheap API model |

### Local (DGX Spark, 128GB)

| Label | Model | Params (total/active) | VRAM | SWE-bench | Notes |
|-------|-------|-----------------------|------|-----------|-------|
| `minimax-m2.5` | MiniMax M2.5 | 230B / 10B MoE | ~101GB (3-bit GGUF) | **80.2%** | Best open-source, #1 SWE-bench |
| `qwen3.5-122b` | Qwen3.5-122B-A10B | 122B / 10B MoE | ~75GB (NVFP4) | 72.0% | NVIDIA-optimized for Spark |
| `glm4.7-flash` | GLM-4.7-Flash | 30B / 3B MoE | ~12GB (Q4) | 59.2% | Ultra-light, great for local folks |
| `qwen3.5-35b` | Qwen3.5-35B | 35B dense | ~20GB (Q4) | ~55% est. | Solid small dense model |

## Why These Models

- **MiniMax M2.5**: Highest SWE-bench open-source score (80.2%), proven on DGX Spark at 26 tok/s, strong tool calling (76.8% BFCL)
- **Qwen3.5-122B**: Runner-up, NVFP4 quantization purpose-built for DGX Spark, 262K context, excellent tool calling
- **Gemini 3 Flash**: Best API value — 78% SWE-bench at $0.50/M input, 1M context
- **GLM-4.7-Flash**: Nearly free to run locally (~3B active), 59% SWE-bench is impressive per-param. Audience: local hobbyists
- **Qwen3.5-35B**: Popular community model, runs on consumer GPUs (24GB), good baseline

## Run Configs

### Smoke test (5 tasks, ~30 min)
```bash
bash benchmarks/run_benchmark.sh smoke
```

### Short run (20 tasks, ~2-3 hours)
```bash
bash benchmarks/run_benchmark.sh short
```

### Full run (300 tasks, ~8-12 hours)
```bash
bash benchmarks/run_benchmark.sh full
```

### Running local models

Start vLLM with target model, then set env vars:

```bash
# On DGX Spark — start vLLM with MiniMax M2.5
vllm serve MiniMax-M2.5 --port 8000 --tensor-parallel-size 1

# In another terminal — run benchmark
export LOCAL_API_KEY=dummy
export RUN_MINIMAX=1
bash benchmarks/run_benchmark.sh short

# Swap model and run next
# (stop vLLM, restart with GLM-4.7-Flash)
export RUN_MINIMAX=0
export RUN_GLM4FLASH=1
bash benchmarks/run_benchmark.sh short
```

### Running Gemini 3 Flash (API)
```bash
export GOOGLE_API_KEY=your-key-here
bash benchmarks/run_benchmark.sh short
```

## Key Numbers to Report

| Metric | What it shows |
|--------|---------------|
| **Resolve rate** | % of tasks where tests pass (primary metric) |
| **Patch rate** | % of tasks that produced any diff |
| **Cost per resolved issue** | Total cost / resolved count (API models only) |
| **Iterations needed** | How many loop iterations to solve |
| **Time per task** | Wall-clock seconds |
| **Iteration value** | resolve_rate(3 iters) - resolve_rate(1 iter) |

## Output Structure

```
benchmark_results/
└── run_20260315_143000/
    ├── gemini3-flash/
    │   ├── predictions.jsonl    # SWE-bench compatible
    │   ├── metrics.jsonl        # Per-task details
    │   └── config.json          # Reproducibility
    ├── minimax-m2.5/
    ├── glm4.7-flash/
    ├── qwen3.5-35b/
    └── qwen3.5-122b/
```

## Evaluation

After all runs complete:
```bash
pip install swebench

for d in benchmark_results/run_*/*/; do
    label=$(basename "$d")
    python -m swebench.harness.run_evaluation \
        --dataset_name princeton-nlp/SWE-bench_Lite \
        --predictions_path "$d/predictions.jsonl" \
        --max_workers 8 --run_id "$label"
done
```
