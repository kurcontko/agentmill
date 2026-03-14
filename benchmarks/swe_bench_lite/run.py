#!/usr/bin/env python3
"""
AgentMill SWE-bench Lite Benchmark Runner

Runs AgentMill against SWE-bench Lite (300 instances) and produces
predictions compatible with the official SWE-bench evaluation harness.

Usage:
    # Run full benchmark (300 tasks)
    python benchmarks/swe_bench_lite/run.py

    # Run specific instances
    python benchmarks/swe_bench_lite/run.py --instances django__django-11099 astropy__astropy-12907

    # Run first N tasks (for testing)
    python benchmarks/swe_bench_lite/run.py --limit 5

    # Use local mode (no Docker, just claude CLI)
    python benchmarks/swe_bench_lite/run.py --local --limit 5

    # Evaluate results
    python -m swebench.harness.run_evaluation \\
        --dataset_name princeton-nlp/SWE-bench_Lite \\
        --predictions_path benchmark_results/swe_lite/predictions.jsonl \\
        --max_workers 8 --run_id agentmill

Requirements:
    pip install datasets
    # For evaluation: pip install swebench
"""

import argparse
import json
import logging
import shutil
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

# Add parent to path for shared imports
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from shared.task_runner import (
    BenchmarkConfig,
    TaskResult,
    print_summary,
    run_task_docker,
    write_metrics,
    write_predictions,
)

logger = logging.getLogger(__name__)

DATASET_NAME = "princeton-nlp/SWE-bench_Lite"
MODEL_NAME = "agentmill-claude"


def load_tasks(
    limit: int = 0,
    instance_ids: list[str] | None = None,
    split: str = "test",
) -> list[dict]:
    """Load SWE-bench Lite tasks from HuggingFace."""
    from datasets import load_dataset

    logger.info(f"Loading {DATASET_NAME} split={split}...")
    ds = load_dataset(DATASET_NAME, split=split)

    tasks = []
    for row in ds:
        task = {
            "instance_id": row["instance_id"],
            "repo": row["repo"],
            "base_commit": row["base_commit"],
            "problem_statement": row["problem_statement"],
            "hints_text": row.get("hints_text", ""),
            "version": row.get("version", ""),
        }
        if instance_ids and task["instance_id"] not in instance_ids:
            continue
        tasks.append(task)
        if limit and len(tasks) >= limit:
            break

    logger.info(f"Loaded {len(tasks)} tasks")
    return tasks


def run_single_task(task: dict, config: BenchmarkConfig) -> TaskResult:
    """Run a single task in its own temp directory."""
    work_dir = Path(tempfile.mkdtemp(prefix=f"swe_lite_{task['instance_id']}_"))
    try:
        return run_task_docker(task, config, work_dir)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="Run AgentMill against SWE-bench Lite")
    parser.add_argument("--model", default="sonnet", help="Claude model (default: sonnet)")
    parser.add_argument("--max-iterations", type=int, default=3, help="Max agent loop iterations per task")
    parser.add_argument("--timeout", type=int, default=1800, help="Timeout per task in seconds")
    parser.add_argument("--limit", type=int, default=0, help="Limit number of tasks (0=all)")
    parser.add_argument("--instances", nargs="+", help="Specific instance IDs to run")
    parser.add_argument("--split", default="test", choices=["test", "dev"], help="Dataset split")
    parser.add_argument("--workers", type=int, default=1, help="Parallel workers")
    parser.add_argument("--results-dir", default="benchmark_results/swe_lite", help="Output directory")
    parser.add_argument("--local", action="store_true", help="Run locally (no Docker)")
    parser.add_argument("--image", default="agentmill", help="Docker image name")
    parser.add_argument("--loop-delay", type=int, default=2, help="Delay between iterations")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    config = BenchmarkConfig(
        model=args.model,
        max_iterations=args.max_iterations,
        timeout_seconds=args.timeout,
        agent_image=args.image,
        results_dir=args.results_dir,
        use_docker=not args.local,
        parallel_workers=args.workers,
        loop_delay=args.loop_delay,
        anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY", ""),
        claude_oauth_token=os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", ""),
    )

    if not config.anthropic_api_key and not config.claude_oauth_token:
        logger.error("Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN")
        sys.exit(1)

    # Load tasks
    tasks = load_tasks(limit=args.limit, instance_ids=args.instances, split=args.split)
    if not tasks:
        logger.error("No tasks to run")
        sys.exit(1)

    # Run benchmark
    results_dir = Path(args.results_dir)
    results_dir.mkdir(parents=True, exist_ok=True)

    results: list[TaskResult] = []

    if args.workers > 1:
        with ProcessPoolExecutor(max_workers=args.workers) as pool:
            futures = {
                pool.submit(run_single_task, task, config): task["instance_id"]
                for task in tasks
            }
            for future in as_completed(futures):
                iid = futures[future]
                try:
                    results.append(future.result())
                except Exception as e:
                    logger.error(f"[{iid}] Worker failed: {e}")
                    results.append(TaskResult(instance_id=iid, error=str(e)))
    else:
        for task in tasks:
            results.append(run_single_task(task, config))

    # Write outputs
    write_predictions(results, results_dir / "predictions.jsonl", MODEL_NAME)
    write_metrics(results, results_dir / "metrics.jsonl")

    # Save config for reproducibility
    with open(results_dir / "config.json", "w") as f:
        json.dump({
            "dataset": DATASET_NAME,
            "split": args.split,
            "model": config.model,
            "max_iterations": config.max_iterations,
            "timeout_seconds": config.timeout_seconds,
            "use_docker": config.use_docker,
            "agent_image": config.agent_image,
            "total_tasks": len(tasks),
        }, f, indent=2)

    print_summary(results)

    print(f"\nResults saved to: {results_dir}/")
    print(f"\nTo evaluate:")
    print(f"  pip install swebench")
    print(f"  python -m swebench.harness.run_evaluation \\")
    print(f"    --dataset_name {DATASET_NAME} \\")
    print(f"    --predictions_path {results_dir}/predictions.jsonl \\")
    print(f"    --max_workers 8 --run_id agentmill")


import os

if __name__ == "__main__":
    main()
