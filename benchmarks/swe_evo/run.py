#!/usr/bin/env python3
"""
AgentMill SWE-EVO Benchmark Runner

Runs AgentMill against SWE-EVO (48 long-horizon evolution tasks).
SWE-EVO tests multi-step version evolution — implementing all changes
from release notes spanning version upgrades.

Supports multiple providers: Claude, DeepSeek, GLM, Gemini, Qwen, etc.

Usage:
    # Claude (via AgentMill Docker)
    python benchmarks/swe_evo/run.py --limit 3

    # Cheap models
    python benchmarks/swe_evo/run.py --provider deepseek --limit 3
    python benchmarks/swe_evo/run.py --provider glm4-flash --limit 3

    # More iterations for long-horizon tasks
    python benchmarks/swe_evo/run.py --max-iterations 10 --timeout 3600

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
    ProviderConfig,
    estimate_cost,
    get_provider,
    list_providers,
    run_with_openai_compat,
)
from shared.task_runner import (
    BenchmarkConfig,
    TaskResult,
    print_summary,
    run_task_docker,
    write_metrics,
    write_predictions,
)

logger = logging.getLogger(__name__)

DATASET_NAME = "Fsoft-AIC/SWE-EVO"


def load_tasks(
    limit: int = 0,
    instance_ids: list[str] | None = None,
    split: str = "test",
) -> list[dict]:
    """Load SWE-EVO tasks from HuggingFace."""
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
            "hints_text": "",
            "version": row.get("version", ""),
            "start_version": row.get("start_version", ""),
            "end_version": row.get("end_version", ""),
            "test_cmds": row.get("test_cmds", ""),
        }
        if instance_ids and task["instance_id"] not in instance_ids:
            continue
        tasks.append(task)
        if limit and len(tasks) >= limit:
            break

    logger.info(f"Loaded {len(tasks)} tasks")
    return tasks


def build_evo_prompt(task: dict, iteration: int = 1, current_diff: str = "") -> str:
    """Build a SWE-EVO specific prompt."""
    start_ver = task.get("start_version", "?")
    end_ver = task.get("end_version", "?")
    test_cmds = task.get("test_cmds", "")

    prompt = f"""# Version Evolution Task: {start_ver} → {end_ver}

Implement the changes needed to evolve this codebase from version {start_ver} to {end_ver}.

## Release Notes / Change Specification

{task['problem_statement']}

## Instructions

This is a long-horizon evolution task requiring changes across many files.

- Read the release notes carefully and identify distinct changes.
- Start with foundational changes, then build on them.
- Work incrementally: one feature/change at a time.
- Use read_file, write_file, run_command, list_files tools.
"""

    if test_cmds:
        prompt += f"\n## Test Command\n\n```bash\n{test_cmds}\n```\n"

    if iteration > 1 and current_diff:
        prompt += f"\n## Progress So Far (iteration {iteration})\n\n```diff\n{current_diff[:8000]}\n```\n\nContinue implementing remaining changes from the release notes.\n"
    elif iteration > 1:
        prompt += f"\n## Iteration {iteration}\n\nNo changes yet. Start implementing.\n"

    return prompt


def run_task_provider(
    task: dict,
    provider: ProviderConfig,
    max_iterations: int,
    timeout: int,
) -> TaskResult:
    """Run a single SWE-EVO task using a non-Claude provider."""
    instance_id = task["instance_id"]
    result = TaskResult(instance_id=instance_id)
    work_dir = Path(tempfile.mkdtemp(prefix=f"swe_evo_{instance_id}_"))
    repo_dir = work_dir / "repo"

    try:
        logger.info(f"[{instance_id}] Cloning {task['repo']} @ {task['base_commit'][:8]}")
        subprocess.run(
            ["git", "clone", "--quiet", f"https://github.com/{task['repo']}.git", str(repo_dir)],
            check=True, capture_output=True, timeout=300,
        )
        subprocess.run(
            ["git", "checkout", task["base_commit"]],
            cwd=repo_dir, check=True, capture_output=True,
        )

        start = time.monotonic()
        total_usage = {"input_tokens": 0, "output_tokens": 0}

        for iteration in range(1, max_iterations + 1):
            current_diff = subprocess.run(
                ["git", "diff", task["base_commit"]],
                cwd=repo_dir, capture_output=True, text=True,
            ).stdout

            prompt = build_evo_prompt(task, iteration, current_diff)

            exit_code, output, usage = run_with_openai_compat(
                prompt, provider, str(repo_dir), timeout=timeout,
            )
            total_usage["input_tokens"] += usage.get("input_tokens", 0)
            total_usage["output_tokens"] += usage.get("output_tokens", 0)
            result.iterations_used = iteration

            if exit_code != 0:
                result.error = output[:500]
                break

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
            f"patch={len(result.model_patch)} chars, cost=${cost:.4f}"
        )

    except subprocess.TimeoutExpired:
        result.error = "timeout"
    except Exception as e:
        result.error = str(e)
        logger.error(f"[{instance_id}] Error: {e}")
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    return result


def run_task_claude_evo(task: dict, config: BenchmarkConfig) -> TaskResult:
    """Run a single SWE-EVO task using Claude via Docker."""
    work_dir = Path(tempfile.mkdtemp(prefix=f"swe_evo_{task['instance_id']}_"))
    try:
        # Write EVO-specific prompt
        prompts_dir = work_dir / "prompts"
        prompts_dir.mkdir(parents=True, exist_ok=True)
        prompt = build_evo_prompt(task)
        (prompts_dir / "PROMPT.md").write_text(prompt)
        return run_task_docker(task, config, work_dir)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="Run AgentMill against SWE-EVO")
    parser.add_argument("--provider", default="claude", help="Provider name (default: claude)")
    parser.add_argument("--model", default=None, help="Model override")
    parser.add_argument("--max-iterations", type=int, default=8, help="Iterations per task (default: 8)")
    parser.add_argument("--timeout", type=int, default=3600, help="Timeout per task (default: 1hr)")
    parser.add_argument("--limit", type=int, default=0, help="Limit tasks (0=all)")
    parser.add_argument("--instances", nargs="+", help="Specific instance IDs")
    parser.add_argument("--split", default="test", help="Dataset split")
    parser.add_argument("--workers", type=int, default=1, help="Parallel workers")
    parser.add_argument("--results-dir", default=None, help="Output directory")
    parser.add_argument("--local", action="store_true", help="Run locally (Claude only)")
    parser.add_argument("--image", default="agentmill", help="Docker image")
    parser.add_argument("--loop-delay", type=int, default=2)
    parser.add_argument("--list-providers", action="store_true")
    args = parser.parse_args()

    if args.list_providers:
        print(list_providers())
        return

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    provider = get_provider(args.provider)
    if args.model:
        provider.model = args.model

    model_name = f"agentmill-{provider.name}-{provider.model}"
    results_dir = Path(args.results_dir or f"benchmark_results/swe_evo/{args.provider}")
    results_dir.mkdir(parents=True, exist_ok=True)

    tasks = load_tasks(limit=args.limit, instance_ids=args.instances, split=args.split)
    if not tasks:
        logger.error("No tasks to run")
        sys.exit(1)

    results: list[TaskResult] = []

    if provider.name == "claude":
        config = BenchmarkConfig(
            model=provider.model,
            max_iterations=args.max_iterations,
            timeout_seconds=args.timeout,
            agent_image=args.image,
            results_dir=str(results_dir),
            use_docker=not args.local,
            loop_delay=args.loop_delay,
            anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY", ""),
            claude_oauth_token=os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", ""),
        )
        for task in tasks:
            results.append(run_task_claude_evo(task, config))
    else:
        api_key = os.environ.get(provider.api_key_env, "")
        if not api_key:
            logger.error(f"Set {provider.api_key_env}")
            sys.exit(1)

        if args.workers > 1:
            with ProcessPoolExecutor(max_workers=args.workers) as pool:
                futures = {
                    pool.submit(run_task_provider, task, provider, args.max_iterations, args.timeout): task["instance_id"]
                    for task in tasks
                }
                for future in as_completed(futures):
                    iid = futures[future]
                    try:
                        results.append(future.result())
                    except Exception as e:
                        results.append(TaskResult(instance_id=iid, error=str(e)))
        else:
            for task in tasks:
                results.append(run_task_provider(task, provider, args.max_iterations, args.timeout))

    write_predictions(results, results_dir / "predictions.jsonl", model_name)
    write_metrics(results, results_dir / "metrics.jsonl")

    with open(results_dir / "config.json", "w") as f:
        json.dump({
            "dataset": DATASET_NAME,
            "provider": provider.name,
            "model": provider.model,
            "max_iterations": args.max_iterations,
            "timeout_seconds": args.timeout,
            "total_tasks": len(tasks),
            "input_cost_per_m": provider.input_cost_per_m,
            "output_cost_per_m": provider.output_cost_per_m,
        }, f, indent=2)

    print_summary(results)

    # Per-repo breakdown
    by_repo: dict[str, list[TaskResult]] = {}
    for task, result in zip(tasks, results):
        by_repo.setdefault(task["repo"], []).append(result)

    print(f"\nPer-repo breakdown:")
    for repo, repo_results in sorted(by_repo.items()):
        patches = sum(1 for r in repo_results if r.model_patch)
        print(f"  {repo}: {patches}/{len(repo_results)} patches")

    print(f"\nProvider: {provider.name} / {provider.model}")
    print(f"Pricing: ${provider.input_cost_per_m}/M in, ${provider.output_cost_per_m}/M out")
    print(f"Results: {results_dir}/")


if __name__ == "__main__":
    main()
