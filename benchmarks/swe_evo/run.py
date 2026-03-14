#!/usr/bin/env python3
"""
AgentMill SWE-EVO Benchmark Runner

Runs AgentMill against SWE-EVO (48 long-horizon evolution tasks).
SWE-EVO tests multi-step version evolution — implementing all changes
from release notes spanning version upgrades.

This is where AgentMill's respawning loop architecture shines:
agents iterate across multiple loops to handle large, multi-file changes.

Usage:
    # Run full benchmark (48 tasks)
    python benchmarks/swe_evo/run.py

    # Run specific instances
    python benchmarks/swe_evo/run.py --instances conan-io__conan_2.0.14_2.0.15

    # Run first N tasks
    python benchmarks/swe_evo/run.py --limit 5

    # More iterations for long-horizon tasks
    python benchmarks/swe_evo/run.py --max-iterations 10 --timeout 3600

Requirements:
    pip install datasets
"""

import argparse
import json
import logging
import os
import shutil
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

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

DATASET_NAME = "Fsoft-AIC/SWE-EVO"
MODEL_NAME = "agentmill-claude"


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
            # SWE-EVO specific
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


def write_evo_prompt(prompt_path: Path, task: dict) -> None:
    """Write a SWE-EVO specific prompt optimized for long-horizon evolution."""
    problem = task.get("problem_statement", "")
    start_ver = task.get("start_version", "?")
    end_ver = task.get("end_version", "?")
    test_cmds = task.get("test_cmds", "")

    content = f"""# SWE-EVO Task: Version Evolution

Implement the changes needed to evolve this codebase from version {start_ver} to {end_ver}.

## Release Notes / Change Specification

{problem}

## Instructions

This is a **long-horizon evolution task** — it likely requires changes across many files.

### Strategy

1. **Read the release notes carefully**. Identify distinct changes/features.
2. **Prioritize**: start with the most impactful or foundational changes.
3. **Work incrementally**: implement one feature/change at a time, commit after each.
4. **Test as you go**: run tests after each logical change.
5. **Don't try to do everything at once** — make progress across iterations.

### Rules

- Follow existing code patterns and conventions.
- Do NOT modify test files unless the release notes specifically require it.
- Commit after each coherent unit of progress.
- If stuck on one change, move to the next and come back.
- Update PROGRESS.md to track what you've completed vs what remains.
"""

    if test_cmds:
        content += f"""
### Test Command

```bash
{test_cmds}
```
"""

    prompt_path.write_text(content)


def run_single_task(task: dict, config: BenchmarkConfig) -> TaskResult:
    """Run a single SWE-EVO task."""
    work_dir = Path(tempfile.mkdtemp(prefix=f"swe_evo_{task['instance_id']}_"))
    try:
        # Write EVO-specific prompt instead of generic one
        prompts_dir = work_dir / "prompts"
        prompts_dir.mkdir(parents=True, exist_ok=True)
        write_evo_prompt(prompts_dir / "PROMPT.md", task)

        # Still use the shared runner for clone + agent execution
        return run_task_docker(task, config, work_dir)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="Run AgentMill against SWE-EVO")
    parser.add_argument("--model", default="sonnet", help="Claude model (default: sonnet)")
    parser.add_argument(
        "--max-iterations", type=int, default=8,
        help="Max iterations per task (default: 8, higher for long-horizon)"
    )
    parser.add_argument("--timeout", type=int, default=3600, help="Timeout per task (default: 3600s = 1hr)")
    parser.add_argument("--limit", type=int, default=0, help="Limit number of tasks (0=all)")
    parser.add_argument("--instances", nargs="+", help="Specific instance IDs to run")
    parser.add_argument("--split", default="test", help="Dataset split")
    parser.add_argument("--workers", type=int, default=1, help="Parallel workers")
    parser.add_argument("--results-dir", default="benchmark_results/swe_evo", help="Output directory")
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

    tasks = load_tasks(limit=args.limit, instance_ids=args.instances, split=args.split)
    if not tasks:
        logger.error("No tasks to run")
        sys.exit(1)

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

    # SWE-EVO specific: show per-repo breakdown
    by_repo: dict[str, list[TaskResult]] = {}
    for task, result in zip(tasks, results):
        repo = task["repo"]
        by_repo.setdefault(repo, []).append(result)

    print(f"\nPer-repo breakdown:")
    for repo, repo_results in sorted(by_repo.items()):
        patches = sum(1 for r in repo_results if r.model_patch)
        print(f"  {repo}: {patches}/{len(repo_results)} patches produced")

    print(f"\nResults saved to: {results_dir}/")
    print(f"\nTo evaluate with SWE-EVO harness:")
    print(f"  git clone https://github.com/FSoft-AI4Code/SWE-EVO.git")
    print(f"  cd SWE-EVO")
    print(f"  python SWE-bench/evaluate_instance.py \\")
    print(f"    --trajectories_path {results_dir}/predictions.jsonl \\")
    print(f"    --max_workers 8")


if __name__ == "__main__":
    main()
