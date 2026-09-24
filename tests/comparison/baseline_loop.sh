#!/usr/bin/env bash
# Development-only comparison baseline; not part of AgentMill.
#
# What a careful user might write around `docker run` + `claude -p`: a private
# clone, bounded attempts, per-attempt and total timeouts, checks in a fresh
# credential-free container, check feedback, last-passing tracking, hooks
# disabled for host Git, and patch export. Optional CHECK_DIR mounts held-out
# checks read-only at /checks in the check container only.
set -euo pipefail

if [[ $# -ne 8 ]]; then
    echo "usage: baseline_loop.sh SOURCE OUT_DIR IMAGE TASK CHECK MAX_ATTEMPTS ATTEMPT_TIMEOUT_S TOTAL_TIMEOUT_S" >&2
    exit 1
fi
source_repo=$1 out=$2 image=$3 task=$4 check=$5
max_attempts=$6 attempt_timeout=$7 total_timeout=$8

schema='{"type":"object","properties":{"status":{"type":"string","enum":["done","continue","blocked"]},"summary":{"type":"string"},"next_step":{"type":["string","null"]},"question":{"type":["string","null"]}},"required":["status","summary","next_step","question"],"additionalProperties":false}'
repo="$out/repo"
mkdir -p "$out"
git clone -q -- "$source_repo" "$repo"
base=$(git -C "$repo" rev-parse HEAD)
deadline=$((SECONDS + total_timeout))
last_passing="" feedback="No previous attempt." verdict=incomplete attempt=0

gitc() {
    git -C "$repo" -c core.hooksPath=/dev/null -c user.name=baseline \
        -c user.email=baseline@localhost "$@"
}
# --mount (unlike -v) fails instead of creating a missing source on the daemon host.
in_container() {
    docker run --rm --init --cap-drop ALL --security-opt no-new-privileges \
        --user "$(id -u):$(id -g)" -e HOME=/tmp \
        --mount "type=bind,src=$repo,dst=/workspace" -w /workspace "$@"
}

for attempt in $(seq 1 "$max_attempts"); do
    remaining=$((deadline - SECONDS))
    if ((remaining <= 0)); then
        verdict=time_limit
        break
    fi
    limit=$((remaining < attempt_timeout ? remaining : attempt_timeout))
    log="$out/attempt-$attempt"
    printf 'Task:\n%s\n\nCheck: %s\nAttempt %s/%s. Previous check output:\n%s\n' \
        "$task" "$check" "$attempt" "$max_attempts" "$feedback" > "$log.prompt"
    agent_exit=0
    in_container -i -e ANTHROPIC_API_KEY "$image" timeout -k 2 "$limit" \
        claude -p --output-format stream-json --verbose --json-schema "$schema" \
        --permission-mode dontAsk < "$log.prompt" > "$log.jsonl" 2> "$log.stderr" || agent_exit=$?
    status=$(jq -r 'select(.type == "result") | .structured_output.status // empty' \
        "$log.jsonl" 2> /dev/null | tail -n 1) || status=""
    gitc add -A
    gitc commit -q --no-verify --allow-empty -m "baseline attempt $attempt"
    passed=0
    held_out=()
    if [[ -n ${CHECK_DIR:-} ]]; then
        held_out=(--mount "type=bind,src=$CHECK_DIR,dst=/checks,readonly")
    fi
    if in_container ${held_out[@]+"${held_out[@]}"} "$image" bash -c "$check" > "$log.check" 2>&1; then
        passed=1
        last_passing=$(gitc rev-parse HEAD)
    fi
    feedback=$(tail -c 3000 "$log.check")
    echo "attempt=$attempt agent_exit=$agent_exit status=${status:-none} checks_passed=$passed" >> "$out/log"
    if [[ $status == "done" && $passed == 1 ]]; then
        verdict=success
        break
    fi
    if [[ $status == blocked ]]; then
        verdict=blocked
        break
    fi
done

final=$(gitc rev-parse HEAD)
gitc diff --binary "$base" "$final" > "$out/final.patch"
if [[ -n $last_passing ]]; then
    gitc diff --binary "$base" "$last_passing" > "$out/last-passing.patch"
fi
jq -n --arg verdict "$verdict" --arg base "$base" --arg final "$final" \
    --arg last_passing "$last_passing" --argjson attempts "$attempt" \
    '{verdict: $verdict, attempts: $attempts, base: $base, final: $final,
      last_passing: (if $last_passing == "" then null else $last_passing end)}' > "$out/result.json"
case $verdict in
    success) exit 0 ;;
    blocked) exit 3 ;;
    *) exit 2 ;;
esac
