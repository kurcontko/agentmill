"""
Shared task runner for AgentMill benchmarks.

Clones a repo at a specific commit, runs AgentMill's agent loop against it,
and captures the resulting diff as a prediction.
"""

import json
import logging
import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class TaskResult:
    instance_id: str
    model_patch: str = ""
    elapsed_seconds: float = 0.0
    iterations_used: int = 0
    exit_code: int = -1
    error: str = ""
    log_path: str = ""


@dataclass
class BenchmarkConfig:
    model: str = "sonnet"
    max_iterations: int = 3
    loop_delay: int = 2
    timeout_seconds: int = 1800  # 30 min per task
    agent_image: str = "agentmill"
    results_dir: str = "benchmark_results"
    use_docker: bool = True
    parallel_workers: int = 1
    # Auth (one must be set)
    anthropic_api_key: str = ""
    claude_oauth_token: str = ""


def write_prompt(prompt_path: Path, problem_statement: str, hints: str = "") -> None:
    """Write the benchmark task prompt for the agent."""
    content = f"""# SWE-bench Task

Fix the following GitHub issue in this repository.

## Issue

{problem_statement}
"""
    if hints and hints.strip():
        content += f"""
## Hints

{hints}
"""

    content += """
## Instructions

- Make the minimal code changes needed to fix this issue.
- Do NOT modify test files unless the issue specifically requires it.
- Follow existing code patterns and conventions.
- When done, ensure your changes are committed.
- Focus on correctness — a minimal fix is better than an over-engineered one.
"""
    prompt_path.write_text(content)


def run_task_docker(
    task: dict,
    config: BenchmarkConfig,
    work_dir: Path,
) -> TaskResult:
    """Run a single benchmark task using AgentMill Docker container."""
    instance_id = task["instance_id"]
    repo = task["repo"]
    base_commit = task["base_commit"]

    result = TaskResult(instance_id=instance_id)
    repo_dir = work_dir / "repo"
    logs_dir = work_dir / "logs"
    prompts_dir = work_dir / "prompts"
    logs_dir.mkdir(parents=True, exist_ok=True)
    prompts_dir.mkdir(parents=True, exist_ok=True)

    try:
        # Clone and checkout
        logger.info(f"[{instance_id}] Cloning {repo} @ {base_commit[:8]}")
        subprocess.run(
            ["git", "clone", "--quiet", f"https://github.com/{repo}.git", str(repo_dir)],
            check=True,
            capture_output=True,
            timeout=300,
        )
        subprocess.run(
            ["git", "checkout", base_commit],
            cwd=repo_dir,
            check=True,
            capture_output=True,
        )

        # Write prompt
        write_prompt(
            prompts_dir / "PROMPT.md",
            task.get("problem_statement", ""),
            task.get("hints_text", ""),
        )

        start = time.monotonic()

        if config.use_docker:
            result = _run_docker(instance_id, config, repo_dir, logs_dir, prompts_dir, start)
        else:
            result = _run_local(instance_id, config, repo_dir, logs_dir, prompts_dir, start)

        # Capture diff
        diff_proc = subprocess.run(
            ["git", "diff", base_commit],
            cwd=repo_dir,
            capture_output=True,
            text=True,
        )
        result.model_patch = diff_proc.stdout
        result.elapsed_seconds = time.monotonic() - start
        result.log_path = str(logs_dir)

        logger.info(
            f"[{instance_id}] Done in {result.elapsed_seconds:.0f}s, "
            f"patch={len(result.model_patch)} chars"
        )

    except subprocess.TimeoutExpired:
        result.error = "timeout"
        logger.warning(f"[{instance_id}] Timed out after {config.timeout_seconds}s")
    except Exception as e:
        result.error = str(e)
        logger.error(f"[{instance_id}] Error: {e}")

    return result


def _run_docker(
    instance_id: str,
    config: BenchmarkConfig,
    repo_dir: Path,
    logs_dir: Path,
    prompts_dir: Path,
    start: float,
) -> TaskResult:
    """Run agent via Docker container."""
    result = TaskResult(instance_id=instance_id)

    env_flags = []
    if config.anthropic_api_key:
        env_flags += ["-e", f"ANTHROPIC_API_KEY={config.anthropic_api_key}"]
    elif config.claude_oauth_token:
        env_flags += ["-e", f"CLAUDE_CODE_OAUTH_TOKEN={config.claude_oauth_token}"]

    cmd = [
        "docker", "run", "--rm",
        "-v", f"{repo_dir}:/workspace/repo",
        "-v", f"{logs_dir}:/workspace/logs",
        "-v", f"{prompts_dir}:/prompts",
        *env_flags,
        "-e", f"MODEL={config.model}",
        "-e", f"MAX_ITERATIONS={config.max_iterations}",
        "-e", f"LOOP_DELAY={config.loop_delay}",
        "-e", "AUTO_COMMIT=wip",
        "-e", "AGENT_ID=bench",
        config.agent_image,
    ]

    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=config.timeout_seconds,
    )
    result.exit_code = proc.returncode
    result.elapsed_seconds = time.monotonic() - start

    # Count iterations from log
    log_file = logs_dir / "agent-bench.log"
    if log_file.exists():
        content = log_file.read_text()
        result.iterations_used = content.count("==== Iteration")

    return result


def _run_local(
    instance_id: str,
    config: BenchmarkConfig,
    repo_dir: Path,
    logs_dir: Path,
    prompts_dir: Path,
    start: float,
) -> TaskResult:
    """Run agent locally (no Docker) using claude CLI directly."""
    result = TaskResult(instance_id=instance_id)
    prompt_file = prompts_dir / "PROMPT.md"

    for iteration in range(1, config.max_iterations + 1):
        prompt_content = prompt_file.read_text()
        proc = subprocess.run(
            [
                "claude", "--dangerously-skip-permissions",
                "-p", prompt_content,
                "--model", config.model,
            ],
            cwd=repo_dir,
            capture_output=True,
            text=True,
            timeout=config.timeout_seconds,
        )

        result.iterations_used = iteration
        result.exit_code = proc.returncode

        # Check if changes were made
        status = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=repo_dir,
            capture_output=True,
            text=True,
        )
        if status.stdout.strip():
            # Auto-commit
            subprocess.run(["git", "add", "-A"], cwd=repo_dir)
            subprocess.run(
                ["git", "commit", "-m", f"bench: iteration {iteration}"],
                cwd=repo_dir,
                capture_output=True,
            )

        if iteration < config.max_iterations:
            time.sleep(config.loop_delay)

    result.elapsed_seconds = time.monotonic() - start
    return result


def clone_and_checkout(task: dict, work_dir: Path) -> Path:
    """Clone a repo at a specific commit. Returns the repo directory."""
    instance_id = task["instance_id"]
    repo_dir = work_dir / "repo"
    logger.info(f"[{instance_id}] Cloning {task['repo']} @ {task['base_commit'][:8]}")
    subprocess.run(
        ["git", "clone", "--quiet", f"https://github.com/{task['repo']}.git", str(repo_dir)],
        check=True, capture_output=True, timeout=300,
    )
    subprocess.run(
        ["git", "checkout", task["base_commit"]],
        cwd=repo_dir, check=True, capture_output=True,
    )
    return repo_dir


def capture_diff(repo_dir: Path, base_commit: str) -> str:
    """Capture the git diff from base_commit to current state."""
    proc = subprocess.run(
        ["git", "diff", base_commit],
        cwd=repo_dir, capture_output=True, text=True,
    )
    return proc.stdout


def write_predictions(results: list[TaskResult], output_path: Path, model_name: str) -> None:
    """Write results as SWE-bench compatible JSONL predictions file."""
    with open(output_path, "w") as f:
        for r in results:
            pred = {
                "instance_id": r.instance_id,
                "model_name_or_path": model_name,
                "model_patch": r.model_patch,
            }
            f.write(json.dumps(pred) + "\n")
    logger.info(f"Wrote {len(results)} predictions to {output_path}")


def write_metrics(results: list[TaskResult], output_path: Path) -> None:
    """Write detailed per-task metrics as JSONL."""
    with open(output_path, "w") as f:
        for r in results:
            metrics = {
                "instance_id": r.instance_id,
                "elapsed_seconds": round(r.elapsed_seconds, 1),
                "iterations_used": r.iterations_used,
                "exit_code": r.exit_code,
                "patch_size_chars": len(r.model_patch),
                "has_patch": len(r.model_patch) > 0,
                "error": r.error,
            }
            f.write(json.dumps(metrics) + "\n")
    logger.info(f"Wrote {len(results)} metrics to {output_path}")


def print_summary(results: list[TaskResult]) -> None:
    """Print a summary of benchmark results."""
    total = len(results)
    has_patch = sum(1 for r in results if r.model_patch)
    errors = sum(1 for r in results if r.error)
    avg_time = sum(r.elapsed_seconds for r in results) / max(total, 1)
    avg_iters = sum(r.iterations_used for r in results) / max(total, 1)

    print(f"\n{'='*60}")
    print(f"AgentMill Benchmark Summary")
    print(f"{'='*60}")
    print(f"Total tasks:       {total}")
    print(f"Patches produced:  {has_patch} ({has_patch/max(total,1)*100:.1f}%)")
    print(f"Errors:            {errors}")
    print(f"Avg time/task:     {avg_time:.0f}s")
    print(f"Avg iterations:    {avg_iters:.1f}")
    print(f"{'='*60}")
    print(f"\nNote: Run swebench evaluation to get resolve rate.")
