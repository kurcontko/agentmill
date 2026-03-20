#!/usr/bin/env python3
"""
AgentMill SWE-bench Lite Benchmark Runner

Runs AgentMill against SWE-bench Lite (300 instances) and produces
predictions compatible with the official SWE-bench evaluation harness.

Supports multiple providers: Claude (via CLI), DeepSeek, GLM, Gemini,
Qwen, Codestral, GPT-4o-mini (via OpenAI-compatible APIs).

Usage:
    # Claude models (via AgentMill Docker)
    python benchmarks/swe_bench_lite/run.py --limit 5
    python benchmarks/swe_bench_lite/run.py --model haiku --limit 5

    # Cheap models (via OpenAI-compatible API)
    python benchmarks/swe_bench_lite/run.py --provider deepseek --limit 5
    python benchmarks/swe_bench_lite/run.py --provider glm4-flash --limit 5
    python benchmarks/swe_bench_lite/run.py --provider gemini3-flash --limit 5

    # List available providers
    python benchmarks/swe_bench_lite/run.py --list-providers

    # Evaluate results
    python -m swebench.harness.run_evaluation \
        --dataset_name princeton-nlp/SWE-bench_Lite \
        --predictions_path benchmark_results/swe_lite/predictions.jsonl \
        --max_workers 8 --run_id agentmill

Requirements:
    pip install datasets
    pip install openai  # for non-Claude providers
"""

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from shared.providers import (
    PROVIDERS,
    ProviderConfig,
    estimate_cost,
    get_provider,
    list_providers,
    run_with_claude_cli,
    run_with_openai_compat,
)
from shared.task_runner import (
    BenchmarkConfig,
    TaskResult,
    print_summary,
    run_task_docker,
    write_metrics,
    write_predictions,
    write_prompt,
)

logger = logging.getLogger(__name__)

DATASET_NAME = "princeton-nlp/SWE-bench_Lite"


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


def run_task_with_provider(
    task: dict,
    provider: ProviderConfig,
    max_iterations: int,
    timeout: int,
) -> TaskResult:
    """Run a single task using a non-Claude provider via OpenAI-compatible API."""
    instance_id = task["instance_id"]
    result = TaskResult(instance_id=instance_id)

    work_dir = Path(tempfile.mkdtemp(prefix=f"swe_lite_{instance_id}_"))
    repo_dir = work_dir / "repo"

    try:
        # Clone repo at base_commit
        logger.info(f"[{instance_id}] Cloning {task['repo']} @ {task['base_commit'][:8]}")
        subprocess.run(
            ["git", "clone", "--quiet", f"https://github.com/{task['repo']}.git", str(repo_dir)],
            check=True, capture_output=True, timeout=300,
        )
        subprocess.run(
            ["git", "checkout", task["base_commit"]],
            cwd=repo_dir, check=True, capture_output=True,
        )

        # Build prompt
        prompt = f"""Fix the following GitHub issue in this repository.

## Issue

{task['problem_statement']}
"""
        if task.get("hints_text", "").strip():
            prompt += f"\n## Hints\n\n{task['hints_text']}\n"

        prompt += """
## Instructions

You MUST use the provided tools to fix this issue. Follow this workflow:

1. Use `list_files` or `run_command` (with grep) to find relevant source files.
2. Use `read_file` to read the relevant code.
3. Use `write_file` to write the COMPLETE fixed file content back. This is REQUIRED.
4. You may use `run_command` to run tests and verify your fix.

CRITICAL: You MUST call `write_file` with the full corrected file content to apply your fix.
Do NOT just analyze the code — you must actually write the fix using write_file.
Do NOT modify test files unless the issue specifically requires it.

Available tools: read_file, write_file, run_command, list_files.
"""

        start = time.monotonic()
        total_usage = {"input_tokens": 0, "output_tokens": 0}

        # Multi-iteration loop (like AgentMill's respawning loop)
        for iteration in range(1, max_iterations + 1):
            iter_prompt = prompt
            if iteration > 1:
                # Add context about previous iterations
                diff = subprocess.run(
                    ["git", "diff", task["base_commit"]],
                    cwd=repo_dir, capture_output=True, text=True,
                ).stdout
                if diff:
                    iter_prompt += f"\n## Changes So Far (iteration {iteration})\n\n```diff\n{diff[:5000]}\n```\n\nContinue improving the fix if needed.\n"
                else:
                    iter_prompt += f"\n## Iteration {iteration}\n\nNo changes yet. Make the fix.\n"

            exit_code, output, usage = run_with_openai_compat(
                iter_prompt, provider, str(repo_dir), timeout=timeout,
            )
            total_usage["input_tokens"] += usage.get("input_tokens", 0)
            total_usage["output_tokens"] += usage.get("output_tokens", 0)
            result.iterations_used = iteration

            if exit_code != 0:
                result.error = output[:500]
                break

        # Capture final diff
        diff_proc = subprocess.run(
            ["git", "diff", task["base_commit"]],
            cwd=repo_dir, capture_output=True, text=True,
        )
        result.model_patch = diff_proc.stdout
        result.elapsed_seconds = time.monotonic() - start
        result.exit_code = 0

        cost = estimate_cost(total_usage, provider)
        logger.info(
            f"[{instance_id}] Done in {result.elapsed_seconds:.0f}s, "
            f"patch={len(result.model_patch)} chars, "
            f"tokens={total_usage['input_tokens']+total_usage['output_tokens']}, "
            f"cost=${cost:.4f}"
        )

    except subprocess.TimeoutExpired:
        result.error = "timeout"
        logger.warning(f"[{instance_id}] Timed out")
    except Exception as e:
        result.error = str(e)
        logger.error(f"[{instance_id}] Error: {e}")
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    return result


def run_task_claude(task: dict, config: BenchmarkConfig) -> TaskResult:
    """Run a single task using Claude via AgentMill Docker or local CLI."""
    work_dir = Path(tempfile.mkdtemp(prefix=f"swe_lite_{task['instance_id']}_"))
    try:
        return run_task_docker(task, config, work_dir)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="Run AgentMill against SWE-bench Lite")
    parser.add_argument("--provider", default="claude", help="Provider name (default: claude)")
    parser.add_argument("--model", default=None, help="Model override (uses provider default if unset)")
    parser.add_argument("--max-iterations", type=int, default=3, help="Agent loop iterations per task")
    parser.add_argument("--timeout", type=int, default=1800, help="Timeout per task in seconds")
    parser.add_argument("--limit", type=int, default=0, help="Limit number of tasks (0=all)")
    parser.add_argument("--instances", nargs="+", help="Specific instance IDs to run")
    parser.add_argument("--split", default="test", choices=["test", "dev"], help="Dataset split")
    parser.add_argument("--workers", type=int, default=1, help="Parallel workers")
    parser.add_argument("--results-dir", default=None, help="Output directory (auto-generated if unset)")
    parser.add_argument("--local", action="store_true", help="Run locally (no Docker, Claude only)")
    parser.add_argument("--image", default="agentmill", help="Docker image name")
    parser.add_argument("--loop-delay", type=int, default=2, help="Delay between iterations")
    parser.add_argument("--list-providers", action="store_true", help="List available providers")
    args = parser.parse_args()

    if args.list_providers:
        print(list_providers())
        return

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    provider = get_provider(args.provider)
    if args.model:
        provider.model = args.model

    model_name = f"agentmill-{provider.name}-{provider.model}"
    results_dir = Path(args.results_dir or f"benchmark_results/swe_lite/{args.provider}")
    results_dir.mkdir(parents=True, exist_ok=True)

    tasks = load_tasks(limit=args.limit, instance_ids=args.instances, split=args.split)
    if not tasks:
        logger.error("No tasks to run")
        sys.exit(1)

    results: list[TaskResult] = []

    if provider.name == "claude":
        # Use AgentMill Docker/CLI
        config = BenchmarkConfig(
            model=provider.model,
            max_iterations=args.max_iterations,
            timeout_seconds=args.timeout,
            agent_image=args.image,
            results_dir=str(results_dir),
            use_docker=not args.local,
            parallel_workers=args.workers,
            loop_delay=args.loop_delay,
            anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY", ""),
            claude_oauth_token=os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", ""),
        )
        if not config.anthropic_api_key and not config.claude_oauth_token:
            logger.error("Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN")
            sys.exit(1)

        for task in tasks:
            results.append(run_task_claude(task, config))
    else:
        # Use OpenAI-compatible API
        api_key = os.environ.get(provider.api_key_env, "")
        if not api_key:
            logger.error(f"Set {provider.api_key_env} env var")
            sys.exit(1)

        if args.workers > 1:
            with ProcessPoolExecutor(max_workers=args.workers) as pool:
                futures = {
                    pool.submit(
                        run_task_with_provider, task, provider,
                        args.max_iterations, args.timeout,
                    ): task["instance_id"]
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
                results.append(
                    run_task_with_provider(task, provider, args.max_iterations, args.timeout)
                )

    # Write outputs
    write_predictions(results, results_dir / "predictions.jsonl", model_name)
    write_metrics(results, results_dir / "metrics.jsonl")

    with open(results_dir / "config.json", "w") as f:
        json.dump({
            "dataset": DATASET_NAME,
            "split": args.split,
            "provider": provider.name,
            "model": provider.model,
            "max_iterations": args.max_iterations,
            "timeout_seconds": args.timeout,
            "total_tasks": len(tasks),
            "input_cost_per_m": provider.input_cost_per_m,
            "output_cost_per_m": provider.output_cost_per_m,
        }, f, indent=2)

    print_summary(results)

    print(f"\nProvider: {provider.name} / {provider.model}")
    print(f"Pricing: ${provider.input_cost_per_m}/M in, ${provider.output_cost_per_m}/M out")
    print(f"Results: {results_dir}/")
    print(f"\nTo evaluate:")
    print(f"  pip install swebench")
    print(f"  python -m swebench.harness.run_evaluation \\")
    print(f"    --dataset_name {DATASET_NAME} \\")
    print(f"    --predictions_path {results_dir}/predictions.jsonl \\")
    print(f"    --max_workers 8 --run_id {args.provider}")


if __name__ == "__main__":
    main()
