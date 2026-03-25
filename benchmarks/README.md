# AgentMill Benchmarks

Benchmark harnesses for measuring AgentMill's agent loop against industry-standard coding agent evaluations.

## Benchmarks

### SWE-bench Lite (300 tasks)

Industry-standard benchmark. Real GitHub issues from popular Python repos with ground-truth test suites. Every coding agent reports this number.

```bash
# Install deps
pip install datasets

# Run 5 tasks (quick test)
python benchmarks/swe_bench_lite/run.py --limit 5

# Run full benchmark
python benchmarks/swe_bench_lite/run.py --workers 4

# Evaluate
pip install swebench
python -m swebench.harness.run_evaluation \
    --dataset_name princeton-nlp/SWE-bench_Lite \
    --predictions_path benchmark_results/swe_lite/predictions.jsonl \
    --max_workers 8 --run_id agentmill
```

### SWE-EVO (48 tasks)

Long-horizon software evolution benchmark. Agents must implement all changes from release notes spanning version upgrades. Tests multi-iteration capability — AgentMill's core value proposition.

```bash
# Run 3 tasks (quick test)
python benchmarks/swe_evo/run.py --limit 3

# Run full benchmark (longer timeout, more iterations)
python benchmarks/swe_evo/run.py --max-iterations 10 --timeout 3600 --workers 2

# Evaluate
git clone https://github.com/FSoft-AI4Code/SWE-EVO.git
cd SWE-EVO
python SWE-bench/evaluate_instance.py \
    --trajectories_path ../benchmark_results/swe_evo/predictions.jsonl \
    --max_workers 8
```

## Modes

### Docker mode (default)

Runs each task inside an AgentMill container. Requires `docker build -t agentmill .` first.

### Local mode (`--local`)

Runs `claude` CLI directly against the repo. Useful for development/debugging.

## Key Options

| Flag | Default | Description |
|------|---------|-------------|
| `--model` | `sonnet` | Claude model to use |
| `--max-iterations` | 3 (Lite) / 8 (EVO) | Agent loop iterations per task |
| `--timeout` | 1800 (Lite) / 3600 (EVO) | Seconds per task |
| `--limit N` | 0 (all) | Run only first N tasks |
| `--instances ID...` | all | Run specific instance IDs |
| `--workers N` | 1 | Parallel task runners |
| `--local` | false | Skip Docker, run claude CLI directly |

## Auth

Set one of:
```bash
export ANTHROPIC_API_KEY=sk-ant-...
# or
export CLAUDE_CODE_OAUTH_TOKEN=...
```

## Output

```
benchmark_results/
├── swe_lite/
│   ├── predictions.jsonl    # SWE-bench compatible predictions
│   ├── metrics.jsonl        # Per-task timing, iterations, patch size
│   └── config.json          # Run configuration for reproducibility
└── swe_evo/
    ├── predictions.jsonl
    ├── metrics.jsonl
    └── config.json
```

## Metrics Tracked

| Metric | Description |
|--------|-------------|
| Resolve rate | % of tasks where tests pass (from evaluation harness) |
| Patch rate | % of tasks where agent produced any diff |
| Iterations used | How many loop iterations the agent needed |
| Time per task | Wall-clock seconds |
| Patch size | Characters of diff produced |

## Requirements

- Python 3.11+
- `datasets` package (HuggingFace)
- Docker (for container mode)
- `swebench` package (for evaluation only)
- 120GB+ disk, 16GB+ RAM (for SWE-bench evaluation)
