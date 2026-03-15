#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# AgentMill Benchmark Runner
# ============================================================
#
# Runs SWE-bench Lite across multiple models:
#   - Gemini 3 Flash (API, $0.50/M in)
#   - MiniMax M2.5 (local, 230B MoE, 80.2% SWE-bench)
#   - GLM-4.7-Flash (local, 30B MoE, 59.2% SWE-bench)
#   - Qwen3.5-35B (local, dense, community favorite)
#
# Prerequisites:
#   pip install datasets openai
#   export GOOGLE_API_KEY=...          # for Gemini
#   export LOCAL_API_KEY=dummy         # for local vLLM (any string)
#   # Start vLLM on localhost:8000 with the target model
#
# Usage:
#   bash benchmarks/run_benchmark.sh smoke      # 5 tasks, quick test
#   bash benchmarks/run_benchmark.sh short      # 20 tasks
#   bash benchmarks/run_benchmark.sh full       # all 300 tasks
# ============================================================

MODE="${1:-smoke}"

case "$MODE" in
    smoke) LIMIT=5;   ITERS=2; TIMEOUT=900;  WORKERS=1 ;;
    short) LIMIT=20;  ITERS=3; TIMEOUT=1800; WORKERS=2 ;;
    full)  LIMIT=0;   ITERS=3; TIMEOUT=1800; WORKERS=4 ;;
    *) echo "Usage: $0 {smoke|short|full}"; exit 1 ;;
esac

TIMESTAMP="$(date -u '+%Y%m%d_%H%M%S')"
BASE_DIR="benchmark_results/run_${TIMESTAMP}"
COMMON_ARGS="--limit $LIMIT --max-iterations $ITERS --timeout $TIMEOUT --workers $WORKERS"

echo "============================================================"
echo " AgentMill Benchmark — mode=$MODE, limit=$LIMIT, iters=$ITERS"
echo " Results → $BASE_DIR/"
echo "============================================================"

run_bench() {
    local provider="$1"
    local label="$2"
    local results_dir="$BASE_DIR/$label"
    echo ""
    echo ">>> [$label] Starting ($provider)..."
    python benchmarks/swe_bench_lite/run.py \
        --provider "$provider" \
        --results-dir "$results_dir" \
        $COMMON_ARGS \
        2>&1 | tee "$results_dir.log" || echo ">>> [$label] FAILED (see $results_dir.log)"
    echo ">>> [$label] Done → $results_dir/"
}

# --- API models ---
if [ -n "${GOOGLE_API_KEY:-}" ]; then
    run_bench "gemini3-flash" "gemini3-flash"
else
    echo "SKIP: gemini3-flash (GOOGLE_API_KEY not set)"
fi

# --- Local models (vLLM at localhost:8000) ---
# User swaps models in vLLM between runs.
# Set LOCAL_API_KEY=dummy (vLLM doesn't check auth by default).

if [ -n "${LOCAL_API_KEY:-}" ]; then
    if [ "${RUN_MINIMAX:-}" = "1" ]; then
        run_bench "local-minimax" "minimax-m2.5"
    fi
    if [ "${RUN_QWEN122B:-}" = "1" ]; then
        run_bench "local-qwen122b" "qwen3.5-122b"
    fi
    if [ "${RUN_GLM4FLASH:-}" = "1" ]; then
        run_bench "local-glm4-flash" "glm4.7-flash"
    fi
    if [ "${RUN_QWEN35B:-}" = "1" ]; then
        run_bench "local-qwen35b" "qwen3.5-35b"
    fi
else
    echo "SKIP: local models (LOCAL_API_KEY not set)"
fi

# --- Summary ---
echo ""
echo "============================================================"
echo " All runs complete. Results in $BASE_DIR/"
echo ""
echo " To evaluate:"
echo "   pip install swebench"
echo "   for d in $BASE_DIR/*/; do"
echo '     label=$(basename "$d")'
echo '     python -m swebench.harness.run_evaluation \'
echo "       --dataset_name princeton-nlp/SWE-bench_Lite \\"
echo '       --predictions_path "$d/predictions.jsonl" \'
echo '       --max_workers 8 --run_id "$label"'
echo "   done"
echo "============================================================"
