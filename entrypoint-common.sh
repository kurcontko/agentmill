#!/usr/bin/env bash

LOG_DIR="${LOG_DIR:-/workspace/logs}"
mkdir -p "$LOG_DIR"
AGENTMILL_PROFILE_LEVEL="${AGENTMILL_PROFILE_LEVEL:-trusted}"
AGENTMILL_RUN_ID="${AGENTMILL_RUN_ID:-$(date -u '+%Y%m%dT%H%M%SZ')-${AGENT_ID:-agent}-$$}"
AGENTMILL_PROVIDER="${AGENTMILL_PROVIDER:-}"
AGENTMILL_CLIENT="${AGENTMILL_CLIENT:-${AGENTMILL_PROVIDER:-claude}}"
AGENTMILL_CLIENT_TRANSPORT="${AGENTMILL_CLIENT_TRANSPORT:-native}"
AGENTMILL_ACP_BRIDGE="${AGENTMILL_ACP_BRIDGE:-/acp-stdio-bridge.py}"
AGENTMILL_ACP_PROMPT="${AGENTMILL_ACP_PROMPT:-}"
AGENTMILL_MCP_MANIFEST_LOCK="${AGENTMILL_MCP_MANIFEST_LOCK:-true}"
AGENTMILL_MCP_TOOL_SNAPSHOT="${AGENTMILL_MCP_TOOL_SNAPSHOT:-true}"
AGENTMILL_MCP_TOOL_SNAPSHOT_TIMEOUT_SECONDS="${AGENTMILL_MCP_TOOL_SNAPSHOT_TIMEOUT_SECONDS:-3}"
EVENT_LOG="${EVENT_LOG:-$LOG_DIR/events.jsonl}"
MAX_WALL_SECONDS="${MAX_WALL_SECONDS:-0}"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-0}"
MAX_TOTAL_TOKENS="${MAX_TOTAL_TOKENS:-0}"
MAX_TOTAL_USD="${MAX_TOTAL_USD:-0}"
AGENTMILL_COST_INPUT_PER_MTOKENS="${AGENTMILL_COST_INPUT_PER_MTOKENS:-0}"
AGENTMILL_COST_OUTPUT_PER_MTOKENS="${AGENTMILL_COST_OUTPUT_PER_MTOKENS:-0}"
AGENTMILL_COST_CACHE_CREATION_PER_MTOKENS="${AGENTMILL_COST_CACHE_CREATION_PER_MTOKENS:-0}"
AGENTMILL_COST_CACHE_READ_PER_MTOKENS="${AGENTMILL_COST_CACHE_READ_PER_MTOKENS:-0}"
AGENTMILL_CLAUDE_OUTPUT_FORMAT="${AGENTMILL_CLAUDE_OUTPUT_FORMAT:-text}"
AGENTMILL_HOOK_DIR="${AGENTMILL_HOOK_DIR:-/hooks}"
AGENTMILL_HOOK_TIMEOUT_SECONDS="${AGENTMILL_HOOK_TIMEOUT_SECONDS:-30}"
AGENTMILL_HOOK_CONTEXT_MAX_BYTES="${AGENTMILL_HOOK_CONTEXT_MAX_BYTES:-16384}"
AGENTMILL_ALLOW_HIGH_RISK_CHANGES="${AGENTMILL_ALLOW_HIGH_RISK_CHANGES:-false}"
AGENTMILL_WORKSPACE_MODE="${AGENTMILL_WORKSPACE_MODE:-direct}"
AGENTMILL_ALLOW_DIRECT_HOST_REPO="${AGENTMILL_ALLOW_DIRECT_HOST_REPO:-false}"
AGENTMILL_WRITE_ROOTS="${AGENTMILL_WRITE_ROOTS:-}"
AGENTMILL_WRITE_ROOT_SANDBOX="${AGENTMILL_WRITE_ROOT_SANDBOX:-auto}"
AGENTMILL_BWRAP_COMMAND="${AGENTMILL_BWRAP_COMMAND:-bwrap}"
AGENTMILL_SHELL_ALLOWLIST="${AGENTMILL_SHELL_ALLOWLIST:-}"
AGENTMILL_SHELL_DENYLIST="${AGENTMILL_SHELL_DENYLIST:-}"
AGENTMILL_ALLOW_SHELL_NETWORK="${AGENTMILL_ALLOW_SHELL_NETWORK:-false}"
AGENTMILL_PROTECTED_BRANCHES="${AGENTMILL_PROTECTED_BRANCHES:-main,master,trunk,release,production}"
AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES="${AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES:-false}"
AGENTMILL_ALLOW_FORCE_PUSH="${AGENTMILL_ALLOW_FORCE_PUSH:-false}"
AGENTMILL_ALLOW_MERGE_COMMITS="${AGENTMILL_ALLOW_MERGE_COMMITS:-false}"
AGENTMILL_GIT_REMOTE_ALLOWLIST="${AGENTMILL_GIT_REMOTE_ALLOWLIST:-}"
AGENTMILL_ALLOW_GIT_NETWORK="${AGENTMILL_ALLOW_GIT_NETWORK:-false}"
AGENTMILL_NETWORK="${AGENTMILL_NETWORK:-}"
AGENTMILL_EGRESS_ALLOWLIST="${AGENTMILL_EGRESS_ALLOWLIST:-}"
AGENTMILL_EGRESS_PROXY_PORT="${AGENTMILL_EGRESS_PROXY_PORT:-18080}"
AGENTMILL_CLAUDE_COMMAND="${AGENTMILL_CLAUDE_COMMAND:-claude}"
AGENTMILL_OPENCODE_COMMAND="${AGENTMILL_OPENCODE_COMMAND:-opencode}"
AGENTMILL_OPENCODE_REQUIRE_AUTH="${AGENTMILL_OPENCODE_REQUIRE_AUTH:-true}"
AGENTMILL_CODEX_COMMAND="${AGENTMILL_CODEX_COMMAND:-codex}"
AGENTMILL_CODEX_REQUIRE_AUTH="${AGENTMILL_CODEX_REQUIRE_AUTH:-true}"
AGENTMILL_CODEX_DEFAULT_MODEL="${AGENTMILL_CODEX_DEFAULT_MODEL:-gpt-5.3-codex}"
AGENTMILL_CODEX_SANDBOX="${AGENTMILL_CODEX_SANDBOX:-}"
AGENTMILL_CODEX_APPROVAL_POLICY="${AGENTMILL_CODEX_APPROVAL_POLICY:-}"
AGENTMILL_HOST_CODEX_HOME="${AGENTMILL_HOST_CODEX_HOME:-$HOME/.host-codex}"
AGENTMILL_QWEN_COMMAND="${AGENTMILL_QWEN_COMMAND:-qwen}"
AGENTMILL_QWEN_REQUIRE_AUTH="${AGENTMILL_QWEN_REQUIRE_AUTH:-true}"
AGENTMILL_QWEN_OUTPUT_FORMAT="${AGENTMILL_QWEN_OUTPUT_FORMAT:-stream-json}"
AGENTMILL_QWEN_INCLUDE_PARTIAL_MESSAGES="${AGENTMILL_QWEN_INCLUDE_PARTIAL_MESSAGES:-false}"
AGENTMILL_QWEN_DEFAULT_MODEL="${AGENTMILL_QWEN_DEFAULT_MODEL:-qwen3-coder-plus}"
AGENTMILL_QWEN_SANDBOX="${AGENTMILL_QWEN_SANDBOX:-}"
AGENTMILL_GEMINI_COMMAND="${AGENTMILL_GEMINI_COMMAND:-gemini}"
AGENTMILL_GEMINI_REQUIRE_AUTH="${AGENTMILL_GEMINI_REQUIRE_AUTH:-true}"
AGENTMILL_GEMINI_OUTPUT_FORMAT="${AGENTMILL_GEMINI_OUTPUT_FORMAT:-json}"
AGENTMILL_GEMINI_DEFAULT_MODEL="${AGENTMILL_GEMINI_DEFAULT_MODEL:-gemini-2.5-flash}"
AGENTMILL_GEMINI_SANDBOX="${AGENTMILL_GEMINI_SANDBOX:-}"
AGENTMILL_CLIENT_HOME_ROOT="${AGENTMILL_CLIENT_HOME_ROOT:-$HOME/.agentmill/clients}"
AGENTMILL_CLIENT_HOME="${AGENTMILL_CLIENT_HOME:-}"
AGENTMILL_FAKE_CLIENT_EXIT_CODE="${AGENTMILL_FAKE_CLIENT_EXIT_CODE:-0}"
AGENTMILL_FAKE_CLIENT_TOUCH_DONE="${AGENTMILL_FAKE_CLIENT_TOUCH_DONE:-true}"
AGENTMILL_FAKE_CLIENT_WRITE_FILE="${AGENTMILL_FAKE_CLIENT_WRITE_FILE:-}"
AGENTMILL_FAKE_CLIENT_WRITE_TEXT="${AGENTMILL_FAKE_CLIENT_WRITE_TEXT:-fake client output}"
AGENTMILL_FAKE_CLIENT_EMIT_TOOL_EVENT="${AGENTMILL_FAKE_CLIENT_EMIT_TOOL_EVENT:-true}"
AGENTMILL_SETUP_CLAUDE_CONFIG="${AGENTMILL_SETUP_CLAUDE_CONFIG:-/setup-claude-config.sh}"
AGENTMILL_SETUP_REPO_ENV="${AGENTMILL_SETUP_REPO_ENV:-/setup-repo-env.sh}"

log() {
    local id="${AGENT_ID:-tui}"
    local msg body
    if declare -F redact_text >/dev/null; then
        body="$(redact_text "$*")"
    else
        body="$*"
    fi
    msg="[agentmill:${id} $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $body"
    echo "$msg"
    echo "$msg" >> "$LOG_DIR/agent-${id}.log"
}

# Greppable error/warn helpers (clax convention): one line, literal ERROR/WARN
# token + reason. Use these so `grep -E '^.*ERROR' logs/agent-*.log` finds every
# real failure regardless of phrasing.
log_error() { log "ERROR $*"; }
log_warn()  { log "WARN $*";  }

redact_text() {
    local text="$*"
    local secret
    for secret in "${ANTHROPIC_API_KEY:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-}" "${GITHUB_TOKEN:-}" "${GH_TOKEN:-}"; do
        [[ -n "$secret" ]] && text="${text//"$secret"/[REDACTED]}"
    done
    printf '%s' "$text" | sed -E \
        -e 's/sk-ant-[A-Za-z0-9._-]{10,}/[REDACTED_ANTHROPIC_KEY]/g' \
        -e 's/sk-[A-Za-z0-9._-]{20,}/[REDACTED_API_KEY]/g' \
        -e 's/gh[pousr]_[A-Za-z0-9_]{20,}/[REDACTED_GITHUB_TOKEN]/g' \
        -e 's/xox[baprs]-[A-Za-z0-9-]{20,}/[REDACTED_SLACK_TOKEN]/g' \
        -e 's/Bearer[[:space:]]+[A-Za-z0-9._~+\/=-]{20,}/Bearer [REDACTED_TOKEN]/g' \
        -e 's/(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|GITHUB_TOKEN|GH_TOKEN)=([^[:space:]]+)/\1=[REDACTED]/g'
}

redacted_tee() {
    local output_file="$1" line redacted
    : > "$output_file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        redacted="$(redact_text "$line")"
        printf '%s\n' "$redacted"
        printf '%s\n' "$redacted" >> "$output_file"
    done
}

json_escape() {
    local text
    text="$(redact_text "$*")"
    printf '%s' "$text" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

json_value() {
    local value="$1"
    case "$value" in
        true|false|null) printf '%s' "$value" ;;
        *)
            if [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
                printf '%s' "$value"
            else
                json_escape "$value"
            fi
            ;;
    esac
}

event_payload() {
    local first=true pair key value
    printf '{'
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [[ "$first" == true ]] || printf ','
        first=false
        printf '%s:%s' "$(json_escape "$key")" "$(json_value "$value")"
    done
    printf '}'
}

event_emit() {
    local type="$1" payload="${2:-}"
    local iter="${ITERATION:-0}" agent="${AGENT_ID:-tui}" profile="${AGENTMILL_PROFILE_LEVEL:-trusted}"
    local timestamp line lock
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    [[ -n "$payload" && "$payload" =~ ^[[:space:]]*\{ ]] || payload="{}"
    mkdir -p "$(dirname "$EVENT_LOG")"
    line="{\"version\":1,\"timestamp\":$(json_escape "$timestamp"),\"run_id\":$(json_escape "$AGENTMILL_RUN_ID"),\"agent_id\":$(json_escape "$agent"),\"profile\":$(json_escape "$profile"),\"iteration\":$(json_value "$iter"),\"type\":$(json_escape "$type"),\"payload\":$payload}"
    lock="${EVENT_LOG}.lock"
    if _lock_acquire "$lock" 5; then
        printf '%s\n' "$line" >> "$EVENT_LOG"
        _lock_release "$lock"
    else
        log_warn "events log lock timeout for $type"
    fi
}

event_emit_kv() {
    local type="$1"
    shift || true
    event_emit "$type" "$(event_payload "$@")"
}

emit_iteration_failed() {
    local reason="${1:-unknown}" status="${2:-error}" description="${3:-}" exit_code="${4:-}" files_changed="${5:-}" commits="${6:-}"
    event_emit_kv iteration.failed \
        reason="$reason" \
        status="$status" \
        description="$description" \
        exit_code="$exit_code" \
        files_changed="$files_changed" \
        commits="$commits"
}

agentmill_truthy() {
    case "${1:-}" in
        true|TRUE|True|1|yes|YES|Yes|on|ON|On) return 0 ;;
    esac
    return 1
}

is_readonly_clone_mode() {
    case "${AGENTMILL_WORKSPACE_MODE:-direct}" in
        readonly-clone|clone-ro|ro-clone) return 0 ;;
    esac
    return 1
}

hook_payload() {
    event_payload \
        run_id="$AGENTMILL_RUN_ID" \
        agent_id="${AGENT_ID:-tui}" \
        role="${AGENTMILL_ROLE:-}" \
        profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" \
        iteration="${ITERATION:-0}" \
        repo_dir="${REPO_DIR:-}" \
        branch="$(git branch --show-current 2>/dev/null || true)" \
        "$@"
}

parse_hook_decision() {
    local output_file="$1"
    python3 - "$output_file" <<'PY'
import json
import os
import sys

text = open(sys.argv[1], encoding="utf-8").read().strip()
if not text:
    print("allow")
    print("")
    print("")
    raise SystemExit(0)

try:
    data = json.loads(text)
except json.JSONDecodeError as exc:
    print("deny")
    print(f"invalid hook JSON: {exc}")
    raise SystemExit(2)

decision = data.get("decision", "allow")
reason = " ".join(str(data.get("reason", "")).split())
additional_context = data.get("additional_context", "")
if additional_context is None:
    additional_context = ""
elif not isinstance(additional_context, str):
    additional_context = json.dumps(additional_context, sort_keys=True)

try:
    max_bytes = int(os.environ.get("AGENTMILL_HOOK_CONTEXT_MAX_BYTES", "16384"))
except ValueError:
    max_bytes = 16384
max_bytes = max(max_bytes, 0)
encoded_context = additional_context.encode("utf-8")
if max_bytes and len(encoded_context) > max_bytes:
    additional_context = encoded_context[:max_bytes].decode("utf-8", errors="ignore")

if decision not in {"allow", "deny", "defer"}:
    print("deny")
    print(f"invalid hook decision: {decision}")
    print("")
    raise SystemExit(2)

print(decision)
print(reason)
print(additional_context)
PY
}

extract_hook_prompt_file() {
    local output_file="$1"
    python3 - "$output_file" <<'PY'
import json
import os
import pathlib
import sys

text = open(sys.argv[1], encoding="utf-8").read().strip()
if not text:
    raise SystemExit(0)

try:
    data = json.loads(text)
except json.JSONDecodeError:
    raise SystemExit(0)

prompt_file = data.get("prompt_file", "")
if prompt_file in {"", None}:
    raise SystemExit(0)
if not isinstance(prompt_file, str):
    print("prompt_file must be a string", file=sys.stderr)
    raise SystemExit(2)
if "\x00" in prompt_file:
    print("prompt_file must not contain NUL bytes", file=sys.stderr)
    raise SystemExit(2)

root = os.environ.get("AGENTMILL_PROMPT_ROOT", "/prompts").rstrip("/") or "/prompts"
if not root.startswith("/"):
    print("AGENTMILL_PROMPT_ROOT must be absolute", file=sys.stderr)
    raise SystemExit(2)
path = pathlib.PurePosixPath(prompt_file)
if not path.is_absolute():
    print("prompt_file must be absolute", file=sys.stderr)
    raise SystemExit(2)
if ".." in path.parts:
    print("prompt_file must not contain '..'", file=sys.stderr)
    raise SystemExit(2)
if prompt_file != root and not prompt_file.startswith(root + "/"):
    print(f"prompt_file must be under {root}", file=sys.stderr)
    raise SystemExit(2)

print(prompt_file)
PY
}

prepend_hook_additional_context() {
    local prompt="${1:-}" context="${HOOK_LAST_ADDITIONAL_CONTEXT:-}"
    if [[ -z "$context" ]]; then
        printf '%s' "$prompt"
        return 0
    fi
    event_emit_kv hook.context_injected hook="${HOOK_LAST_NAME:-pre_iteration}" bytes="${#context}"
    printf '## Harness Additional Context\n\n%s\n\n%s' "$context" "$prompt"
}

apply_hook_prompt_file_update() {
    local updated="${HOOK_LAST_PROMPT_FILE:-}" previous="${PROMPT_FILE:-}"
    [[ -n "$updated" ]] || return 0
    if [[ ! -f "$updated" ]]; then
        HOOK_LAST_DECISION="deny"
        HOOK_LAST_REASON="hook prompt_file does not exist: $updated"
        log_error "$HOOK_LAST_REASON"
        event_emit_kv policy.denied reason=hook_prompt_file_missing prompt_file="$updated" hook="${HOOK_LAST_NAME:-pre_iteration}"
        return 1
    fi
    PROMPT_FILE="$updated"
    export PROMPT_FILE
    event_emit_kv hook.prompt_file_updated hook="${HOOK_LAST_NAME:-pre_iteration}" previous_prompt_file="$previous" prompt_file="$PROMPT_FILE"
}

hook_scope_component() {
    local value="${1:-}"
    printf '%s' "$value" | sed -E 's/[^A-Za-z0-9_.-]+/_/g'
}

run_hook_file() {
    local name="$1" hook_path="$2" payload="$3" hook_scope="${4:-global}"
    if [[ ! -e "$hook_path" ]]; then
        event_emit_kv hook.skipped hook="$name" reason=missing path="$hook_path"
        return 0
    fi
    if [[ ! -x "$hook_path" ]]; then
        HOOK_LAST_DECISION="deny"
        HOOK_LAST_REASON="hook exists but is not executable"
        log_error "Hook $name is not executable: $hook_path"
        event_emit_kv policy.denied reason=hook_not_executable hook="$name" path="$hook_path" scope="$hook_scope"
        return 1
    fi
    if ! is_nonnegative_int "$AGENTMILL_HOOK_TIMEOUT_SECONDS" || [[ "$AGENTMILL_HOOK_TIMEOUT_SECONDS" -eq 0 ]]; then
        HOOK_LAST_DECISION="deny"
        HOOK_LAST_REASON="invalid hook timeout"
        log_error "AGENTMILL_HOOK_TIMEOUT_SECONDS must be a positive integer"
        event_emit_kv policy.denied reason=invalid_hook_timeout hook="$name" timeout="$AGENTMILL_HOOK_TIMEOUT_SECONDS" scope="$hook_scope"
        return 1
    fi

    local stdout_file stderr_file prompt_error_file rc parsed parse_rc prompt_rc decision reason additional_context prompt_file_update
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    prompt_error_file="$(mktemp)"
    event_emit_kv hook.started hook="$name" path="$hook_path" scope="$hook_scope" timeout_seconds="$AGENTMILL_HOOK_TIMEOUT_SECONDS"

    set +e
    if command -v timeout >/dev/null 2>&1; then
        printf '%s\n' "$payload" | timeout "$AGENTMILL_HOOK_TIMEOUT_SECONDS" "$hook_path" >"$stdout_file" 2>"$stderr_file"
    else
        printf '%s\n' "$payload" | "$hook_path" >"$stdout_file" 2>"$stderr_file"
    fi
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        HOOK_LAST_DECISION="deny"
        if [[ "$rc" -eq 124 ]]; then
            HOOK_LAST_REASON="hook timed out"
            log_error "Hook $name timed out after ${AGENTMILL_HOOK_TIMEOUT_SECONDS}s"
            event_emit_kv policy.denied reason=hook_timeout hook="$name" timeout_seconds="$AGENTMILL_HOOK_TIMEOUT_SECONDS" scope="$hook_scope"
        else
            HOOK_LAST_REASON="$(redact_text "$(cat "$stderr_file" 2>/dev/null || true)")"
            [[ -n "$HOOK_LAST_REASON" ]] || HOOK_LAST_REASON="hook exited with code $rc"
            log_error "Hook $name failed: $HOOK_LAST_REASON"
            event_emit_kv policy.denied reason=hook_failed hook="$name" exit_code="$rc" detail="$HOOK_LAST_REASON" scope="$hook_scope"
        fi
        rm -f "$stdout_file" "$stderr_file" "$prompt_error_file"
        return 1
    fi

    set +e
    parsed="$(parse_hook_decision "$stdout_file")"
    parse_rc=$?
    set -e
    decision="$(printf '%s\n' "$parsed" | sed -n '1p')"
    reason="$(printf '%s\n' "$parsed" | sed -n '2p')"
    additional_context="$(printf '%s\n' "$parsed" | sed -n '3,$p')"
    HOOK_LAST_DECISION="$decision"
    HOOK_LAST_REASON="$reason"
    HOOK_LAST_ADDITIONAL_CONTEXT="$additional_context"

    if [[ "$parse_rc" -ne 0 ]]; then
        log_error "Hook $name returned invalid decision JSON: $reason"
        event_emit_kv policy.denied reason=hook_invalid_json hook="$name" detail="$reason" scope="$hook_scope"
        rm -f "$stdout_file" "$stderr_file" "$prompt_error_file"
        return 1
    fi

    set +e
    prompt_file_update="$(extract_hook_prompt_file "$stdout_file" 2>"$prompt_error_file")"
    prompt_rc=$?
    set -e
    if [[ "$prompt_rc" -ne 0 ]]; then
        HOOK_LAST_DECISION="deny"
        HOOK_LAST_REASON="$(cat "$prompt_error_file" 2>/dev/null || true)"
        [[ -n "$HOOK_LAST_REASON" ]] || HOOK_LAST_REASON="invalid prompt_file"
        log_error "Hook $name returned invalid prompt_file: $HOOK_LAST_REASON"
        event_emit_kv policy.denied reason=hook_invalid_prompt_file hook="$name" detail="$HOOK_LAST_REASON" scope="$hook_scope"
        rm -f "$stdout_file" "$stderr_file" "$prompt_error_file"
        return 1
    fi
    HOOK_LAST_PROMPT_FILE="$prompt_file_update"
    rm -f "$stdout_file" "$stderr_file" "$prompt_error_file"

    case "$decision" in
        allow)
            event_emit_kv policy.allowed reason=hook_allow hook="$name" detail="$reason" scope="$hook_scope" path="$hook_path" additional_context_bytes="${#HOOK_LAST_ADDITIONAL_CONTEXT}" prompt_file="$HOOK_LAST_PROMPT_FILE"
            event_emit_kv hook.completed hook="$name" decision=allow reason="$reason" scope="$hook_scope" path="$hook_path" additional_context_bytes="${#HOOK_LAST_ADDITIONAL_CONTEXT}" prompt_file="$HOOK_LAST_PROMPT_FILE"
            return 0
            ;;
        deny)
            log_warn "Hook $name denied action: $reason"
            event_emit_kv policy.denied reason=hook_deny hook="$name" detail="$reason" scope="$hook_scope" path="$hook_path"
            event_emit_kv hook.completed hook="$name" decision=deny reason="$reason" scope="$hook_scope" path="$hook_path"
            return 1
            ;;
        defer)
            log_warn "Hook $name deferred action: $reason"
            event_emit_kv policy.deferred reason=hook_defer hook="$name" detail="$reason" scope="$hook_scope" path="$hook_path"
            event_emit_kv hook.completed hook="$name" decision=defer reason="$reason" scope="$hook_scope" path="$hook_path"
            return 2
            ;;
    esac
}

run_hook() {
    local name="$1" payload="${2:-}"
    [[ -n "$payload" ]] || payload="{}"
    HOOK_LAST_NAME="$name"
    HOOK_LAST_DECISION="allow"
    HOOK_LAST_REASON=""
    HOOK_LAST_ADDITIONAL_CONTEXT=""
    HOOK_LAST_PROMPT_FILE=""

    local role_component profile_component combined_context="" prompt_file_update="" found=false rc=0 i
    local -a hook_paths hook_scopes
    hook_paths+=("$AGENTMILL_HOOK_DIR/${name}.sh")
    hook_scopes+=("global")

    profile_component="$(hook_scope_component "${AGENTMILL_PROFILE_LEVEL:-trusted}")"
    if [[ -n "$profile_component" ]]; then
        hook_paths+=("$AGENTMILL_HOOK_DIR/profiles/${profile_component}/${name}.sh")
        hook_scopes+=("profile:${profile_component}")
    fi
    role_component="$(hook_scope_component "${AGENTMILL_ROLE:-}")"
    if [[ -n "$role_component" ]]; then
        hook_paths+=("$AGENTMILL_HOOK_DIR/roles/${role_component}/${name}.sh")
        hook_scopes+=("role:${role_component}")
    fi

    for i in "${!hook_paths[@]}"; do
        [[ -e "${hook_paths[$i]}" ]] || continue
        found=true
        set +e
        run_hook_file "$name" "${hook_paths[$i]}" "$payload" "${hook_scopes[$i]}"
        rc=$?
        set -e
        if [[ "$rc" -ne 0 ]]; then
            return "$rc"
        fi
        if [[ -n "$HOOK_LAST_ADDITIONAL_CONTEXT" ]]; then
            if [[ -n "$combined_context" ]]; then
                combined_context="${combined_context}"$'\n\n'"${HOOK_LAST_ADDITIONAL_CONTEXT}"
            else
                combined_context="$HOOK_LAST_ADDITIONAL_CONTEXT"
            fi
        fi
        if [[ -n "${HOOK_LAST_PROMPT_FILE:-}" ]]; then
            prompt_file_update="$HOOK_LAST_PROMPT_FILE"
        fi
    done

    HOOK_LAST_ADDITIONAL_CONTEXT="$combined_context"
    HOOK_LAST_PROMPT_FILE="$prompt_file_update"
    if [[ "$found" != true ]]; then
        event_emit_kv hook.skipped hook="$name" reason=missing path="$AGENTMILL_HOOK_DIR/${name}.sh" role="${AGENTMILL_ROLE:-}" profile="${AGENTMILL_PROFILE_LEVEL:-trusted}"
    fi
    return 0
}

high_risk_changes() {
    python3 <<'PY'
import re
import subprocess
import sys

PATTERNS = [
    ("ci-workflow", re.compile(r"^\.github/workflows/")),
    ("github-action", re.compile(r"^\.github/actions/")),
    ("git-hook", re.compile(r"^\.git/hooks/")),
    ("claude-config", re.compile(r"^\.claude/")),
    ("codex-config", re.compile(r"^\.codex/")),
    ("mcp-config", re.compile(r"(^|/)\.mcp\.json$")),
    ("env-file", re.compile(r"(^|/)\.env($|[.])")),
    ("package-script", re.compile(r"(^|/)package\.json$")),
    ("makefile", re.compile(r"(^|/)(Makefile|makefile|GNUmakefile)$")),
    ("container-config", re.compile(r"(^|/)(Dockerfile|docker-compose\.ya?ml)$")),
    ("deploy-script", re.compile(r"(^|/)(deploy|release|publish)([._-].*)?$|(^|/)(deploy|release|publish)/")),
    ("auth-config", re.compile(r"(^|/)(auth|credentials?|secrets?)([._/-].*)?$")),
]

def paths_from_status(line: str) -> list[str]:
    if not line:
        return []
    raw = line[3:] if len(line) > 3 else line
    if " -> " in raw:
        return [part.strip() for part in raw.split(" -> ", 1)]
    return [raw.strip()]

seen = set()
result = subprocess.run(
    ["git", "status", "--porcelain", "--untracked-files=all"],
    check=False,
    capture_output=True,
    text=True,
)
if result.returncode != 0:
    raise SystemExit(0)

for line in result.stdout.splitlines():
    for path in paths_from_status(line.rstrip("\n")):
        if not path or path in seen:
            continue
        seen.add(path)
        for category, pattern in PATTERNS:
            if pattern.search(path):
                print(f"{category}\t{path}")
                break
PY
}

enforce_high_risk_change_policy() {
    local profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" allow="${AGENTMILL_ALLOW_HIGH_RISK_CHANGES:-false}"
    local changes summary count categories
    changes="$(high_risk_changes)"
    if [[ -z "$changes" ]]; then
        event_emit_kv policy.allowed reason=high_risk_change_check result=none
        return 0
    fi

    summary="$(printf '%s\n' "$changes" | sed 's/\t/:/' | paste -sd ';' -)"
    categories="$(printf '%s\n' "$changes" | awk -F '\t' '{print $1}' | sort -u | paste -sd ',' -)"
    count="$(printf '%s\n' "$changes" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [[ "$profile" == "trusted" || "$allow" == "true" || "$allow" == "1" || "$allow" == "yes" ]]; then
        log_warn "High-risk changes allowed by profile/override: $summary"
        event_emit_kv policy.allowed reason=high_risk_changes_allowed profile="$profile" count="$count" categories="$categories" files="$summary"
        return 0
    fi

    log_error "High-risk changes require review before commit/push: $summary"
    event_emit_kv policy.denied reason=high_risk_changes profile="$profile" count="$count" categories="$categories" files="$summary"
    return 1
}

enforce_workspace_isolation() {
    local multi_agent="${1:-false}" profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" mode="${AGENTMILL_WORKSPACE_MODE:-direct}"

    if [[ "$profile" != "trusted" && "$multi_agent" != "true" ]]; then
        if is_readonly_clone_mode; then
            log_error "AGENTMILL_WORKSPACE_MODE=$mode requires /workspace/upstream clone mode"
            event_emit_kv policy.denied reason=readonly_clone_without_upstream profile="$profile" workspace_mode="$mode"
            return 1
        fi
        if agentmill_truthy "$AGENTMILL_ALLOW_DIRECT_HOST_REPO"; then
            log_warn "Direct writable host repo allowed by AGENTMILL_ALLOW_DIRECT_HOST_REPO for profile=$profile"
            event_emit_kv policy.allowed reason=direct_host_repo_override profile="$profile" workspace_mode="$mode"
            return 0
        fi
        log_error "standard/untrusted runs must use read-only clone mode or set AGENTMILL_ALLOW_DIRECT_HOST_REPO=true"
        event_emit_kv policy.denied reason=direct_host_repo_disallowed profile="$profile" workspace_mode="$mode"
        return 1
    fi

    if is_readonly_clone_mode && [[ "$multi_agent" != "true" ]]; then
        log_error "AGENTMILL_WORKSPACE_MODE=$mode requires /workspace/upstream clone mode"
        event_emit_kv policy.denied reason=readonly_clone_without_upstream profile="$profile" workspace_mode="$mode"
        return 1
    fi

    event_emit_kv policy.allowed reason=workspace_isolation profile="$profile" workspace_mode="$mode" multi_agent="$multi_agent"
}

enforce_write_root_policy() {
    local profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" roots="${AGENTMILL_WRITE_ROOTS:-}" output rc event_type
    if [[ "$profile" == "trusted" || -z "${roots//[[:space:],]/}" ]]; then
        event_emit_kv policy.allowed reason=write_roots_unrestricted profile="$profile"
        return 0
    fi
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    if output="$(python3 - "$roots" "$profile" <<'PY'
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path, PurePosixPath

roots_raw, profile = sys.argv[1:3]

def payload(**items):
    print(json.dumps(items, sort_keys=True, separators=(",", ":")))

def norm_rel(value: str) -> str | None:
    raw = value.replace(os.sep, "/").strip()
    if not raw or raw == ".":
        return "."
    path = PurePosixPath(raw)
    if path.is_absolute():
        return None
    parts = []
    for part in path.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            return None
        parts.append(part)
    return "/".join(parts) if parts else "."

def parse_roots(raw: str, repo: Path):
    roots = []
    invalid = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        if item.startswith("/"):
            try:
                item = str(Path(item).resolve().relative_to(repo))
            except (OSError, ValueError):
                invalid.append(item)
                continue
        root = norm_rel(item)
        if root is None:
            invalid.append(item)
            continue
        if root not in roots:
            roots.append(root)
    return roots, invalid

def status_paths() -> list[str]:
    raw = subprocess.check_output(["git", "status", "--porcelain=v1", "-z"])
    entries = [entry.decode("utf-8", "replace") for entry in raw.split(b"\0") if entry]
    paths = []
    index = 0
    while index < len(entries):
        entry = entries[index]
        index += 1
        if len(entry) < 4:
            continue
        code = entry[:2]
        path = entry[3:]
        paths.append(path)
        if "R" in code or "C" in code:
            if index < len(entries):
                paths.append(entries[index])
                index += 1
    out = []
    for path in paths:
        normalized = norm_rel(path)
        if normalized and normalized not in out:
            out.append(normalized)
    return out

def allowed(path: str, roots: list[str]) -> bool:
    if "." in roots:
        return True
    return any(path == root or path.startswith(root + "/") for root in roots)

repo = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()).resolve()
roots, invalid = parse_roots(roots_raw, repo)
if invalid:
    payload(
        reason="invalid_write_roots",
        profile=profile,
        invalid=",".join(invalid[:20]),
        write_roots=roots_raw,
    )
    raise SystemExit(1)
if not roots:
    payload(reason="write_roots_unrestricted", profile=profile)
    raise SystemExit(0)

paths = status_paths()
violations = [path for path in paths if not allowed(path, roots)]
if violations:
    payload(
        reason="write_root_violation",
        profile=profile,
        count=len(violations),
        files=",".join(violations[:20]),
        write_roots=",".join(roots),
    )
    raise SystemExit(1)

payload(
    reason="write_roots_enforced",
    profile=profile,
    changed_count=len(paths),
    write_roots=",".join(roots),
)
PY
)"; then
        event_type=policy.allowed
        rc=0
    else
        rc=$?
        event_type=policy.denied
    fi
    [[ -n "$output" ]] && event_emit "$event_type" "$output"
    return "$rc"
}

client_has_native_write_root_mediation() {
    case "${AGENTMILL_CLIENT:-claude}" in
        claude|codex) return 0 ;;
        *) return 1 ;;
    esac
}

write_root_filesystem_sandbox_enabled() {
    local profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" roots="${AGENTMILL_WRITE_ROOTS:-}" mode="${AGENTMILL_WRITE_ROOT_SANDBOX:-auto}"
    [[ "$profile" != "trusted" ]] || return 1
    [[ -n "${roots//[[:space:],]/}" ]] || return 1
    [[ "$mode" != "off" && "$mode" != "false" && "$mode" != "0" ]] || return 1
    client_has_native_write_root_mediation && return 1
    return 0
}

write_root_sandbox_paths() {
    python3 - "$REPO_DIR" "$AGENTMILL_WRITE_ROOTS" <<'PY'
from __future__ import annotations

import os
import sys
from pathlib import Path, PurePosixPath

repo = Path(sys.argv[1]).resolve()
roots_raw = sys.argv[2]

def norm_rel(value: str) -> str | None:
    raw = value.replace(os.sep, "/").strip()
    if not raw or raw == ".":
        return "."
    if raw.startswith("/"):
        try:
            raw = str(Path(raw).resolve().relative_to(repo)).replace(os.sep, "/")
        except (OSError, ValueError):
            return None
    path = PurePosixPath(raw)
    if path.is_absolute():
        return None
    parts = []
    for part in path.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            return None
        parts.append(part)
    return "/".join(parts) if parts else "."

roots: list[str] = []
invalid: list[str] = []
for item in roots_raw.split(","):
    item = item.strip()
    if not item:
        continue
    normalized = norm_rel(item)
    if normalized is None:
        invalid.append(item)
    elif normalized not in roots:
        roots.append(normalized)

if invalid:
    print(",".join(invalid), file=sys.stderr)
    raise SystemExit(2)
if "." in roots:
    print("__FULL_WORKSPACE__")
    raise SystemExit(0)
for root in roots:
    path = (repo / root).resolve()
    try:
        path.relative_to(repo)
    except ValueError:
        print(root, file=sys.stderr)
        raise SystemExit(2)
    print(path)
PY
}

path_is_under_or_equal() {
    python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys

child = Path(sys.argv[1]).resolve()
parent = Path(sys.argv[2]).resolve()
try:
    child.relative_to(parent)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

client_run_with_write_root_sandbox() {
    local cwd="$1"
    shift

    if ! write_root_filesystem_sandbox_enabled; then
        (cd "$cwd" && "$@")
        return "$?"
    fi

    local mode="${AGENTMILL_WRITE_ROOT_SANDBOX:-auto}" roots_output root root_count bwrap="${AGENTMILL_BWRAP_COMMAND:-bwrap}"
    if ! roots_output="$(write_root_sandbox_paths 2>&1)"; then
        log_error "Invalid AGENTMILL_WRITE_ROOTS for filesystem sandbox: $roots_output"
        event_emit_kv policy.denied reason=invalid_write_root_sandbox_roots profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" client="${AGENTMILL_CLIENT:-}" detail="$roots_output"
        return 1
    fi
    if [[ "$roots_output" == "__FULL_WORKSPACE__" || -z "$roots_output" ]]; then
        event_emit_kv policy.allowed reason=write_root_filesystem_sandbox_unrestricted profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" client="${AGENTMILL_CLIENT:-}" write_roots="${AGENTMILL_WRITE_ROOTS:-}"
        (cd "$cwd" && "$@")
        return "$?"
    fi
    if ! command -v "$bwrap" >/dev/null 2>&1; then
        log_error "AGENTMILL_WRITE_ROOTS for ${AGENTMILL_CLIENT:-client} requires bubblewrap filesystem sandbox; '$bwrap' not found"
        event_emit_kv policy.denied reason=write_root_filesystem_sandbox_missing profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" client="${AGENTMILL_CLIENT:-}" command="$bwrap"
        return 1
    fi
    if ! "$bwrap" --die-with-parent --ro-bind / / --chdir / -- true >/dev/null 2>&1; then
        log_error "Bubblewrap filesystem sandbox is unavailable; refusing unmediated ${AGENTMILL_CLIENT:-client} run with AGENTMILL_WRITE_ROOTS"
        event_emit_kv policy.denied reason=write_root_filesystem_sandbox_unavailable profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" client="${AGENTMILL_CLIENT:-}" command="$bwrap"
        return 1
    fi

    local -a bwrap_args=(--die-with-parent --ro-bind / /)
    [[ -d /dev ]] && bwrap_args+=(--dev-bind /dev /dev)
    [[ -d /proc ]] && bwrap_args+=(--proc /proc)
    [[ -d /tmp ]] && bwrap_args+=(--bind /tmp /tmp)
    if [[ -n "${HOME:-}" && -d "$HOME" ]] && ! path_is_under_or_equal "$HOME" "$REPO_DIR"; then
        bwrap_args+=(--bind "$HOME" "$HOME")
    fi
    bwrap_args+=(--ro-bind "$REPO_DIR" "$REPO_DIR")

    root_count=0
    while IFS= read -r root; do
        [[ -n "$root" ]] || continue
        [[ -e "$root" ]] || mkdir -p "$root"
        bwrap_args+=(--bind "$root" "$root")
        root_count=$((root_count + 1))
    done <<< "$roots_output"

    bwrap_args+=(--chdir "$cwd")
    event_emit_kv policy.allowed reason=write_root_filesystem_sandbox profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" client="${AGENTMILL_CLIENT:-}" roots="$root_count" command="$bwrap" mode="$mode"
    "$bwrap" "${bwrap_args[@]}" -- "$@"
}

export_readonly_clone_artifacts() {
    local iter="${1:-${ITERATION:-0}}" base="${UPSTREAM_HEAD:-}" head artifact_dir safe_run safe_agent untracked_list
    [[ -n "$base" ]] || base="$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1 || git rev-parse HEAD)"
    head="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    safe_run="${AGENTMILL_RUN_ID//[^A-Za-z0-9_.-]/_}"
    safe_agent="${AGENT_ID:-agent}"
    safe_agent="${safe_agent//[^A-Za-z0-9_.-]/_}"
    artifact_dir="$LOG_DIR/patches/${safe_run}-${safe_agent}-iter${iter}"
    mkdir -p "$artifact_dir"

    printf 'base=%s\nhead=%s\nbranch=%s\nrepo=%s\n' \
        "$base" "$head" "${AGENT_BRANCH:-}" "${REPO_DIR:-}" > "$artifact_dir/metadata.txt"
    git diff --stat "$base..HEAD" > "$artifact_dir/summary.txt" 2>/dev/null || true
    git format-patch --no-stat --output-directory "$artifact_dir" "$base..HEAD" >/dev/null 2>&1 || true
    git diff --binary > "$artifact_dir/uncommitted.patch" 2>/dev/null || true

    untracked_list="$artifact_dir/untracked-files.txt"
    git ls-files --others --exclude-standard > "$untracked_list" 2>/dev/null || true
    if [[ -s "$untracked_list" ]]; then
        tar -C "${REPO_DIR:-.}" -czf "$artifact_dir/untracked-files.tgz" -T "$untracked_list" 2>/dev/null || true
    fi

    log "Read-only clone artifacts written to $artifact_dir"
    event_emit_kv artifact.created kind=readonly_clone_patch path="$artifact_dir" base="$base" head="$head" branch="${AGENT_BRANCH:-}" iteration="$iter"
}

branch_is_protected() {
    local branch="$1" item
    local -a _protected_branches
    IFS=',' read -r -a _protected_branches <<< "${AGENTMILL_PROTECTED_BRANCHES:-}"
    for item in "${_protected_branches[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" && "$branch" == "$item" ]] && return 0
    done
    return 1
}

enforce_git_branch_policy() {
    local multi_agent="${1:-false}" profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" expected="${AGENT_BRANCH:-}" current protected=false
    current="$(git branch --show-current 2>/dev/null || true)"
    [[ -n "$current" ]] || current="DETACHED"

    if [[ -n "$expected" && "$current" != "$expected" ]]; then
        log_error "Current branch '$current' does not match AGENT_BRANCH '$expected'"
        event_emit_kv policy.denied reason=branch_mismatch profile="$profile" expected_branch="$expected" current_branch="$current"
        return 1
    fi

    if branch_is_protected "$current"; then
        protected=true
    fi
    if [[ "$profile" != "trusted" && "$protected" == true ]]; then
        if ! is_readonly_clone_mode; then
            if agentmill_truthy "$AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES"; then
                log_warn "Protected branch writes allowed by override: $current"
                event_emit_kv policy.allowed reason=protected_branch_override profile="$profile" branch="$current" multi_agent="$multi_agent"
                return 0
            fi
            log_error "standard/untrusted writes to protected branch '$current' require readonly-clone mode or AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES=true"
            event_emit_kv policy.denied reason=protected_branch_write profile="$profile" branch="$current" multi_agent="$multi_agent"
            return 1
        fi
    fi

    event_emit_kv policy.allowed reason=git_branch_policy profile="$profile" branch="$current" protected="$protected" multi_agent="$multi_agent"
}

valid_git_ref_name() {
    local ref="$1"
    [[ -n "$ref" ]] || return 1
    [[ "$ref" != -* ]] || return 1
    git check-ref-format --branch "$ref" >/dev/null 2>&1
}

git_origin_remote_url() {
    git remote get-url origin 2>/dev/null || true
}

git_remote_policy_result() {
    local remote_url="$1" allowlist="${AGENTMILL_GIT_REMOTE_ALLOWLIST:-}"
    python3 - "$remote_url" "$allowlist" <<'PY'
import re
import sys
from urllib.parse import urlparse


def clean_path(path: str) -> str:
    path = path.strip().strip("/")
    if path.endswith(".git"):
        path = path[:-4]
    return path.strip("/")


def normalize_network_remote(value: str):
    raw = value.strip()
    if not raw:
        return ("missing", "")

    parsed = urlparse(raw)
    if parsed.scheme:
        if parsed.scheme == "file":
            return ("local", parsed.path or raw)
        host = (parsed.hostname or "").lower()
        if not host:
            return ("local", raw)
        path = clean_path(parsed.path)
        return ("network", f"{host}/{path}" if path else host)

    # Git SSH scp-style remotes, e.g. git@github.com:org/repo.git.
    match = re.match(r"^(?:[^@\s/]+@)?([^:\s/]+):(.+)$", raw)
    if match and not raw.startswith(("./", "../", "/")):
        host = match.group(1).lower()
        path = clean_path(match.group(2))
        return ("network", f"{host}/{path}" if path else host)

    return ("local", raw)


def normalize_rule(rule: str):
    raw = rule.strip().strip("/")
    if not raw:
        return ""

    kind, normalized = normalize_network_remote(raw)
    if kind == "network":
        return normalized

    if "/" in raw and not raw.startswith(("./", "../", "/")):
        host, path = raw.split("/", 1)
        host = host.lower()
        path = clean_path(path)
        return f"{host}/{path}" if path else host

    if re.match(r"^[A-Za-z0-9.-]+(:[0-9]+)?$", raw):
        return raw.lower()

    return ""


def split_normalized(value: str):
    if "/" in value:
        host, path = value.split("/", 1)
    else:
        host, path = value, ""
    return host, path.strip("/")


def rule_matches(rule: str, remote: str) -> bool:
    rule_host, rule_path = split_normalized(rule)
    remote_host, remote_path = split_normalized(remote)
    if rule_host != remote_host:
        return False
    if not rule_path:
        return True
    return remote_path == rule_path or remote_path.startswith(f"{rule_path}/")


remote = sys.argv[1]
allowlist = [item.strip() for item in sys.argv[2].split(",") if item.strip()]
kind, normalized = normalize_network_remote(remote)
if kind != "network":
    print(f"{kind}\t{normalized}\t")
    raise SystemExit(0)

rules = [rule for item in allowlist if (rule := normalize_rule(item))]
for rule in rules:
    if rule_matches(rule, normalized):
        print(f"allowed\t{normalized}\t{rule}")
        raise SystemExit(0)

if rules:
    print(f"denied\t{normalized}\t")
else:
    print(f"network\t{normalized}\t")
PY
}

enforce_git_remote_egress_policy() {
    local action="$1" profile="$2" network="${AGENTMILL_NETWORK:-}" allowlist="${AGENTMILL_GIT_REMOTE_ALLOWLIST:-}"
    local remote_url remote_result remote_kind remote_name matched_rule

    remote_url="$(git_origin_remote_url)"
    if [[ -z "$remote_url" ]]; then
        if [[ "$network" == "deny" || "$network" == "allowlist" || -n "$allowlist" ]]; then
            log_error "Refusing $action because origin remote is required for git egress policy"
            event_emit_kv policy.denied reason=git_remote_missing action="$action" profile="$profile" network="$network"
            return 1
        fi
        return 0
    fi

    remote_result="$(git_remote_policy_result "$remote_url")"
    IFS=$'\t' read -r remote_kind remote_name matched_rule <<< "$remote_result"

    if [[ "$remote_kind" == "local" ]]; then
        event_emit_kv policy.allowed reason=git_remote_local action="$action" profile="$profile" remote="$remote_name"
        return 0
    fi

    if [[ "$network" == "deny" ]] && ! agentmill_truthy "$AGENTMILL_ALLOW_GIT_NETWORK"; then
        log_error "Refusing $action to network git remote '$remote_name' because AGENTMILL_NETWORK=deny"
        event_emit_kv policy.denied reason=git_network_denied action="$action" profile="$profile" remote="$remote_name" network="$network"
        return 1
    fi

    if [[ "$network" == "allowlist" && -z "$allowlist" ]]; then
        log_error "Refusing $action to network git remote '$remote_name' because AGENTMILL_NETWORK=allowlist requires AGENTMILL_GIT_REMOTE_ALLOWLIST"
        event_emit_kv policy.denied reason=git_remote_allowlist_missing action="$action" profile="$profile" remote="$remote_name" network="$network"
        return 1
    fi

    if [[ "$remote_kind" == "denied" ]]; then
        log_error "Refusing $action to git remote '$remote_name'; not in AGENTMILL_GIT_REMOTE_ALLOWLIST"
        event_emit_kv policy.denied reason=git_remote_not_allowlisted action="$action" profile="$profile" remote="$remote_name" network="$network"
        return 1
    fi

    if [[ "$remote_kind" == "allowed" ]]; then
        event_emit_kv policy.allowed reason=git_remote_allowlist action="$action" profile="$profile" remote="$remote_name" rule="$matched_rule" network="$network"
    fi
    return 0
}

enforce_git_remote_action_policy() {
    local action="${1:-push}" branch="${2:-${AGENT_BRANCH:-}}" profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" current protected=false
    current="$(git branch --show-current 2>/dev/null || true)"
    [[ -n "$current" ]] || current="DETACHED"

    case "$action" in
        push|fetch|rebase|force_push) ;;
        *)
            log_error "Unknown git remote action policy request: $action"
            event_emit_kv policy.denied reason=unknown_git_remote_action action="$action" profile="$profile" branch="$branch"
            return 1
            ;;
    esac

    if ! valid_git_ref_name "$branch"; then
        log_error "Refusing $action with invalid git branch ref '$branch'"
        event_emit_kv policy.denied reason=invalid_git_ref action="$action" profile="$profile" branch="$branch"
        return 1
    fi

    if [[ -n "${AGENT_BRANCH:-}" && "$branch" != "$AGENT_BRANCH" ]]; then
        log_error "Refusing $action to '$branch'; expected AGENT_BRANCH '$AGENT_BRANCH'"
        event_emit_kv policy.denied reason=git_action_branch_mismatch action="$action" profile="$profile" expected_branch="$AGENT_BRANCH" branch="$branch"
        return 1
    fi

    if [[ "$current" != "$branch" ]]; then
        log_error "Refusing $action to '$branch' while current branch is '$current'"
        event_emit_kv policy.denied reason=git_action_current_branch_mismatch action="$action" profile="$profile" current_branch="$current" branch="$branch"
        return 1
    fi

    if ! enforce_git_remote_egress_policy "$action" "$profile"; then
        return 1
    fi

    if [[ "$action" == "force_push" ]]; then
        if agentmill_truthy "$AGENTMILL_ALLOW_FORCE_PUSH"; then
            log_warn "Force-push allowed by AGENTMILL_ALLOW_FORCE_PUSH for branch '$branch'"
            event_emit_kv policy.allowed reason=force_push_override action="$action" profile="$profile" branch="$branch"
            return 0
        fi
        log_error "Force-push is disabled by default; set AGENTMILL_ALLOW_FORCE_PUSH=true to override"
        event_emit_kv policy.denied reason=force_push_disallowed action="$action" profile="$profile" branch="$branch"
        return 1
    fi

    if branch_is_protected "$branch"; then
        protected=true
    fi
    if [[ "$profile" != "trusted" && "$protected" == true ]]; then
        if ! is_readonly_clone_mode; then
            if agentmill_truthy "$AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES"; then
                log_warn "Protected branch $action allowed by override: $branch"
                event_emit_kv policy.allowed reason=protected_branch_remote_override action="$action" profile="$profile" branch="$branch"
                return 0
            fi
            log_error "standard/untrusted $action to protected branch '$branch' requires readonly-clone mode or AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES=true"
            event_emit_kv policy.denied reason=protected_branch_remote_action action="$action" profile="$profile" branch="$branch"
            return 1
        fi
    fi

    event_emit_kv policy.allowed reason=git_remote_action_policy action="$action" profile="$profile" branch="$branch" protected="$protected"
}

enforce_git_merge_policy() {
    local base_ref="${1:-}" profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" range merge_commits merge_count
    if [[ "$profile" == "trusted" ]]; then
        event_emit_kv policy.allowed reason=merge_commit_policy profile="$profile"
        return 0
    fi
    if agentmill_truthy "$AGENTMILL_ALLOW_MERGE_COMMITS"; then
        log_warn "Merge commits allowed by AGENTMILL_ALLOW_MERGE_COMMITS for profile=$profile"
        event_emit_kv policy.allowed reason=merge_commit_override profile="$profile"
        return 0
    fi
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    if [[ -n "$base_ref" ]] && git rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null; then
        range="${base_ref}..HEAD"
    else
        range="HEAD"
    fi
    merge_commits="$(git rev-list --merges --max-count=5 "$range" 2>/dev/null || true)"
    if [[ -z "$merge_commits" ]]; then
        event_emit_kv policy.allowed reason=merge_commit_policy profile="$profile" range="$range"
        return 0
    fi
    merge_count="$(printf '%s\n' "$merge_commits" | sed '/^$/d' | wc -l | tr -d ' ')"
    log_error "Merge commits are not allowed for profile=$profile; found $merge_count new merge commit(s)"
    event_emit_kv policy.denied reason=merge_commits_disallowed profile="$profile" range="$range" merge_count="$merge_count" sample="$(printf '%s\n' "$merge_commits" | head -n 1)"
    return 1
}

emit_mcp_manifest_snapshot() {
    local snapshot_file
    snapshot_file="$LOG_DIR/mcp-manifest-${AGENTMILL_RUN_ID//[^A-Za-z0-9_.-]/_}-${AGENT_ID:-agent}.json"
    local payload manifest_meta
    payload="$(python3 - "$snapshot_file" <<'PY'
import hashlib
import json
import os
import selectors
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

out = Path(sys.argv[1])
home = Path(os.environ.get("HOME", ""))

def load(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}

def digest(value) -> str:
    blob = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(blob).hexdigest()

def truthy(value: str, default: bool = False) -> bool:
    if value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}

def safe_float(value: str, default: float) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return default
    return result if result > 0 else default

def mcp_launch_metadata(cfg) -> dict:
    if not isinstance(cfg, dict):
        return {"transport": "unknown"}
    command = cfg.get("command")
    if isinstance(command, str) and command.strip():
        return {
            "transport": "stdio",
            "command": command.strip(),
            "command_path_kind": "absolute" if command.strip().startswith("/") else "path",
        }
    url = cfg.get("url") or cfg.get("serverUrl") or cfg.get("endpoint")
    if isinstance(url, str) and url.strip():
        parsed = urlparse(url.strip())
        metadata = {"transport": str(cfg.get("type") or "remote")}
        if parsed.scheme:
            metadata["url_scheme"] = parsed.scheme
        if parsed.hostname:
            metadata["url_host"] = parsed.hostname
        if parsed.port:
            metadata["url_port"] = parsed.port
        return metadata
    if cfg.get("type"):
        return {"transport": str(cfg.get("type"))}
    return {"transport": "unknown"}

def read_jsonrpc_response(proc, selector, wanted_id: int, deadline: float):
    while time.monotonic() < deadline:
        remaining = max(0.05, deadline - time.monotonic())
        events = selector.select(remaining)
        if not events:
            if proc.poll() is not None:
                raise RuntimeError("process_exited")
            continue
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                raise RuntimeError("process_exited")
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if payload.get("id") == wanted_id:
            return payload
    raise TimeoutError("timeout")

def send_jsonrpc(proc, payload: dict) -> None:
    proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    proc.stdin.flush()

def summarize_mcp_tools(tools) -> list[dict]:
    records = []
    if not isinstance(tools, list):
        return records
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        name = str(tool.get("name", "")).strip()
        if not name:
            continue
        schema = tool.get("inputSchema", tool.get("input_schema", {}))
        records.append(
            {
                "name": name,
                "description_hash": digest(str(tool.get("description", ""))),
                "input_schema_hash": digest(schema if isinstance(schema, (dict, list)) else str(schema)),
            }
        )
    return sorted(records, key=lambda item: item["name"])

def list_stdio_mcp_tools(cfg: dict, timeout: float) -> dict:
    if not isinstance(cfg, dict):
        return {"tool_snapshot_status": "unsupported_config"}
    command = cfg.get("command")
    if not isinstance(command, str) or not command.strip():
        return {"tool_snapshot_status": "unsupported_transport"}
    args = cfg.get("args", [])
    if args is None:
        args = []
    if not isinstance(args, list) or any(not isinstance(item, (str, int, float)) for item in args):
        return {"tool_snapshot_status": "unsupported_args"}
    argv = [command.strip(), *[str(item) for item in args]]
    env = os.environ.copy()
    cfg_env = cfg.get("env", {})
    if isinstance(cfg_env, dict):
        for key, value in cfg_env.items():
            if isinstance(key, str) and isinstance(value, (str, int, float)):
                env[key] = str(value)
    cwd = cfg.get("cwd") if isinstance(cfg.get("cwd"), str) else None
    proc = None
    try:
        proc = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        selector = selectors.DefaultSelector()
        selector.register(proc.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        send_jsonrpc(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "agentmill", "version": "0"},
                },
            },
        )
        init = read_jsonrpc_response(proc, selector, 1, deadline)
        if "error" in init:
            return {"tool_snapshot_status": "initialize_error"}
        send_jsonrpc(proc, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

        all_tools = []
        cursor = None
        for request_id in range(2, 12):
            params = {}
            if cursor:
                params["cursor"] = cursor
            send_jsonrpc(proc, {"jsonrpc": "2.0", "id": request_id, "method": "tools/list", "params": params})
            response = read_jsonrpc_response(proc, selector, request_id, deadline)
            if "error" in response:
                return {"tool_snapshot_status": "tools_list_error"}
            result = response.get("result", {})
            if not isinstance(result, dict):
                return {"tool_snapshot_status": "tools_list_invalid"}
            all_tools.extend(result.get("tools", []))
            cursor = result.get("nextCursor")
            if not cursor:
                break
        tools = summarize_mcp_tools(all_tools)
        return {
            "tool_snapshot_status": "ok",
            "tool_count": len(tools),
            "tool_manifest_hash": digest(tools),
            "tools": tools,
        }
    except FileNotFoundError:
        return {"tool_snapshot_status": "command_not_found"}
    except TimeoutError:
        return {"tool_snapshot_status": "timeout"}
    except Exception:
        return {"tool_snapshot_status": "snapshot_error"}
    finally:
        if proc is not None:
            try:
                proc.terminate()
                proc.wait(timeout=1)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass

allowlist = [item.strip() for item in os.environ.get("AGENTMILL_MCP_ALLOWLIST", "").split(",") if item.strip()]
allowset = set(allowlist)
profile = os.environ.get("AGENTMILL_PROFILE_LEVEL", "trusted")
tool_snapshot_enabled = truthy(os.environ.get("AGENTMILL_MCP_TOOL_SNAPSHOT", ""), True)
tool_snapshot_timeout = safe_float(os.environ.get("AGENTMILL_MCP_TOOL_SNAPSHOT_TIMEOUT_SECONDS", ""), 3.0)

def should_snapshot_tools(name: str, cfg) -> bool:
    if not tool_snapshot_enabled:
        return False
    if not isinstance(cfg, dict) or not cfg.get("command"):
        return False
    if profile == "trusted":
        return True
    return name in allowset

def mcp_server_record(name: str, source: str, cfg) -> dict:
    record = {"name": name, "source": source, "config_hash": digest(cfg)}
    record.update(mcp_launch_metadata(cfg))
    if should_snapshot_tools(name, cfg):
        record.update(list_stdio_mcp_tools(cfg, tool_snapshot_timeout))
    elif not tool_snapshot_enabled:
        record["tool_snapshot_status"] = "disabled"
    return record

claude = load(home / ".claude.json")
settings = load(home / ".claude" / "settings.json")
servers = []

for name, cfg in sorted(claude.get("mcpServers", {}).items()):
    servers.append(mcp_server_record(name, "claude.json:mcpServers", cfg))

for project_path, project in sorted(claude.get("projects", {}).items()):
    for name, cfg in sorted(project.get("mcpServers", {}).items()):
        servers.append(mcp_server_record(name, f"project:{project_path}:mcpServers", cfg))
    mcp_json_servers = load(Path(project_path) / ".mcp.json").get("mcpServers", {})
    for name in sorted(project.get("enabledMcpjsonServers", [])):
        cfg = mcp_json_servers.get(name, {})
        record = mcp_server_record(name, f"project:{project_path}:enabledMcpjsonServers", cfg)
        if not cfg:
            record["config_hash"] = ""
        servers.append(record)

manifest = {
    "version": 1,
    "run_id": os.environ.get("AGENTMILL_RUN_ID", ""),
    "agent_id": os.environ.get("AGENT_ID", ""),
    "role": os.environ.get("AGENTMILL_ROLE", ""),
    "profile": profile,
    "mcp_allowlist": allowlist,
    "enable_all_project_mcp": bool(settings.get("enableAllProjectMcpServers", False)),
    "tool_snapshot_enabled": tool_snapshot_enabled,
    "servers": servers,
}
manifest["manifest_hash"] = digest(manifest)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
print(json.dumps({
    "server_count": len(servers),
    "manifest_hash": manifest["manifest_hash"],
    "snapshot_file": str(out),
    "enable_all_project_mcp": manifest["enable_all_project_mcp"],
}, separators=(",", ":")))
PY
)"
    manifest_meta="$(python3 - "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(
    "\t".join(
        [
            str(payload.get("manifest_hash", "")),
            str(payload.get("snapshot_file", "")),
            str(payload.get("server_count", "")),
            str(payload.get("enable_all_project_mcp", False)).lower(),
        ]
    )
)
PY
)"
    IFS=$'\t' read -r MCP_MANIFEST_LAST_HASH MCP_MANIFEST_LAST_FILE MCP_MANIFEST_LAST_SERVER_COUNT MCP_MANIFEST_LAST_ENABLE_ALL_PROJECT_MCP <<< "$manifest_meta"
    event_emit "mcp.manifest" "$payload"
}

mcp_manifest_baseline_file() {
    printf '%s\n' "$LOG_DIR/mcp-manifest-baseline-${AGENTMILL_RUN_ID//[^A-Za-z0-9_.-]/_}-${AGENT_ID:-agent}.sha256"
}

enforce_mcp_manifest_stability() {
    local profile="${AGENTMILL_PROFILE_LEVEL:-trusted}" baseline_file baseline_hash
    emit_mcp_manifest_snapshot

    if [[ "$profile" == "trusted" ]]; then
        event_emit_kv policy.allowed reason=mcp_manifest_trusted manifest_hash="$MCP_MANIFEST_LAST_HASH" snapshot_file="$MCP_MANIFEST_LAST_FILE"
        return 0
    fi
    if ! agentmill_truthy "$AGENTMILL_MCP_MANIFEST_LOCK"; then
        event_emit_kv policy.allowed reason=mcp_manifest_lock_disabled profile="$profile" manifest_hash="$MCP_MANIFEST_LAST_HASH" snapshot_file="$MCP_MANIFEST_LAST_FILE"
        return 0
    fi

    baseline_file="$(mcp_manifest_baseline_file)"
    if [[ ! -f "$baseline_file" ]]; then
        mkdir -p "$(dirname "$baseline_file")"
        printf '%s\n' "$MCP_MANIFEST_LAST_HASH" > "$baseline_file"
        event_emit_kv policy.allowed reason=mcp_manifest_baseline profile="$profile" manifest_hash="$MCP_MANIFEST_LAST_HASH" snapshot_file="$MCP_MANIFEST_LAST_FILE" server_count="$MCP_MANIFEST_LAST_SERVER_COUNT"
        return 0
    fi

    baseline_hash="$(head -n 1 "$baseline_file" 2>/dev/null || true)"
    if [[ -z "$baseline_hash" ]]; then
        log_error "MCP manifest baseline is empty: $baseline_file"
        event_emit_kv policy.denied reason=mcp_manifest_baseline_empty profile="$profile" baseline_file="$baseline_file" manifest_hash="$MCP_MANIFEST_LAST_HASH" snapshot_file="$MCP_MANIFEST_LAST_FILE"
        return 1
    fi
    if [[ "$baseline_hash" != "$MCP_MANIFEST_LAST_HASH" ]]; then
        log_error "MCP manifest changed during run; refusing to continue for profile=$profile"
        event_emit_kv policy.denied reason=mcp_manifest_changed profile="$profile" baseline_hash="$baseline_hash" manifest_hash="$MCP_MANIFEST_LAST_HASH" snapshot_file="$MCP_MANIFEST_LAST_FILE" server_count="$MCP_MANIFEST_LAST_SERVER_COUNT"
        return 1
    fi

    event_emit_kv policy.allowed reason=mcp_manifest_stable profile="$profile" manifest_hash="$MCP_MANIFEST_LAST_HASH" snapshot_file="$MCP_MANIFEST_LAST_FILE" server_count="$MCP_MANIFEST_LAST_SERVER_COUNT"
}

is_nonnegative_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_signed_int() {
    [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

is_nonnegative_number() {
    [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

usage_budget_enabled() {
    local max_tokens="${MAX_TOTAL_TOKENS:-0}" max_usd="${MAX_TOTAL_USD:-0}"
    if is_nonnegative_int "$max_tokens" && [[ "$max_tokens" -gt 0 ]]; then
        return 0
    fi
    if is_nonnegative_number "$max_usd"; then
        python3 - "$max_usd" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) > 0 else 1)
PY
        return $?
    fi
    return 1
}

cost_estimator_configured() {
    python3 <<'PY'
import os

names = [
    "AGENTMILL_COST_INPUT_PER_MTOKENS",
    "AGENTMILL_COST_OUTPUT_PER_MTOKENS",
    "AGENTMILL_COST_CACHE_CREATION_PER_MTOKENS",
    "AGENTMILL_COST_CACHE_READ_PER_MTOKENS",
]
for name in names:
    try:
        if float(os.environ.get(name, "0") or 0) > 0:
            raise SystemExit(0)
    except ValueError:
        pass
raise SystemExit(1)
PY
}

ensure_usage_telemetry_for_budget() {
    if [[ "${AGENTMILL_CLIENT:-claude}" != "claude" ]]; then
        return 0
    fi
    if usage_budget_enabled; then
        case "${AGENTMILL_CLAUDE_OUTPUT_FORMAT:-text}" in
            text|"")
                AGENTMILL_CLAUDE_OUTPUT_FORMAT=stream-json
                export AGENTMILL_CLAUDE_OUTPUT_FORMAT
                log "Usage budget configured; using Claude stream-json output for token/cost telemetry"
                event_emit_kv policy.allowed reason=usage_budget_telemetry client=claude output_format="$AGENTMILL_CLAUDE_OUTPUT_FORMAT"
                ;;
        esac
    fi
}

validate_runtime_policy() {
    local mode="${1:-headless}" profile="${AGENTMILL_PROFILE_LEVEL:-trusted}"
    local max_iterations="${MAX_ITERATIONS:-0}" max_wall="${MAX_WALL_SECONDS:-0}" max_log="${MAX_LOG_BYTES:-0}" max_tokens="${MAX_TOTAL_TOKENS:-0}" max_usd="${MAX_TOTAL_USD:-0}" respawn="${RESPAWN:-false}"

    case "$profile" in
        trusted|standard|untrusted) ;;
        *)
            log_error "Unknown AGENTMILL_PROFILE_LEVEL '$profile' (expected trusted, standard, or untrusted)"
            event_emit_kv policy.denied reason=unknown_profile profile="$profile" mode="$mode"
            return 1
            ;;
    esac

    if ! is_nonnegative_int "$max_wall"; then
        log_error "MAX_WALL_SECONDS must be a non-negative integer (got '$max_wall')"
        event_emit_kv policy.denied reason=invalid_max_wall_seconds max_wall_seconds="$max_wall" mode="$mode"
        return 1
    fi

    if ! is_nonnegative_int "$max_iterations"; then
        log_error "MAX_ITERATIONS must be a non-negative integer (got '$max_iterations')"
        event_emit_kv policy.denied reason=invalid_max_iterations max_iterations="$max_iterations" mode="$mode"
        return 1
    fi

    if ! is_nonnegative_int "$max_log"; then
        log_error "MAX_LOG_BYTES must be a non-negative integer (got '$max_log')"
        event_emit_kv policy.denied reason=invalid_max_log_bytes max_log_bytes="$max_log" mode="$mode"
        return 1
    fi

    if ! is_nonnegative_int "$max_tokens"; then
        log_error "MAX_TOTAL_TOKENS must be a non-negative integer (got '$max_tokens')"
        event_emit_kv policy.denied reason=invalid_max_total_tokens max_total_tokens="$max_tokens" mode="$mode"
        return 1
    fi

    if ! is_nonnegative_number "$max_usd"; then
        log_error "MAX_TOTAL_USD must be a non-negative number (got '$max_usd')"
        event_emit_kv policy.denied reason=invalid_max_total_usd max_total_usd="$max_usd" mode="$mode"
        return 1
    fi

    if [[ "$profile" != "trusted" ]]; then
        if [[ "$mode" == "headless" && "$max_iterations" -eq 0 && "$max_wall" -eq 0 ]]; then
            log_error "standard/untrusted headless runs require MAX_ITERATIONS or MAX_WALL_SECONDS"
            event_emit_kv policy.denied reason=unbounded_headless_run profile="$profile" mode="$mode"
            return 1
        fi
        if [[ "$mode" == "tui" && "$respawn" == "true" && "$max_wall" -eq 0 ]]; then
            log_error "standard/untrusted respawn runs require MAX_WALL_SECONDS"
            event_emit_kv policy.denied reason=unbounded_respawn_run profile="$profile" mode="$mode"
            return 1
        fi
    fi

    event_emit_kv policy.allowed reason=runtime_policy profile="$profile" mode="$mode" max_iterations="$max_iterations" max_wall_seconds="$max_wall" max_log_bytes="$max_log" max_total_tokens="$max_tokens" max_total_usd="$max_usd"
}

log_bytes_used() {
    python3 - "$LOG_DIR" <<'PY'
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
total = 0
if root.exists():
    for path in root.rglob("*"):
        try:
            if path.is_file():
                total += path.stat().st_size
        except OSError:
            pass
print(total)
PY
}

enforce_log_budget() {
    local max_log="${MAX_LOG_BYTES:-0}" used
    if ! is_nonnegative_int "$max_log"; then
        log_error "MAX_LOG_BYTES must be a non-negative integer (got '$max_log')"
        event_emit_kv policy.denied reason=invalid_max_log_bytes max_log_bytes="$max_log"
        return 1
    fi
    [[ "$max_log" -gt 0 ]] || return 0

    used="$(log_bytes_used)"
    if [[ "$used" -ge "$max_log" ]]; then
        log_error "Log budget exhausted: ${used}/${max_log} bytes"
        event_emit_kv budget.exhausted budget=log_bytes used_bytes="$used" max_log_bytes="$max_log"
        return 1
    fi
    return 0
}

extract_usage_from_session() {
    local session_log="$1"
    python3 - "$session_log" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    text = path.read_text(encoding="utf-8", errors="ignore")
except OSError:
    raise SystemExit(1)

INPUT_KEYS = {"input_tokens", "prompt_tokens"}
OUTPUT_KEYS = {"output_tokens", "completion_tokens", "reasoning_output_tokens"}
CACHE_CREATE_KEYS = {"cache_creation_input_tokens", "cache_creation_tokens", "cache_write_input_tokens"}
CACHE_READ_KEYS = {"cache_read_input_tokens", "cache_read_tokens", "cached_input_tokens"}
TOTAL_KEYS = {"total_tokens"}
COST_KEYS = {"cost_usd", "total_cost_usd", "estimated_cost_usd", "usd"}
GEMINI_TOKEN_KEYS = {"prompt", "candidates", "cached", "thoughts", "tool", "total"}

def as_number(value):
    if isinstance(value, bool) or value is None:
        return 0.0
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0

def add_from_dict(target, data):
    if not isinstance(data, dict):
        return False
    matched = False
    for key, value in data.items():
        if key in INPUT_KEYS:
            target["input_tokens"] += int(as_number(value)); matched = True
        elif key in OUTPUT_KEYS:
            target["output_tokens"] += int(as_number(value)); matched = True
        elif key in CACHE_CREATE_KEYS:
            target["cache_creation_input_tokens"] += int(as_number(value)); matched = True
        elif key in CACHE_READ_KEYS:
            target["cache_read_input_tokens"] += int(as_number(value)); matched = True
        elif key in TOTAL_KEYS:
            target["reported_total_tokens"] += int(as_number(value)); matched = True
        elif key in COST_KEYS:
            target["cost_usd"] += as_number(value); matched = True
    return matched

def estimate_cost_usd(totals):
    if totals["cost_usd"] > 0:
        return totals["cost_usd"]

    def rate(name):
        try:
            return float(os.environ.get(name, "0") or 0)
        except ValueError:
            return 0.0

    return (
        totals["input_tokens"] * rate("AGENTMILL_COST_INPUT_PER_MTOKENS")
        + totals["output_tokens"] * rate("AGENTMILL_COST_OUTPUT_PER_MTOKENS")
        + totals["cache_creation_input_tokens"] * rate("AGENTMILL_COST_CACHE_CREATION_PER_MTOKENS")
        + totals["cache_read_input_tokens"] * rate("AGENTMILL_COST_CACHE_READ_PER_MTOKENS")
    ) / 1_000_000

def add_gemini_tokens(target, data):
    if not isinstance(data, dict) or not (set(data) & GEMINI_TOKEN_KEYS):
        return False
    target["input_tokens"] += int(as_number(data.get("prompt")))
    target["output_tokens"] += int(as_number(data.get("candidates"))) + int(as_number(data.get("thoughts"))) + int(as_number(data.get("tool")))
    target["cache_read_input_tokens"] += int(as_number(data.get("cached")))
    target["reported_total_tokens"] += int(as_number(data.get("total")))
    return True

def walk(value, target):
    if isinstance(value, dict):
        usage = value.get("usage")
        if isinstance(usage, dict):
            add_from_dict(target, usage)
        if add_from_dict(target, value):
            return
        for key, child in value.items():
            if key == "usage" and isinstance(child, dict):
                continue
            if key == "tokens" and add_gemini_tokens(target, child):
                continue
            walk(child, target)
    elif isinstance(value, list):
        for child in value:
            walk(child, target)

objects = []
try:
    objects.append(json.loads(text))
except json.JSONDecodeError:
    for line in text.splitlines():
        line = line.strip()
        if not line or not line.startswith(("{", "[")):
            continue
        try:
            objects.append(json.loads(line))
        except json.JSONDecodeError:
            continue

totals = {
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0,
    "reported_total_tokens": 0,
    "cost_usd": 0.0,
}
for obj in objects:
    walk(obj, totals)

derived_total = (
    totals["input_tokens"]
    + totals["output_tokens"]
    + totals["cache_creation_input_tokens"]
    + totals["cache_read_input_tokens"]
)
total_tokens = totals["reported_total_tokens"] or derived_total
cost_usd = estimate_cost_usd(totals)
if total_tokens == 0 and cost_usd == 0:
    raise SystemExit(1)

payload = {
    "input_tokens": totals["input_tokens"],
    "output_tokens": totals["output_tokens"],
    "cache_creation_input_tokens": totals["cache_creation_input_tokens"],
    "cache_read_input_tokens": totals["cache_read_input_tokens"],
    "total_tokens": total_tokens,
    "cost_usd": round(cost_usd, 6),
}
print(json.dumps(payload, separators=(",", ":")))
PY
}

usage_json_field() {
    local usage_json="$1" key="$2"
    python3 - "$usage_json" "$key" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
value = data.get(sys.argv[2], "")
if isinstance(value, float):
    print(f"{value:.6f}".rstrip("0").rstrip(".") or "0")
else:
    print(value)
PY
}

usage_payload_with_session() {
    local usage_json="$1" session_log="$2"
    python3 - "$usage_json" "$session_log" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
data["session_log"] = sys.argv[2]
print(json.dumps(data, separators=(",", ":")))
PY
}

USAGE_LOG="${USAGE_LOG:-/workspace/logs/usage.tsv}"

usage_log_init() {
    mkdir -p "$(dirname "$USAGE_LOG")"
    [[ -f "$USAGE_LOG" ]] || printf 'iteration\tagent\ttimestamp\tinput_tokens\toutput_tokens\tcache_creation_input_tokens\tcache_read_input_tokens\ttotal_tokens\tcost_usd\n' > "$USAGE_LOG"
}

usage_log_append() {
    local iter="$1" agent="$2" usage_json="$3" lock="${USAGE_LOG}.lock"
    usage_log_init
    if _lock_acquire "$lock" 5; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(tsv_cell "$iter")" \
            "$(tsv_cell "$agent")" \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            "$(tsv_cell "$(usage_json_field "$usage_json" input_tokens)")" \
            "$(tsv_cell "$(usage_json_field "$usage_json" output_tokens)")" \
            "$(tsv_cell "$(usage_json_field "$usage_json" cache_creation_input_tokens)")" \
            "$(tsv_cell "$(usage_json_field "$usage_json" cache_read_input_tokens)")" \
            "$(tsv_cell "$(usage_json_field "$usage_json" total_tokens)")" \
            "$(tsv_cell "$(usage_json_field "$usage_json" cost_usd)")" >> "$USAGE_LOG"
        _lock_release "$lock"
    else
        log "WARN: usage log lock timeout"
    fi
}

record_usage_from_session() {
    local iter="$1" agent="$2" session_log="$3" usage_json payload
    USAGE_LAST_RECORDED=false
    USAGE_LAST_INPUT_TOKENS=""
    USAGE_LAST_OUTPUT_TOKENS=""
    USAGE_LAST_CACHE_CREATION_INPUT_TOKENS=""
    USAGE_LAST_CACHE_READ_INPUT_TOKENS=""
    USAGE_LAST_TOTAL_TOKENS=""
    USAGE_LAST_COST_USD=""

    set +e
    usage_json="$(extract_usage_from_session "$session_log")"
    local usage_rc=$?
    set -e
    [[ "$usage_rc" -eq 0 ]] || return 0

    USAGE_LAST_RECORDED=true
    USAGE_LAST_INPUT_TOKENS="$(usage_json_field "$usage_json" input_tokens)"
    USAGE_LAST_OUTPUT_TOKENS="$(usage_json_field "$usage_json" output_tokens)"
    USAGE_LAST_CACHE_CREATION_INPUT_TOKENS="$(usage_json_field "$usage_json" cache_creation_input_tokens)"
    USAGE_LAST_CACHE_READ_INPUT_TOKENS="$(usage_json_field "$usage_json" cache_read_input_tokens)"
    USAGE_LAST_TOTAL_TOKENS="$(usage_json_field "$usage_json" total_tokens)"
    USAGE_LAST_COST_USD="$(usage_json_field "$usage_json" cost_usd)"

    usage_log_append "$iter" "$agent" "$usage_json"
    payload="$(python3 - "$usage_json" "$session_log" "${AGENTMILL_CLIENT:-claude}" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
data["session_log"] = sys.argv[2]
data["client"] = sys.argv[3]
data["raw_event_type"] = "usage"
print(json.dumps(data, separators=(",", ":")))
PY
)"
    event_emit usage.recorded "$payload"
}

extract_tool_events_from_session() {
    local session_log="$1"
    python3 - "$session_log" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
client = os.environ.get("AGENTMILL_CLIENT", "claude")
try:
    text = path.read_text(encoding="utf-8", errors="ignore")
except OSError:
    raise SystemExit(0)

def load_objects(raw: str):
    try:
        obj = json.loads(raw)
        if isinstance(obj, list):
            return obj
        return [obj]
    except json.JSONDecodeError:
        objects = []
        for line in raw.splitlines():
            line = line.strip()
            if not line or not line.startswith(("{", "[")):
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, list):
                objects.extend(obj)
            else:
                objects.append(obj)
        return objects

def stable_hash(value) -> str:
    blob = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str).encode()
    return hashlib.sha256(blob).hexdigest()

def input_summary(value):
    summary = {}
    if isinstance(value, dict):
        summary["input_keys"] = sorted(str(key) for key in value.keys())[:50]
        summary["input_hash"] = stable_hash(value)
    elif value not in (None, ""):
        summary["input_type"] = type(value).__name__
        summary["input_hash"] = stable_hash(value)
    return summary

def mcp_parts(name: str):
    if name.startswith("mcp__"):
        parts = name.split("__", 2)
        if len(parts) == 3:
            return parts[1], parts[2]
    if name.startswith("mcp.") and name.count(".") >= 2:
        _, server, tool = name.split(".", 2)
        return server, tool
    return "", ""

def invocation_event(tool_id, name, provider, input_value=None, extra=None):
    server, tool = mcp_parts(name)
    payload = {
        "client": client,
        "provider": provider,
        "raw_event_type": provider,
        "tool_id": str(tool_id or ""),
        "tool_name": str(name or "unknown"),
    }
    payload.update(input_summary(input_value))
    if server:
        payload["mcp_server"] = server
        payload["mcp_tool"] = tool
    if extra:
        payload.update({k: v for k, v in extra.items() if v not in (None, "")})
    return ("mcp.tool.invoked" if server else "tool.invoked", payload)

def completion_event(tool_id, name, provider, result=None, extra=None):
    server, tool = mcp_parts(name)
    payload = {
        "client": client,
        "provider": provider,
        "raw_event_type": provider,
        "tool_id": str(tool_id or ""),
        "tool_name": str(name or "unknown"),
    }
    if isinstance(result, dict):
        if "is_error" in result:
            payload["is_error"] = bool(result.get("is_error"))
        if "status" in result:
            payload["status"] = str(result.get("status"))
        if "exit_code" in result:
            payload["exit_code"] = result.get("exit_code")
        if "content" in result:
            content = result.get("content")
            payload["content_items"] = len(content) if isinstance(content, list) else (1 if content not in (None, "") else 0)
    if server:
        payload["mcp_server"] = server
        payload["mcp_tool"] = tool
    if extra:
        payload.update({k: v for k, v in extra.items() if v not in (None, "")})
    return ("mcp.tool.completed" if server else "tool.completed", payload)

events = []
names_by_id = {}
seen = set()

def emit(event_type, payload):
    key = (event_type, payload.get("tool_id", ""), payload.get("tool_name", ""), payload.get("provider", ""), len(events))
    if key in seen:
        return
    seen.add(key)
    events.append((event_type, payload))

def handle_tool_use(data, provider):
    tool_id = data.get("id") or data.get("tool_use_id") or data.get("call_id")
    name = data.get("name") or data.get("tool_name") or data.get("function", {}).get("name") or "unknown"
    names_by_id[str(tool_id or "")] = str(name)
    input_value = data.get("input")
    if input_value is None:
        input_value = data.get("arguments")
    if input_value is None and isinstance(data.get("function"), dict):
        input_value = data["function"].get("arguments")
    event_type, payload = invocation_event(tool_id, name, provider, input_value)
    emit(event_type, payload)

def handle_tool_result(data, provider):
    tool_id = data.get("tool_use_id") or data.get("id") or data.get("call_id") or data.get("item_id")
    name = data.get("name") or data.get("tool_name") or names_by_id.get(str(tool_id or ""), "unknown")
    event_type, payload = completion_event(tool_id, name, provider, data)
    emit(event_type, payload)

def handle_item_event(data):
    event_name = str(data.get("type") or data.get("event") or "")
    item = data.get("item") if isinstance(data.get("item"), dict) else data
    item_type = str(item.get("type") or item.get("kind") or "")
    provider = "client_json"
    if event_name.startswith("item.") or event_name.startswith("mcp_") or item_type:
        provider = "codex_json" if "item." in event_name else "client_json"
    if event_name.startswith("turn."):
        return

    if event_name.endswith("started") or event_name in {"tool.started", "tool_call.started"}:
        if item_type in {"command_execution", "command", "shell"}:
            tool_id = item.get("id") or data.get("item_id")
            event_type, payload = invocation_event(tool_id, "Bash", provider, item.get("command") or item.get("cmd"), {"item_type": item_type})
            names_by_id[str(tool_id or "")] = "Bash"
            emit(event_type, payload)
        elif item_type in {"mcp_tool_call", "mcp_call"} or str(item.get("name", "")).startswith("mcp"):
            tool_id = item.get("id") or data.get("item_id")
            name = item.get("name") or item.get("tool_name") or "mcp.unknown.unknown"
            names_by_id[str(tool_id or "")] = str(name)
            event_type, payload = invocation_event(tool_id, name, provider, item.get("arguments") or item.get("input"), {"item_type": item_type})
            emit(event_type, payload)
    if event_name.endswith("completed") or event_name in {"tool.completed", "tool_call.completed"}:
        tool_id = item.get("id") or data.get("item_id")
        name = item.get("name") or item.get("tool_name") or names_by_id.get(str(tool_id or ""), "Bash" if item_type in {"command_execution", "command", "shell"} else "unknown")
        event_type, payload = completion_event(tool_id, name, provider, item, {"item_type": item_type})
        emit(event_type, payload)

def handle_stats_tools(data):
    stats = data.get("stats")
    if not isinstance(stats, dict):
        return
    tools = stats.get("tools")
    if not isinstance(tools, dict):
        return
    by_name = tools.get("byName")
    if not isinstance(by_name, dict):
        return
    provider = f"{client}_stats"
    for name, info in sorted(by_name.items()):
        if not isinstance(info, dict):
            info = {}
        count = info.get("count") or info.get("totalCalls") or 1
        fail = int(info.get("fail") or 0)
        tool_id = f"stats:{name}"
        extra = {
            "aggregate": True,
            "aggregate_count": count,
            "duration_ms": info.get("durationMs") or info.get("totalDurationMs"),
        }
        event_type, payload = invocation_event(tool_id, name, provider, {"aggregate_count": count}, extra)
        emit(event_type, payload)
        result = {"status": "failed" if fail else "completed", "is_error": bool(fail)}
        event_type, payload = completion_event(tool_id, name, provider, result, extra)
        emit(event_type, payload)

def handle_acp_event(data):
    message = data.get("message") if isinstance(data.get("message"), dict) else data
    if not isinstance(message, dict):
        return False
    if message.get("method") != "session/update":
        return False
    params = message.get("params")
    if not isinstance(params, dict):
        return False
    update = params.get("update")
    if not isinstance(update, dict):
        return False
    kind = str(update.get("sessionUpdate") or "")
    provider = "acp_json"
    if kind == "tool_call":
        tool_id = update.get("toolCallId")
        name = update.get("title") or update.get("kind") or "acp.tool"
        names_by_id[str(tool_id or "")] = str(name)
        event_type, payload = invocation_event(tool_id, name, provider, update, {"item_type": kind, "session_id": params.get("sessionId")})
        emit(event_type, payload)
    elif kind == "tool_call_update":
        tool_id = update.get("toolCallId")
        name = names_by_id.get(str(tool_id or ""), update.get("title") or update.get("kind") or "acp.tool")
        result = {"status": update.get("status") or "unknown", "content": update.get("content")}
        event_type, payload = completion_event(tool_id, name, provider, result, {"item_type": kind, "session_id": params.get("sessionId")})
        emit(event_type, payload)
    return kind in {"tool_call", "tool_call_update"}

def walk(value):
    if isinstance(value, dict):
        kind = str(value.get("type") or value.get("event") or "")
        if kind in {"tool_use", "tool_call", "function_call"}:
            handle_tool_use(value, f"{client}_json")
            return
        if kind in {"tool_result", "tool_response", "function_call_output"}:
            handle_tool_result(value, f"{client}_json")
            return
        handle_item_event(value)
        handle_stats_tools(value)
        if handle_acp_event(value):
            return
        for child in value.values():
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)

for obj in load_objects(text):
    walk(obj)

for event_type, payload in events:
    print(f"{event_type}\t{json.dumps(payload, sort_keys=True, separators=(',', ':'))}")
PY
}

record_tool_events_from_session() {
    local iter="$1" agent="$2" session_log="$3" event_type payload invoked=0 completed=0 mcp_invoked=0 mcp_completed=0
    TOOL_EVENTS_LAST_COUNT=0
    while IFS=$'\t' read -r event_type payload; do
        [[ -n "${event_type:-}" && -n "${payload:-}" ]] || continue
        event_emit "$event_type" "$payload"
        case "$event_type" in
            tool.invoked) invoked=$((invoked + 1)) ;;
            tool.completed) completed=$((completed + 1)) ;;
            mcp.tool.invoked) mcp_invoked=$((mcp_invoked + 1)) ;;
            mcp.tool.completed) mcp_completed=$((mcp_completed + 1)) ;;
        esac
        TOOL_EVENTS_LAST_COUNT=$((TOOL_EVENTS_LAST_COUNT + 1))
    done < <(extract_tool_events_from_session "$session_log")
    if [[ "$TOOL_EVENTS_LAST_COUNT" -gt 0 ]]; then
        event_emit_kv tool.summary session_log="$session_log" invoked="$invoked" completed="$completed" mcp_invoked="$mcp_invoked" mcp_completed="$mcp_completed" total="$TOOL_EVENTS_LAST_COUNT"
    fi
}

enforce_shell_command_policy_from_session() {
    local session_log="$1" policy output rc line payload had_errexit=false
    [[ -f "$session_log" ]] || return 0
    policy="$(client_policy_ir_json)"
    case "$-" in *e*) had_errexit=true ;; esac
    set +e
    output="$(python3 - "$session_log" "$policy" <<'PY'
import hashlib
import json
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
policy = json.loads(sys.argv[2])

try:
    text = path.read_text(encoding="utf-8", errors="ignore")
except OSError:
    raise SystemExit(0)

def load_objects(raw: str):
    try:
        obj = json.loads(raw)
        return obj if isinstance(obj, list) else [obj]
    except json.JSONDecodeError:
        objects = []
        for line in raw.splitlines():
            line = line.strip()
            if not line or not line.startswith(("{", "[")):
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, list):
                objects.extend(obj)
            else:
                objects.append(obj)
        return objects

def command_from_input(value):
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return value
        return command_from_input(parsed)
    if isinstance(value, dict):
        for key in ("command", "cmd", "script"):
            item = value.get(key)
            if isinstance(item, str) and item.strip():
                return item
    return ""

def tool_name(value):
    if not isinstance(value, dict):
        return ""
    name = value.get("name") or value.get("tool_name")
    if not name and isinstance(value.get("function"), dict):
        name = value["function"].get("name")
    return str(name or "")

def is_shell_tool(name: str) -> bool:
    lowered = name.lower()
    return lowered in {"bash", "shell"} or lowered.endswith(".bash")

def iter_commands(value):
    seen = set()

    def add(tool_id, name, command):
        command = str(command or "").strip()
        if not command:
            return
        key = (str(tool_id or ""), command)
        if key in seen:
            return
        seen.add(key)
        commands.append((str(tool_id or ""), str(name or "Bash"), command))

    commands = []

    def walk(item):
        if isinstance(item, dict):
            kind = str(item.get("type") or item.get("event") or item.get("kind") or "")
            name = tool_name(item)
            if kind in {"tool_use", "tool_call", "function_call"} and is_shell_tool(name):
                input_value = item.get("input")
                if input_value is None:
                    input_value = item.get("arguments")
                if input_value is None and isinstance(item.get("function"), dict):
                    input_value = item["function"].get("arguments")
                add(item.get("id") or item.get("tool_use_id") or item.get("call_id"), name, command_from_input(input_value))
                return
            nested = item.get("item") if isinstance(item.get("item"), dict) else item
            item_type = str(nested.get("type") or nested.get("kind") or "") if isinstance(nested, dict) else ""
            if item_type in {"command_execution", "command", "shell"}:
                add(nested.get("id") or item.get("item_id"), "Bash", nested.get("command") or nested.get("cmd"))
                return
            for child in item.values():
                walk(child)
        elif isinstance(item, list):
            for child in item:
                walk(child)

    for obj in load_objects(text):
        walk(obj)
    return commands

def argv(value: str):
    try:
        return shlex.split(value, posix=True)
    except ValueError:
        return value.split()

def normalize_pattern(pattern: str):
    raw = str(pattern or "").strip()
    if raw.startswith("Bash(") and raw.endswith(")"):
        raw = raw[5:-1].strip()
    if raw in {"", "*"}:
        return raw, ["*"]
    if raw.endswith(":*"):
        raw = raw[:-2].strip()
    elif raw.endswith("*"):
        raw = raw[:-1].strip()
    if raw.endswith(":"):
        raw = raw[:-1].strip()
    if not raw:
        return str(pattern), ["*"]
    return str(pattern), argv(raw)

def pattern_matches(pattern_tokens, command_tokens):
    if pattern_tokens == ["*"]:
        return True
    if not pattern_tokens or len(command_tokens) < len(pattern_tokens):
        return False
    return command_tokens[: len(pattern_tokens)] == pattern_tokens

shell_policy = policy.get("shell", {})
default = str(shell_policy.get("default", "allow"))
allow_patterns = [normalize_pattern(item) for item in shell_policy.get("allow", [])]
deny_patterns = [normalize_pattern(item) for item in shell_policy.get("deny", [])]
violations = []

for tool_id, name, command in iter_commands(text):
    tokens = argv(command)
    if not tokens:
        continue
    denied_by = next((raw for raw, parts in deny_patterns if pattern_matches(parts, tokens)), "")
    allowed_by = next((raw for raw, parts in allow_patterns if pattern_matches(parts, tokens)), "")
    reason = ""
    matched = ""
    if denied_by:
        reason = "denylist"
        matched = denied_by
    elif default in {"deny", "allowlist"} and not allowed_by:
        reason = "allowlist"
        matched = ",".join(raw for raw, _parts in allow_patterns) or "*"
    if reason:
        violations.append(
            {
                "reason": "shell_command_denied",
                "profile": policy.get("profile", ""),
                "client": policy.get("client", ""),
                "tool_id": tool_id,
                "tool_name": name,
                "argv0": tokens[0],
                "policy": reason,
                "matched_pattern": matched,
                "command_hash": hashlib.sha256(command.encode()).hexdigest(),
            }
        )

for violation in violations:
    print(json.dumps(violation, sort_keys=True, separators=(",", ":")))

raise SystemExit(1 if violations else 0)
PY
)"
    rc=$?
    if [[ "$had_errexit" == true ]]; then
        set -e
    else
        set +e
    fi
    if [[ -n "$output" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            payload="$(python3 - "$line" "$session_log" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload["session_log"] = sys.argv[2]
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
)"
            event_emit policy.denied "$payload"
        done <<< "$output"
    fi
    return "$rc"
}

enforce_tool_class_policy_from_session() {
    local session_log="$1" policy output rc line payload events_file had_errexit=false
    [[ -f "$session_log" ]] || return 0
    events_file="$(mktemp)"
    extract_tool_events_from_session "$session_log" > "$events_file"
    policy="$(client_policy_ir_json)"
    case "$-" in *e*) had_errexit=true ;; esac
    set +e
    output="$(python3 - "$events_file" "$policy" <<'PY'
import json
import re
import sys
from pathlib import Path

events_path = Path(sys.argv[1])
policy = json.loads(sys.argv[2])

WEB_TOOL_NAMES = {
    "webfetch",
    "websearch",
    "web_fetch",
    "web_search",
    "web_run",
    "google_web_search",
    "browser_search",
    "browser_open",
}
SUBAGENT_TOOL_NAMES = {
    "agent",
    "agent_run",
    "agents_run",
    "subagent",
    "subagent_run",
    "subagents_delegate",
    "task",
    "task_create",
    "taskcreate",
}


def norm_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", str(value or "").strip().lower()).strip("_")


def mcp_parts(name: str) -> tuple[str, str]:
    if name.startswith("mcp__"):
        parts = name.split("__", 2)
        if len(parts) == 3:
            return parts[1], parts[2]
    if name.startswith("mcp.") and name.count(".") >= 2:
        _, server, tool = name.split(".", 2)
        return server, tool
    return "", ""


def iter_invoked_events():
    try:
        lines = events_path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return
    for line in lines:
        if not line.strip() or "\t" not in line:
            continue
        event_type, raw_payload = line.split("\t", 1)
        if event_type not in {"tool.invoked", "mcp.tool.invoked"}:
            continue
        try:
            payload = json.loads(raw_payload)
        except json.JSONDecodeError:
            continue
        yield event_type, payload


def is_web_tool(name: str) -> bool:
    normalized = norm_name(name)
    return (
        normalized in WEB_TOOL_NAMES
        or normalized.startswith("web_")
        or normalized.endswith("_web_search")
        or normalized.endswith("_web_fetch")
    )


def is_subagent_tool(name: str) -> bool:
    normalized = norm_name(name)
    return normalized in SUBAGENT_TOOL_NAMES or normalized.startswith(("subagent_", "agent_run_"))


def mcp_allowed(server: str, tool: str, name: str, allowlist: list[str]) -> bool:
    candidates = {server, name}
    if server and tool:
        candidates.add(f"{server}.{tool}")
        candidates.add(f"mcp__{server}__{tool}")
    return any(item in candidates for item in allowlist)


def base_violation(reason: str, payload: dict, category: str, policy_kind: str) -> dict:
    return {
        "reason": reason,
        "source": "post_session_tool_policy",
        "profile": policy.get("profile", ""),
        "client": policy.get("client", ""),
        "tool_id": str(payload.get("tool_id") or ""),
        "tool_name": str(payload.get("tool_name") or ""),
        "category": category,
        "policy": policy_kind,
    }


violations = []
for event_type, payload in iter_invoked_events() or ():
    name = str(payload.get("tool_name") or "")
    server = str(payload.get("mcp_server") or "")
    tool = str(payload.get("mcp_tool") or "")
    if not server:
        server, tool = mcp_parts(name)

    if event_type == "mcp.tool.invoked" or server:
        mcp_policy = policy.get("mcp", {})
        default = str(mcp_policy.get("default", "allow"))
        allowlist = [str(item) for item in mcp_policy.get("allowlist", [])]
        if default == "deny" or (default == "allowlist" and not mcp_allowed(server, tool, name, allowlist)):
            detail = base_violation("mcp_tool_denied", payload, "mcp", default)
            detail["mcp_server"] = server
            detail["mcp_tool"] = tool
            if allowlist:
                detail["mcp_allowlist"] = ",".join(allowlist)
            violations.append(detail)
        continue

    if is_web_tool(name):
        web_policy = policy.get("web", {})
        default = str(web_policy.get("default", "allow"))
        if default == "deny":
            violations.append(base_violation("web_tool_denied", payload, "web", default))
        continue

    if is_subagent_tool(name):
        subagent_policy = policy.get("subagent", {})
        default = str(subagent_policy.get("default", "allow"))
        if default == "deny":
            violations.append(base_violation("subagent_denied", payload, "subagent", default))

for violation in violations:
    print(json.dumps(violation, sort_keys=True, separators=(",", ":")))

raise SystemExit(1 if violations else 0)
PY
)"
    rc=$?
    rm -f "$events_file"
    if [[ "$had_errexit" == true ]]; then
        set -e
    else
        set +e
    fi
    if [[ -n "$output" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            payload="$(python3 - "$line" "$session_log" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload["session_log"] = sys.argv[2]
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
)"
            event_emit policy.denied "$payload"
        done <<< "$output"
    fi
    return "$rc"
}

usage_totals() {
    python3 - "$USAGE_LOG" <<'PY'
import csv
import sys
from pathlib import Path

path = Path(sys.argv[1])
tokens = 0
usd = 0.0
rows = 0
if path.exists():
    for row in csv.DictReader(path.open(newline="", encoding="utf-8"), delimiter="\t"):
        rows += 1
        try:
            tokens += int(float(row.get("total_tokens") or 0))
        except ValueError:
            pass
        try:
            usd += float(row.get("cost_usd") or 0)
        except ValueError:
            pass
print(f"{tokens}\t{usd:.6f}\t{rows}")
PY
}

enforce_usage_budget() {
    local max_tokens="${MAX_TOTAL_TOKENS:-0}" max_usd="${MAX_TOTAL_USD:-0}" totals used_tokens used_usd used_rows rc=0
    USAGE_BUDGET_LAST_REASON=""

    if ! is_nonnegative_int "$max_tokens"; then
        log_error "MAX_TOTAL_TOKENS must be a non-negative integer (got '$max_tokens')"
        event_emit_kv policy.denied reason=invalid_max_total_tokens max_total_tokens="$max_tokens"
        return 1
    fi
    if ! is_nonnegative_number "$max_usd"; then
        log_error "MAX_TOTAL_USD must be a non-negative number (got '$max_usd')"
        event_emit_kv policy.denied reason=invalid_max_total_usd max_total_usd="$max_usd"
        return 1
    fi
    if [[ "$max_tokens" -eq 0 ]]; then
        if python3 - "$max_usd" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) == 0 else 1)
PY
        then
            return 0
        fi
    fi

    totals="$(usage_totals)"
    used_tokens="$(printf '%s\n' "$totals" | awk -F'\t' '{print $1}')"
    used_usd="$(printf '%s\n' "$totals" | awk -F'\t' '{print $2}')"
    used_rows="$(printf '%s\n' "$totals" | awk -F'\t' '{print $3}')"
    if usage_budget_enabled && [[ "${used_rows:-0}" -eq 0 ]]; then
        log_error "Usage budget configured but no usage telemetry has been recorded"
        event_emit_kv budget.exhausted budget=usage_telemetry reason=missing_usage_telemetry max_total_tokens="$max_tokens" max_total_usd="$max_usd"
        USAGE_BUDGET_LAST_REASON="missing_usage_telemetry"
        rc=1
    fi
    if [[ "$max_tokens" -gt 0 && "$used_tokens" -ge "$max_tokens" ]]; then
        log_error "Token budget exhausted: ${used_tokens}/${max_tokens} tokens"
        event_emit_kv budget.exhausted budget=total_tokens used_tokens="$used_tokens" max_total_tokens="$max_tokens"
        USAGE_BUDGET_LAST_REASON="max_total_tokens"
        rc=1
    fi
    if [[ "$used_tokens" -gt 0 ]] && ! cost_estimator_configured && python3 - "$used_usd" "$max_usd" <<'PY'
import sys
used = float(sys.argv[1])
limit = float(sys.argv[2])
raise SystemExit(0 if limit > 0 and used == 0 else 1)
PY
    then
        log_error "Cost budget configured but no cost telemetry or estimator rates are available"
        event_emit_kv budget.exhausted budget=total_usd reason=missing_cost_telemetry used_usd="$used_usd" max_total_usd="$max_usd"
        [[ -n "$USAGE_BUDGET_LAST_REASON" ]] || USAGE_BUDGET_LAST_REASON="missing_cost_telemetry"
        rc=1
    fi
    if python3 - "$used_usd" "$max_usd" <<'PY'
import sys
used = float(sys.argv[1])
limit = float(sys.argv[2])
raise SystemExit(0 if limit > 0 and used >= limit else 1)
PY
    then
        log_error "Cost budget exhausted: ${used_usd}/${max_usd} USD"
        event_emit_kv budget.exhausted budget=total_usd used_usd="$used_usd" max_total_usd="$max_usd"
        [[ -n "$USAGE_BUDGET_LAST_REASON" ]] || USAGE_BUDGET_LAST_REASON="max_total_usd"
        rc=1
    fi
    return "$rc"
}

apply_agent_env_overrides() {
    local base var
    for base in \
        AGENTMILL_ROLE \
        AGENTMILL_CLIENT \
        AGENTMILL_PROVIDER \
        AGENTMILL_CLIENT_TRANSPORT \
        AGENTMILL_ACP_PROMPT \
        AGENTMILL_PROFILE_LEVEL \
        AGENTMILL_COMPLETION_GATE \
        AGENTMILL_VERIFIER_COMMAND \
        AGENTMILL_CODER_OPEN_QUESTIONS_MAX \
        AGENTMILL_REFACTOR_LOC_TARGET \
        AGENTMILL_REFACTOR_LOC_TOLERANCE \
        AGENTMILL_REFACTOR_MAX_LOC_DELTA \
        AGENTMILL_RESEARCH_SATURATION_ITERATIONS \
        AGENTMILL_RESEARCH_OPEN_QUESTIONS_MAX \
        AGENTMILL_NETWORK \
        AGENTMILL_MCP_ALLOWLIST \
        AGENTMILL_MCP_MANIFEST_LOCK \
        AGENTMILL_MCP_TOOL_SNAPSHOT \
        AGENTMILL_MCP_TOOL_SNAPSHOT_TIMEOUT_SECONDS \
        AGENTMILL_SKILL_ALLOWLIST \
        AGENTMILL_FORWARD_HOST_MCP \
        AGENTMILL_FORWARD_HOST_TOOLS \
        AGENTMILL_FORWARD_HOST_HOOKS \
        AGENTMILL_FORWARD_HOST_ENV \
        AGENTMILL_FORWARD_HOST_EXTENSIONS \
        AGENTMILL_WORKSPACE_MODE \
        AGENTMILL_ALLOW_DIRECT_HOST_REPO \
        AGENTMILL_WRITE_ROOTS \
        AGENTMILL_WRITE_ROOT_SANDBOX \
        AGENTMILL_BWRAP_COMMAND \
        AGENTMILL_PRETOOL_POLICY_COMMAND \
        AGENTMILL_SHELL_ALLOWLIST \
        AGENTMILL_SHELL_DENYLIST \
        AGENTMILL_PROTECTED_BRANCHES \
        AGENTMILL_ALLOW_PROTECTED_BRANCH_WRITES \
        AGENTMILL_ALLOW_MERGE_COMMITS \
        AGENTMILL_GIT_REMOTE_ALLOWLIST \
        AGENTMILL_ALLOW_GIT_NETWORK \
        AGENTMILL_CLIENT_HOME_ROOT \
        AGENTMILL_CLIENT_HOME \
        AGENTMILL_OPENCODE_COMMAND \
        AGENTMILL_OPENCODE_REQUIRE_AUTH \
        AGENTMILL_CODEX_COMMAND \
        AGENTMILL_CODEX_REQUIRE_AUTH \
        AGENTMILL_CODEX_DEFAULT_MODEL \
        AGENTMILL_CODEX_SANDBOX \
        AGENTMILL_CODEX_APPROVAL_POLICY \
        AGENTMILL_HOST_CODEX_HOME \
        AGENTMILL_QWEN_COMMAND \
        AGENTMILL_QWEN_REQUIRE_AUTH \
        AGENTMILL_QWEN_OUTPUT_FORMAT \
        AGENTMILL_QWEN_INCLUDE_PARTIAL_MESSAGES \
        AGENTMILL_QWEN_DEFAULT_MODEL \
        AGENTMILL_QWEN_SANDBOX \
        AGENTMILL_GEMINI_COMMAND \
        AGENTMILL_GEMINI_REQUIRE_AUTH \
        AGENTMILL_GEMINI_OUTPUT_FORMAT \
        AGENTMILL_GEMINI_DEFAULT_MODEL \
        AGENTMILL_GEMINI_SANDBOX \
        AGENTMILL_COST_INPUT_PER_MTOKENS \
        AGENTMILL_COST_OUTPUT_PER_MTOKENS \
        AGENTMILL_COST_CACHE_CREATION_PER_MTOKENS \
        AGENTMILL_COST_CACHE_READ_PER_MTOKENS \
        MODEL \
        PROMPT_FILE \
        AGENT_BRANCH \
        MAX_ITERATIONS \
        LOOP_DELAY \
        MAX_WALL_SECONDS \
        MAX_LOG_BYTES \
        MAX_TOTAL_TOKENS \
        MAX_TOTAL_USD \
        AGENTMILL_CLAUDE_OUTPUT_FORMAT \
        AUTO_COMMIT \
        AUTO_RALPH_MAX_ITERATIONS; do
        var="${base}_${AGENT_ID:-1}"
        if [[ -n "${!var:-}" ]]; then
            export "$base=${!var}"
        fi
    done
}

# Resolve friendly model aliases (opus / sonnet / haiku / opus-4.7 / 4.7 / etc.)
# to fully-qualified Claude model IDs. The Claude CLI's own alias resolution
# trails the latest releases (e.g. bare `opus` resolved to 4.6 even after 4.7
# shipped), so we pin known aliases here. Unknown values pass through with a
# WARN so users can still point at model IDs we don't know about yet.
#
# Latest known model IDs as of 2026-04-28:
#   Opus 4.7    -> claude-opus-4-7
#   Sonnet 4.6  -> claude-sonnet-4-6
#   Haiku 4.5   -> claude-haiku-4-5-20251001
#
# Output goes to stdout (capture with command substitution); diagnostics go
# to stderr so they don't pollute the captured value.
resolve_model() {
    local input="${1:-sonnet}"
    local lower
    lower="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"

    # Already a fully-qualified model ID — passthrough.
    case "$lower" in
        claude-*)
            printf '%s' "$lower"
            return 0
            ;;
    esac

    # Family aliases (latest in each family) + explicit version aliases.
    case "$lower" in
        opus|opus-latest|opus-4.7|opus-4-7|opus-47|opus47|4.7|4-7)
            printf '%s' "claude-opus-4-7"
            return 0
            ;;
        sonnet|sonnet-latest|sonnet-4.6|sonnet-4-6|sonnet-46|sonnet46|4.6|4-6)
            printf '%s' "claude-sonnet-4-6"
            return 0
            ;;
        haiku|haiku-latest|haiku-4.5|haiku-4-5|haiku-45|haiku45|4.5|4-5)
            printf '%s' "claude-haiku-4-5-20251001"
            return 0
            ;;
    esac

    # Unknown — warn (to stderr so the caller's $(resolve_model) is clean)
    # and pass through. Lets users pin newly-released model IDs without
    # blocking on this function being updated.
    log_warn "Unknown MODEL alias '$input' — passing through to claude CLI as-is" >&2
    printf '%s' "$input"
}

# Log the installed Claude Code CLI version + warn loudly if it's older than
# the floor that knows about the requested MODEL. Stale CLIs ship with stale
# alias tables and capability metadata and silently downshift to older models
# — this turns the silent failure into a visible WARN.
#
# Refs: https://github.com/anthropics/claude-code/issues/50810
log_claude_version() {
    local model="${1:-}"
    local raw version major minor patch
    raw="$("$AGENTMILL_CLAUDE_COMMAND" --version 2>/dev/null | head -1 || true)"
    version="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -z "$version" ]]; then
        log_warn "Could not parse claude CLI version (output: '$raw')"
        return 0
    fi
    log "Claude Code CLI version: $version"

    # Floor checks — bump these as new model lines ship.
    # Format: "<model-substring>:<min-major>.<min-minor>.<min-patch>"
    local floor_pairs=(
        "claude-opus-4-7:2.1.111"
    )
    IFS='.' read -r major minor patch <<<"$version"
    for pair in "${floor_pairs[@]}"; do
        local m="${pair%%:*}"
        local floor="${pair##*:}"
        local fmajor fminor fpatch
        IFS='.' read -r fmajor fminor fpatch <<<"$floor"
        if [[ "$model" == *"$m"* ]]; then
            if (( major < fmajor )) \
                || ( (( major == fmajor )) && (( minor < fminor )) ) \
                || ( (( major == fmajor )) && (( minor == fminor )) && (( patch < fpatch )) ); then
                log_warn "claude CLI $version is older than the floor $floor for model '$m' — silent downshift likely. Bump CLAUDE_CODE_VERSION in Dockerfile and rebuild."
            fi
        fi
    done
}

require_auth() {
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        log "Auth: using ANTHROPIC_API_KEY"
    elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        log "Auth: using CLAUDE_CODE_OAUTH_TOKEN (subscription)"
        [[ -f "$HOME/.claude.json" ]] || printf '%s\n' '{"hasCompletedOnboarding":true}' > "$HOME/.claude.json"
    else
        log "ERROR: No auth. Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN."
        exit 1
    fi
}

merge_host_claude_config() { "$AGENTMILL_SETUP_CLAUDE_CONFIG"; }

client_select() {
    local requested="${1:-${AGENTMILL_CLIENT:-claude}}"
    if [[ -z "${AGENTMILL_CLIENT:-}" && -n "${AGENTMILL_PROVIDER:-}" ]]; then
        requested="$AGENTMILL_PROVIDER"
    fi
    case "$requested" in
        claude|codex|opencode|qwen|gemini|fake) ;;
        *)
            log_error "Unknown AGENTMILL_CLIENT '$requested' (expected claude, codex, opencode, qwen, gemini, fake)"
            exit 1
            ;;
    esac
    if [[ -n "${AGENTMILL_PROVIDER:-}" && -z "${AGENTMILL_CLIENT:-}" ]]; then
        log_warn "AGENTMILL_PROVIDER is deprecated for client selection; use AGENTMILL_CLIENT=$requested"
    fi
    export AGENTMILL_CLIENT="$requested"
}

client_resolve_model() {
    local input="${1:-sonnet}"
    case "${AGENTMILL_CLIENT:-claude}" in
        claude) resolve_model "$input" ;;
        codex)
            case "$input" in
                opus|sonnet|haiku) printf '%s' "$AGENTMILL_CODEX_DEFAULT_MODEL" ;;
                *) printf '%s' "$input" ;;
            esac
            ;;
        qwen)
            case "$input" in
                opus|sonnet|haiku) printf '%s' "$AGENTMILL_QWEN_DEFAULT_MODEL" ;;
                *) printf '%s' "$input" ;;
            esac
            ;;
        gemini)
            case "$input" in
                opus|sonnet|haiku) printf '%s' "$AGENTMILL_GEMINI_DEFAULT_MODEL" ;;
                *) printf '%s' "$input" ;;
            esac
            ;;
        fake) printf '%s' "$input" ;;
        *) printf '%s' "$input" ;;
    esac
}

client_version() {
    local model="${1:-}"
    case "${AGENTMILL_CLIENT:-claude}" in
        claude) log_claude_version "$model" ;;
        fake) log "Fake client selected" ;;
        opencode)
            local raw
            raw="$("$AGENTMILL_OPENCODE_COMMAND" --version 2>/dev/null | head -1 || true)"
            if [[ -n "$raw" ]]; then
                log "OpenCode CLI version: $raw"
            else
                log_warn "Could not read OpenCode CLI version"
            fi
            ;;
        codex)
            local raw
            raw="$("$AGENTMILL_CODEX_COMMAND" --version 2>/dev/null | head -1 || true)"
            if [[ -n "$raw" ]]; then
                log "Codex CLI version: $raw"
            else
                log_warn "Could not read Codex CLI version"
            fi
            ;;
        qwen)
            local raw
            raw="$("$AGENTMILL_QWEN_COMMAND" --version 2>/dev/null | head -1 || true)"
            if [[ -n "$raw" ]]; then
                log "Qwen Code CLI version: $raw"
            else
                log_warn "Could not read Qwen Code CLI version"
            fi
            ;;
        gemini)
            local raw
            raw="$("$AGENTMILL_GEMINI_COMMAND" --version 2>/dev/null | head -1 || true)"
            if [[ -n "$raw" ]]; then
                log "Gemini CLI version: $raw"
            else
                log_warn "Could not read Gemini CLI version"
            fi
            ;;
        *) log_warn "Client '${AGENTMILL_CLIENT}' is selected but not implemented yet" ;;
    esac
}

client_require_auth() {
    case "${AGENTMILL_CLIENT:-claude}" in
        claude) require_auth ;;
        fake) log "Auth: skipped for fake client" ;;
        opencode)
            if ! agentmill_truthy "$AGENTMILL_OPENCODE_REQUIRE_AUTH"; then
                log "Auth: OpenCode auth check disabled"
            elif [[ -n "${ANTHROPIC_API_KEY:-}" || -n "${OPENAI_API_KEY:-}" || -n "${GEMINI_API_KEY:-}" || -n "${GOOGLE_API_KEY:-}" || -n "${OPENROUTER_API_KEY:-}" || -n "${XAI_API_KEY:-}" || -n "${DEEPSEEK_API_KEY:-}" ]]; then
                log "Auth: using provider environment for OpenCode"
            elif [[ -f "${AGENTMILL_CLIENT_HOME:-$HOME/.local/share/opencode}/auth.json" || -f "$HOME/.local/share/opencode/auth.json" ]]; then
                log "Auth: using OpenCode auth file"
            else
                log "ERROR: No OpenCode auth. Set a provider API key, run opencode auth login, or set AGENTMILL_OPENCODE_REQUIRE_AUTH=false for tests."
                exit 1
            fi
            ;;
        codex)
            local selected_home
            selected_home="$(client_home_path codex)"
            if ! agentmill_truthy "$AGENTMILL_CODEX_REQUIRE_AUTH"; then
                log "Auth: Codex auth check disabled"
            elif [[ -n "${CODEX_API_KEY:-}" || -n "${OPENAI_API_KEY:-}" || -n "${CODEX_ACCESS_TOKEN:-}" ]]; then
                log "Auth: using Codex/OpenAI environment"
            elif [[ -f "$selected_home/.codex/auth.json" ]]; then
                log "Auth: using selected Codex auth file"
            elif [[ "${AGENTMILL_PROFILE_LEVEL:-trusted}" == "trusted" && -f "${AGENTMILL_HOST_CODEX_HOME:-}/auth.json" ]]; then
                log "Auth: using trusted mounted Codex auth file"
            elif [[ "${AGENTMILL_PROFILE_LEVEL:-trusted}" == "trusted" && -f "$HOME/.codex/auth.json" ]]; then
                log "Auth: using trusted host Codex auth file"
            elif [[ -f "${AGENTMILL_HOST_CODEX_HOME:-}/auth.json" ]]; then
                log "ERROR: Mounted Codex auth.json is only forwarded for trusted profile runs. Use CODEX_API_KEY, OPENAI_API_KEY, CODEX_ACCESS_TOKEN, or rerun with --profile-level trusted."
                exit 1
            else
                log "ERROR: No Codex auth. Set CODEX_API_KEY, OPENAI_API_KEY, CODEX_ACCESS_TOKEN, run codex login, or set AGENTMILL_CODEX_REQUIRE_AUTH=false for tests."
                exit 1
            fi
            ;;
        qwen)
            local selected_home
            selected_home="$(client_home_path qwen)"
            if ! agentmill_truthy "$AGENTMILL_QWEN_REQUIRE_AUTH"; then
                log "Auth: Qwen Code auth check disabled"
            elif [[ -n "${DASHSCOPE_API_KEY:-}" || -n "${OPENAI_API_KEY:-}" || -n "${ANTHROPIC_API_KEY:-}" || -n "${GEMINI_API_KEY:-}" || -n "${GOOGLE_API_KEY:-}" || -n "${OPENROUTER_API_KEY:-}" ]]; then
                log "Auth: using provider environment for Qwen Code"
            elif [[ -d "$selected_home/.qwen" || -d "$HOME/.qwen" ]]; then
                log "Auth: using Qwen Code config/cache"
            else
                log "ERROR: No Qwen Code auth. Set DASHSCOPE_API_KEY, OPENAI_API_KEY, another configured provider key, run qwen auth, or set AGENTMILL_QWEN_REQUIRE_AUTH=false for tests."
                exit 1
            fi
            ;;
        gemini)
            local selected_home
            selected_home="$(client_home_path gemini)"
            if ! agentmill_truthy "$AGENTMILL_GEMINI_REQUIRE_AUTH"; then
                log "Auth: Gemini auth check disabled"
            elif [[ -n "${GEMINI_API_KEY:-}" || -n "${GOOGLE_API_KEY:-}" ]]; then
                log "Auth: using Gemini API key environment"
            elif [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -n "${GOOGLE_CLOUD_PROJECT:-}" && -n "${GOOGLE_CLOUD_LOCATION:-}" ]]; then
                log "Auth: using Vertex AI service account environment"
            elif [[ -d "$selected_home/.gemini" || -d "$HOME/.gemini" ]]; then
                log "Auth: using Gemini CLI config/cache"
            else
                log "ERROR: No Gemini auth. Set GEMINI_API_KEY, GOOGLE_API_KEY, Vertex AI environment, run gemini auth, or set AGENTMILL_GEMINI_REQUIRE_AUTH=false for tests."
                exit 1
            fi
            ;;
        *)
            log_error "Client '${AGENTMILL_CLIENT}' is not implemented yet"
            exit 1
            ;;
    esac
}

client_home_path() {
    local client="${1:-${AGENTMILL_CLIENT:-claude}}"
    if [[ -n "${AGENTMILL_CLIENT_HOME:-}" ]]; then
        printf '%s\n' "$AGENTMILL_CLIENT_HOME"
    else
        printf '%s/%s\n' "${AGENTMILL_CLIENT_HOME_ROOT:-$HOME/.agentmill/clients}" "$client"
    fi
}

client_prepare_generic_home() {
    AGENTMILL_CLIENT_HOME="$(client_home_path "${AGENTMILL_CLIENT:-claude}")"
    export AGENTMILL_CLIENT_HOME
    mkdir -p "$AGENTMILL_CLIENT_HOME"
}

client_seed_file_if_missing() {
    local source="$1" target="$2" fallback="${3:-}"
    mkdir -p "$(dirname "$target")"
    if [[ -e "$target" || -L "$target" ]]; then
        return 0
    fi
    if [[ -f "$source" && "$source" != "$target" ]]; then
        cp "$source" "$target"
    elif [[ -n "$fallback" ]]; then
        printf '%s\n' "$fallback" > "$target"
    fi
}

client_link_path() {
    local target="$1" link="$2"
    mkdir -p "$(dirname "$link")"
    if [[ -e "$link" || -L "$link" ]]; then
        rm -rf "$link"
    fi
    ln -s "$target" "$link"
}

client_prepare_claude_home() {
    client_prepare_generic_home
    local selected="$AGENTMILL_CLIENT_HOME" selected_claude="$AGENTMILL_CLIENT_HOME/.claude"
    local default_settings='{"permissions":{"allow":["Bash","Read","Edit","Write","Glob","Grep"],"defaultMode":"bypassPermissions"}}'
    mkdir -p "$selected_claude" "$HOME/.claude"
    client_seed_file_if_missing "$HOME/.claude.json" "$selected/.claude.json" '{"hasCompletedOnboarding":true}'
    client_seed_file_if_missing "$HOME/.claude/settings.json" "$selected_claude/settings.json" "$default_settings"

    TARGET_CONFIG="$selected/.claude.json" \
    TARGET_SETTINGS="$selected_claude/settings.json" \
    TARGET_PLUGINS="$selected_claude/plugins" \
    TARGET_SKILLS="$selected_claude/skills" \
    TARGET_AGENTS="$selected_claude/agents" \
    TARGET_COMMANDS="$selected_claude/commands" \
        "$AGENTMILL_SETUP_CLAUDE_CONFIG"

    client_link_path "$selected/.claude.json" "$HOME/.claude.json"
    client_link_path "$selected_claude/settings.json" "$HOME/.claude/settings.json"
    local name
    for name in plugins skills agents commands; do
        if [[ -d "$selected_claude/$name" ]]; then
            client_link_path "$selected_claude/$name" "$HOME/.claude/$name"
        fi
    done
    log "Client home for claude: $selected"
}

client_write_opencode_config() {
    local config="$1" ir
    ir="$(client_policy_ir_json)"
    mkdir -p "$(dirname "$config")"
    python3 - "$config" "$MODEL" "$ir" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
model = sys.argv[2]
ir = json.loads(sys.argv[3])

def permission_for(tool: str) -> str:
    if tool == "edit":
        return ir["edit"]["default"]
    if tool == "bash":
        default = ir["shell"]["default"]
        if default == "allowlist":
            return "ask"
        if ir["profile"] == "standard" and ir["shell"].get("deny"):
            return "ask"
        return default
    if tool in {"webfetch", "websearch"}:
        return ir["web"]["default"]
    if tool == "task":
        return ir["subagent"]["default"]
    return "allow"

config = {
    "$schema": "https://opencode.ai/config.json",
    "model": model,
    "autoupdate": False,
    "share": "disabled",
    "snapshot": False,
    "instructions": ["AGENTS.md", "CLAUDE.md"],
    "permission": {
        "read": "allow",
        "glob": "allow",
        "grep": "allow",
        "edit": permission_for("edit"),
        "bash": permission_for("bash"),
        "webfetch": permission_for("webfetch"),
        "websearch": permission_for("websearch"),
        "task": permission_for("task"),
    },
    "mcp": {},
    "agentmill_policy": ir,
}
if ir["mcp"]["default"] == "deny":
    config["mcp"] = {}
elif ir["mcp"].get("allowlist"):
    config["agentmill_mcp_allowlist"] = ir["mcp"]["allowlist"]
if ir["shell"].get("allow"):
    config["agentmill_shell_allowlist"] = ir["shell"]["allow"]

path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

client_prepare_opencode_home() {
    client_prepare_generic_home
    export OPENCODE_CONFIG_DIR="$AGENTMILL_CLIENT_HOME"
    export OPENCODE_CONFIG="$AGENTMILL_CLIENT_HOME/opencode.json"
    export OPENCODE_DISABLE_AUTOUPDATE=true
    export OPENCODE_DISABLE_LSP_DOWNLOAD=true
    export OPENCODE_DISABLE_MODELS_FETCH="${OPENCODE_DISABLE_MODELS_FETCH:-true}"
    export OPENCODE_CLIENT="${OPENCODE_CLIENT:-agentmill}"
    if [[ "${AGENTMILL_PROFILE_LEVEL:-trusted}" != "trusted" ]]; then
        export OPENCODE_DISABLE_CLAUDE_CODE=true
        export OPENCODE_DISABLE_DEFAULT_PLUGINS=true
    fi
    client_write_opencode_config "$OPENCODE_CONFIG"
    log "Client home for opencode: $AGENTMILL_CLIENT_HOME"
}

client_seed_config_dir_for_trusted_profile() {
    local source="$1" target="$2"
    if [[ "${AGENTMILL_PROFILE_LEVEL:-trusted}" != "trusted" ]]; then
        return 0
    fi
    if [[ -d "$source" && "$source" != "$target" && ! -L "$source" ]]; then
        mkdir -p "$target"
        cp -a "$source/." "$target/" 2>/dev/null || true
    fi
}

client_codex_sandbox_mode() {
    if [[ -n "${AGENTMILL_CODEX_SANDBOX:-}" ]]; then
        printf '%s' "$AGENTMILL_CODEX_SANDBOX"
        return 0
    fi
    case "${AGENTMILL_PROFILE_LEVEL:-trusted}" in
        trusted|standard) printf '%s' "workspace-write" ;;
        untrusted)
            if is_readonly_clone_mode; then
                printf '%s' "workspace-write"
            else
                printf '%s' "read-only"
            fi
            ;;
        *) printf '%s' "read-only" ;;
    esac
}

client_codex_use_permission_profile() {
    [[ -z "${AGENTMILL_CODEX_SANDBOX:-}" ]]
}

client_codex_approval_policy() {
    if [[ -n "${AGENTMILL_CODEX_APPROVAL_POLICY:-}" ]]; then
        printf '%s' "$AGENTMILL_CODEX_APPROVAL_POLICY"
        return 0
    fi
    case "${AGENTMILL_PROFILE_LEVEL:-trusted}" in
        trusted) printf '%s' "never" ;;
        standard|untrusted) printf '%s' "untrusted" ;;
        *) printf '%s' "untrusted" ;;
    esac
}

client_write_codex_config() {
    local config="$1" ir sandbox approval repo_dir
    ir="$(client_policy_ir_json)"
    sandbox="$(client_codex_sandbox_mode)"
    approval="$(client_codex_approval_policy)"
    repo_dir="${REPO_DIR:-${PWD:-/workspace/repo}}"
    mkdir -p "$(dirname "$config")"
    python3 - "$config" "$MODEL" "$ir" "$sandbox" "$approval" "$repo_dir" "$AGENTMILL_WRITE_ROOTS" "$AGENTMILL_ALLOW_HIGH_RISK_CHANGES" "$AGENTMILL_EGRESS_ALLOWLIST" <<'PY'
import json
import os
import sys
from pathlib import Path, PurePosixPath

path = Path(sys.argv[1])
model = sys.argv[2]
ir = json.loads(sys.argv[3])
sandbox = sys.argv[4]
approval = sys.argv[5]
repo_dir = sys.argv[6]
write_roots_raw = sys.argv[7]
allow_high_risk = sys.argv[8].strip().lower() in {"1", "true", "yes", "on"}
egress_allowlist_raw = sys.argv[9]

def toml_string(value: str) -> str:
    return json.dumps(str(value))

def toml_array(values):
    return "[" + ", ".join(toml_string(value) for value in values) + "]"

def toml_key(value: str) -> str:
    return toml_string(value)

def norm_root(value: str) -> str | None:
    raw = value.replace(os.sep, "/").strip()
    if not raw or raw == ".":
        return "."
    if raw.startswith("/"):
        repo = Path(repo_dir or ".").resolve()
        try:
            raw = str(Path(raw).resolve().relative_to(repo)).replace(os.sep, "/")
        except (OSError, ValueError):
            return None
    path = PurePosixPath(raw)
    if path.is_absolute():
        return None
    parts = []
    for part in path.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            return None
        parts.append(part)
    return "/".join(parts) if parts else "."

def parse_write_roots(raw: str) -> tuple[list[str], list[str]]:
    roots = []
    invalid = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        normalized = norm_root(item)
        if normalized is None:
            invalid.append(item)
            continue
        if normalized not in roots:
            roots.append(normalized)
    return roots, invalid

def network_domains(raw: str) -> list[str]:
    out = []
    for item in raw.replace("\n", ",").split(","):
        item = item.strip()
        if not item:
            continue
        if "://" in item:
            item = item.split("://", 1)[1]
        item = item.split("/", 1)[0].split("@")[-1]
        if ":" in item and not item.startswith("["):
            item = item.rsplit(":", 1)[0]
        item = item.strip("[]").lower().rstrip(".")
        if item and item not in out:
            out.append(item)
    return out

include_env = ["PATH", "HOME", "USER", "LANG", "LC_ALL", "SHELL", "TERM"]
allow_shell = ir["shell"].get("allow", [])
deny_shell = ir["shell"].get("deny", [])
mcp_allowlist = ir["mcp"].get("allowlist", [])
write_roots, invalid_write_roots = parse_write_roots(write_roots_raw)
if invalid_write_roots:
    raise SystemExit(f"invalid AGENTMILL_WRITE_ROOTS for Codex permissions: {','.join(invalid_write_roots)}")
use_permission_profile = not os.environ.get("AGENTMILL_CODEX_SANDBOX", "").strip()

lines = [
    f"model = {toml_string(model)}",
    f"approval_policy = {toml_string(approval)}",
]
if use_permission_profile:
    lines.append('default_permissions = "agentmill"')
else:
    lines.append(f"sandbox_mode = {toml_string(sandbox)}")
lines.extend([
    "",
    "[shell_environment_policy]",
    f"include_only = {toml_array(include_env)}",
    "",
])

if use_permission_profile:
    lines.extend(
        [
            "[permissions.agentmill]",
            f"description = {toml_string('AgentMill generated permissions')}",
            "",
            "[permissions.agentmill.filesystem]",
            '":minimal" = "read"',
            "glob_scan_max_depth = 3",
            "",
            '[permissions.agentmill.filesystem.":workspace_roots"]',
        ]
    )
    full_workspace_write = (
        ir["profile"] == "trusted"
        or "." in write_roots
        or (ir["profile"] == "standard" and not write_roots)
        or (ir["profile"] == "untrusted" and not write_roots and os.environ.get("AGENTMILL_WORKSPACE_MODE", "") == "readonly-clone")
    )
    if full_workspace_write:
        lines.append('"." = "write"')
    else:
        lines.append('"." = "read"')
        for root in write_roots:
            if root != ".":
                lines.append(f"{toml_key(root)} = \"write\"")
    if ir["profile"] != "trusted" and not allow_high_risk:
        for subpath, access in [
            (".env", "deny"),
            ("*.env", "deny"),
            ("**/*.env", "deny"),
            (".github/workflows", "read"),
            (".mcp.json", "read"),
            (".claude", "read"),
            (".codex", "read"),
        ]:
            lines.append(f"{toml_key(subpath)} = {toml_string(access)}")
    lines.extend(["", "[permissions.agentmill.network]"])
    network = ir.get("network", "")
    domains = network_domains(egress_allowlist_raw)
    if network == "allow":
        lines.append("enabled = true")
        lines.extend(["", "[permissions.agentmill.network.domains]", '"*" = "allow"'])
    elif network == "allowlist" and domains:
        lines.append("enabled = true")
        lines.append("")
        lines.append("[permissions.agentmill.network.domains]")
        for domain in domains:
            lines.append(f"{toml_key(domain)} = \"allow\"")
    else:
        lines.append("enabled = false")
    lines.append("")

lines.extend([
    "[agentmill]",
    f"profile = {toml_string(ir['profile'])}",
    f"network = {toml_string(ir['network'])}",
    f"client = {toml_string(ir['client'])}",
    f"shell_allow = {toml_array(allow_shell)}",
    f"shell_deny = {toml_array(deny_shell)}",
    f"mcp_allowlist = {toml_array(mcp_allowlist)}",
    f"write_roots = {toml_array(write_roots)}",
    f"policy_json = {toml_string(json.dumps(ir, sort_keys=True, separators=(',', ':')))}",
    "",
])
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

client_write_codex_rules() {
    local rules_file="$1" ir
    ir="$(client_policy_ir_json)"
    mkdir -p "$(dirname "$rules_file")"
    python3 - "$rules_file" "$ir" <<'PY'
import json
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
ir = json.loads(sys.argv[2])

def pattern_tokens(pattern: str) -> list[str]:
    raw = str(pattern or "").strip()
    if raw.startswith("Bash(") and raw.endswith(")"):
        raw = raw[5:-1].strip()
    if raw.endswith(":*"):
        raw = raw[:-2].strip()
    elif raw.endswith("*"):
        raw = raw[:-1].strip()
    if raw.endswith(":"):
        raw = raw[:-1].strip()
    if raw in {"", "*"}:
        return []
    try:
        return shlex.split(raw)
    except ValueError:
        return raw.split()

def rule(pattern: str, decision: str) -> str | None:
    tokens = pattern_tokens(pattern)
    if not tokens:
        return None
    return f"prefix_rule(pattern={json.dumps(tokens)}, decision={json.dumps(decision)})"

lines = [
    "# Generated by AgentMill. Do not edit in place.",
    f"# profile={ir['profile']} client={ir['client']} network={ir['network']}",
]
for pattern in ir["shell"].get("deny", []):
    item = rule(pattern, "forbidden")
    if item and item not in lines:
        lines.append(item)
for pattern in ir["shell"].get("allow", []):
    item = rule(pattern, "allow")
    if item and item not in lines:
        lines.append(item)
lines.append("")
path.write_text("\n".join(lines), encoding="utf-8")
PY
}

client_prepare_codex_home() {
    client_prepare_generic_home
    local selected="$AGENTMILL_CLIENT_HOME" selected_codex="$AGENTMILL_CLIENT_HOME/.codex"
    mkdir -p "$selected_codex"
    if [[ -n "${AGENTMILL_HOST_CODEX_HOME:-}" ]]; then
        client_seed_config_dir_for_trusted_profile "$AGENTMILL_HOST_CODEX_HOME" "$selected_codex"
    fi
    client_seed_config_dir_for_trusted_profile "$HOME/.codex" "$selected_codex"
    export CODEX_HOME="$selected_codex"
    client_write_codex_config "$selected_codex/config.toml"
    client_write_codex_rules "$selected_codex/rules/agentmill.rules"
    client_link_path "$selected_codex" "$HOME/.codex"
    log "Client home for codex: $selected"
}

client_qwen_cli_approval_mode() {
    case "${AGENTMILL_PROFILE_LEVEL:-trusted}" in
        trusted) printf '%s' "yolo" ;;
        standard) printf '%s' "auto_edit" ;;
        untrusted) printf '%s' "default" ;;
        *) printf '%s' "default" ;;
    esac
}

client_qwen_settings_approval_mode() {
    case "${AGENTMILL_PROFILE_LEVEL:-trusted}" in
        trusted) printf '%s' "yolo" ;;
        standard) printf '%s' "auto-edit" ;;
        untrusted) printf '%s' "plan" ;;
        *) printf '%s' "default" ;;
    esac
}

client_gemini_cli_approval_mode() {
    case "${AGENTMILL_PROFILE_LEVEL:-trusted}" in
        trusted) printf '%s' "yolo" ;;
        standard) printf '%s' "auto_edit" ;;
        untrusted) printf '%s' "default" ;;
        *) printf '%s' "default" ;;
    esac
}

client_write_qwen_config() {
    local config="$1" ir approval_mode
    ir="$(client_policy_ir_json)"
    approval_mode="$(client_qwen_settings_approval_mode)"
    mkdir -p "$(dirname "$config")"
    python3 - "$config" "$MODEL" "$ir" "$approval_mode" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
model = sys.argv[2]
ir = json.loads(sys.argv[3])
approval_mode = sys.argv[4]

def shell_rule(pattern: str) -> str:
    value = str(pattern or "").strip()
    if not value or value == "*":
        return "Bash"
    if value.startswith("Bash("):
        return value
    if value.endswith(":*"):
        value = value[:-2]
    value = value.strip()
    if not value or value == "*":
        return "Bash"
    if value.endswith("*"):
        return f"Bash({value})"
    return f"Bash({value} *)"

def as_sandbox(value: str):
    raw = (value or "").strip()
    if raw.lower() in {"true", "1", "yes", "on"}:
        return True
    if raw.lower() in {"false", "0", "no", "off"}:
        return False
    return raw or None

allow = ["Read"]
ask = []
deny = []
shell_allow = ir["shell"].get("allow", [])

if ir["profile"] == "trusted":
    allow.extend(["Edit", "WebFetch", "Agent", "Skill"])
    if shell_allow:
        allow.extend(shell_rule(pattern) for pattern in shell_allow)
    else:
        allow.append("Bash")
elif ir["profile"] == "standard":
    allow.append("Edit")
    if shell_allow:
        allow.extend(shell_rule(pattern) for pattern in shell_allow)
    else:
        ask.append("Bash")
else:
    deny.extend(["Edit", "WebFetch", "Agent", "Skill"])
    if shell_allow:
        allow.extend(shell_rule(pattern) for pattern in shell_allow)
    else:
        deny.append("Bash")

if ir["web"]["default"] == "deny" and "WebFetch" not in deny:
    deny.append("WebFetch")
if ir["subagent"]["default"] == "deny":
    deny.extend(["Agent", "Skill"])
for pattern in ir["shell"].get("deny", []):
    rule = shell_rule(pattern)
    if rule not in deny:
        deny.append(rule)

config = {
    "general": {
        "enableAutoUpdate": False,
        "showSessionRecap": False,
        "gitCoAuthor": False,
        "checkpointing": {"enabled": False},
    },
    "output": {"format": "json"},
    "ui": {
        "compactMode": True,
        "hideTips": True,
        "accessibility": {"enableLoadingPhrases": False},
    },
    "privacy": {"usageStatisticsEnabled": False},
    "model": {
        "name": model,
        "maxSessionTurns": -1,
        "enableOpenAILogging": False,
    },
    "context": {
        "fileName": ["AGENTS.md", "QWEN.md", "CLAUDE.md"],
        "fileFiltering": {"respectGitIgnore": True, "respectQwenIgnore": True},
    },
    "tools": {
        "approvalMode": approval_mode,
        "useRipgrep": True,
        "useBuiltinRipgrep": False,
    },
    "permissions": {
        "allow": sorted(set(allow)),
        "ask": sorted(set(ask)),
        "deny": sorted(set(deny)),
    },
    "mcp": {},
    "mcpServers": {},
    "slashCommands": {"disabled": []},
    "telemetry": {
        "enabled": False,
        "target": "local",
        "logPrompts": False,
    },
    "advanced": {
        "excludedEnvVars": ["DEBUG", "DEBUG_MODE", "NODE_ENV"],
    },
    "agentmill_policy": ir,
}

sandbox = as_sandbox(os.environ.get("AGENTMILL_QWEN_SANDBOX") or os.environ.get("QWEN_SANDBOX") or "")
if sandbox is not None:
    config["tools"]["sandbox"] = sandbox

if ir["mcp"]["default"] == "allowlist":
    config["mcp"]["allowed"] = ir["mcp"].get("allowlist", [])
elif ir["mcp"]["default"] == "deny":
    config["mcp"]["allowed"] = []
    config["mcp"]["excluded"] = ["*"]

if ir["profile"] != "trusted":
    config["slashCommands"]["disabled"] = ["auth", "mcp", "extensions", "ide"]

path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

client_write_gemini_config() {
    local config="$1" ir
    ir="$(client_policy_ir_json)"
    mkdir -p "$(dirname "$config")"
    python3 - "$config" "$MODEL" "$ir" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
model = sys.argv[2]
ir = json.loads(sys.argv[3])

def as_sandbox(value: str):
    raw = (value or "").strip()
    if raw.lower() in {"true", "1", "yes", "on"}:
        return True
    if raw.lower() in {"false", "0", "no", "off"}:
        return False
    return raw or None

exclude = []
core = None

if ir["web"]["default"] == "deny":
    exclude.extend(["web_fetch", "google_web_search"])

# Gemini does not expose command-prefix mediation. If AgentMill has any
# non-trusted shell deny rules, disable the shell tool instead of pretending the
# prefixes are enforceable.
if ir["shell"]["default"] in {"deny", "allowlist"} or (ir["profile"] != "trusted" and ir["shell"].get("deny")):
    exclude.append("run_shell_command")

if ir["profile"] == "untrusted":
    core = ["glob", "grep_search", "list_directory", "read_file", "read_many_files"]
    exclude.extend(["replace", "run_shell_command", "save_memory", "web_fetch", "write_file", "google_web_search"])

tools = {
    "exclude": sorted(set(exclude)),
    "useRipgrep": True,
}
if core:
    tools["core"] = core
sandbox = as_sandbox(os.environ.get("AGENTMILL_GEMINI_SANDBOX") or os.environ.get("GEMINI_SANDBOX") or "")
if sandbox is not None:
    tools["sandbox"] = sandbox

config = {
    "general": {
        "disableAutoUpdate": True,
        "disableUpdateNag": True,
        "checkpointing": {"enabled": False},
    },
    "output": {"format": "json"},
    "ui": {
        "hideBanner": True,
        "hideTips": True,
        "accessibility": {"disableLoadingPhrases": True},
    },
    "privacy": {"usageStatisticsEnabled": False},
    "model": {
        "name": model,
        "maxSessionTurns": -1,
    },
    "context": {
        "fileName": ["AGENTS.md", "GEMINI.md", "CLAUDE.md"],
        "fileFiltering": {"respectGitIgnore": True, "respectGeminiIgnore": True},
    },
    "tools": tools,
    "mcp": {},
    "mcpServers": {},
    "telemetry": {
        "enabled": False,
        "target": "local",
        "logPrompts": False,
    },
    "advanced": {
        "excludedEnvVars": ["DEBUG", "DEBUG_MODE", "NODE_ENV"],
    },
    "agentmill_policy": ir,
}

if ir["mcp"]["default"] == "allowlist":
    config["mcp"]["allowed"] = ir["mcp"].get("allowlist", [])
elif ir["mcp"]["default"] == "deny":
    config["mcp"]["allowed"] = []
    config["mcp"]["excluded"] = ["*"]

path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

client_prepare_qwen_home() {
    client_prepare_generic_home
    local selected="$AGENTMILL_CLIENT_HOME" selected_qwen="$AGENTMILL_CLIENT_HOME/.qwen"
    mkdir -p "$selected_qwen"
    client_seed_config_dir_for_trusted_profile "$HOME/.qwen" "$selected_qwen"
    export QWEN_CODE_SYSTEM_SETTINGS_PATH="$selected_qwen/settings.json"
    export QWEN_TELEMETRY_ENABLED=false
    export QWEN_TELEMETRY_LOG_PROMPTS=false
    [[ -n "$AGENTMILL_QWEN_SANDBOX" ]] && export QWEN_SANDBOX="$AGENTMILL_QWEN_SANDBOX"
    client_write_qwen_config "$QWEN_CODE_SYSTEM_SETTINGS_PATH"
    client_link_path "$selected_qwen" "$HOME/.qwen"
    log "Client home for qwen: $selected"
}

client_prepare_gemini_home() {
    client_prepare_generic_home
    local selected="$AGENTMILL_CLIENT_HOME" selected_gemini="$AGENTMILL_CLIENT_HOME/.gemini"
    mkdir -p "$selected_gemini"
    client_seed_config_dir_for_trusted_profile "$HOME/.gemini" "$selected_gemini"
    export GEMINI_CLI_SYSTEM_SETTINGS_PATH="$selected_gemini/settings.json"
    export GEMINI_TELEMETRY_ENABLED=false
    export GEMINI_TELEMETRY_LOG_PROMPTS=false
    [[ -n "$AGENTMILL_GEMINI_SANDBOX" ]] && export GEMINI_SANDBOX="$AGENTMILL_GEMINI_SANDBOX"
    client_write_gemini_config "$GEMINI_CLI_SYSTEM_SETTINGS_PATH"
    client_link_path "$selected_gemini" "$HOME/.gemini"
    log "Client home for gemini: $selected"
}

client_prepare_home() {
    case "${AGENTMILL_CLIENT:-claude}" in
        claude) client_prepare_claude_home ;;
        fake) client_prepare_generic_home ;;
        opencode) client_prepare_opencode_home ;;
        codex) client_prepare_codex_home ;;
        qwen) client_prepare_qwen_home ;;
        gemini) client_prepare_gemini_home ;;
        *)
            log_error "Client '${AGENTMILL_CLIENT}' is not implemented yet"
            exit 1
            ;;
    esac
}

client_prepare_project() {
    case "${AGENTMILL_CLIENT:-claude}" in
        claude)
            backup_project_settings ".claude/settings.local.json"
            write_project_settings "$(autonomous_settings_json)"
            ;;
        fake) return 0 ;;
        opencode|qwen|gemini) return 0 ;;
        codex)
            if [[ -n "${CODEX_HOME:-}" ]]; then
                client_write_codex_config "$CODEX_HOME/config.toml"
            fi
            ;;
        *)
            log_error "Client '${AGENTMILL_CLIENT}' is not implemented yet"
            exit 1
            ;;
    esac
}

client_cleanup() {
    case "${AGENTMILL_CLIENT:-claude}" in
        claude) restore_project_settings ;;
        fake) return 0 ;;
        *) return 0 ;;
    esac
}

client_run_headless() {
    local prompt_content="$1" session_log="$2"
    case "${AGENTMILL_CLIENT:-claude}" in
        claude)
            ensure_usage_telemetry_for_budget
            local claude_args=(--dangerously-skip-permissions -p "$prompt_content")
            case "$AGENTMILL_CLAUDE_OUTPUT_FORMAT" in
                text|"") ;;
                json|stream-json) claude_args+=(--output-format "$AGENTMILL_CLAUDE_OUTPUT_FORMAT") ;;
                *)
                    log_error "Invalid AGENTMILL_CLAUDE_OUTPUT_FORMAT: $AGENTMILL_CLAUDE_OUTPUT_FORMAT"
                    event_emit_kv policy.denied reason=invalid_claude_output_format output_format="$AGENTMILL_CLAUDE_OUTPUT_FORMAT"
                    return 2
                    ;;
            esac
            "$AGENTMILL_CLAUDE_COMMAND" "${claude_args[@]}" \
                > >(redacted_tee "$session_log") 2>&1 &
            local client_pid=$!
            start_client_watchers "$client_pid"
            wait "$client_pid" 2>/dev/null
            local rc=$?
            stop_client_watchers
            return "$rc"
            ;;
        fake)
            {
                printf 'fake client received prompt bytes=%s\n' "${#prompt_content}"
                if agentmill_truthy "$AGENTMILL_FAKE_CLIENT_EMIT_TOOL_EVENT"; then
                    printf '{"type":"tool.invoked","name":"fake.write","id":"fake-tool-1"}\n'
                    printf '{"type":"tool.completed","name":"fake.write","id":"fake-tool-1","status":"completed"}\n'
                fi
            } | redacted_tee "$session_log"
            if agentmill_truthy "$AGENTMILL_FAKE_CLIENT_EMIT_TOOL_EVENT"; then
                event_emit_kv tool.invoked client=fake tool_id=fake-tool-1 tool_name=fake.write provider=fake raw_event_type=tool.invoked
                event_emit_kv tool.completed client=fake tool_id=fake-tool-1 tool_name=fake.write provider=fake raw_event_type=tool.completed status=completed
            fi
            if [[ -n "$AGENTMILL_FAKE_CLIENT_WRITE_FILE" ]]; then
                mkdir -p "$(dirname "$REPO_DIR/$AGENTMILL_FAKE_CLIENT_WRITE_FILE")"
                printf '%s\n' "$AGENTMILL_FAKE_CLIENT_WRITE_TEXT" > "$REPO_DIR/$AGENTMILL_FAKE_CLIENT_WRITE_FILE"
            fi
            if agentmill_truthy "$AGENTMILL_FAKE_CLIENT_TOUCH_DONE"; then
                touch "$DONE_FILE"
            fi
            return "$AGENTMILL_FAKE_CLIENT_EXIT_CODE"
            ;;
        opencode)
            local opencode_args=(run --format json --dir "$REPO_DIR")
            [[ -n "${MODEL:-}" ]] && opencode_args+=(--model "$MODEL")
            if [[ "${AGENTMILL_PROFILE_LEVEL:-trusted}" == "trusted" ]]; then
                opencode_args+=(--dangerously-skip-permissions)
            fi
            opencode_args+=("$prompt_content")
            client_run_with_write_root_sandbox "$REPO_DIR" "$AGENTMILL_OPENCODE_COMMAND" "${opencode_args[@]}" \
                > >(redacted_tee "$session_log") 2>&1 &
            local client_pid=$!
            start_client_watchers "$client_pid"
            wait "$client_pid" 2>/dev/null
            local rc=$?
            stop_client_watchers
            return "$rc"
            ;;
        codex)
            local codex_final="${session_log}.final"
            local codex_args=(exec - --cd "$REPO_DIR" --json --ask-for-approval "$(client_codex_approval_policy)" --output-last-message "$codex_final")
            if ! client_codex_use_permission_profile; then
                codex_args+=(--sandbox "$(client_codex_sandbox_mode)")
            fi
            [[ -n "${MODEL:-}" ]] && codex_args+=(--model "$MODEL")
            (
                cd "$REPO_DIR"
                printf '%s' "$prompt_content" | "$AGENTMILL_CODEX_COMMAND" "${codex_args[@]}"
            ) > >(redacted_tee "$session_log") 2>&1 &
            local client_pid=$!
            start_client_watchers "$client_pid"
            wait "$client_pid" 2>/dev/null
            local rc=$?
            stop_client_watchers
            return "$rc"
            ;;
        qwen)
            local qwen_args=(--prompt "$prompt_content" --output-format "$AGENTMILL_QWEN_OUTPUT_FORMAT")
            [[ -n "${MODEL:-}" ]] && qwen_args+=(--model "$MODEL")
            qwen_args+=(--approval-mode "$(client_qwen_cli_approval_mode)")
            if [[ "$AGENTMILL_QWEN_OUTPUT_FORMAT" == "stream-json" ]] && agentmill_truthy "$AGENTMILL_QWEN_INCLUDE_PARTIAL_MESSAGES"; then
                qwen_args+=(--include-partial-messages)
            fi
            client_run_with_write_root_sandbox "$REPO_DIR" "$AGENTMILL_QWEN_COMMAND" "${qwen_args[@]}" \
                > >(redacted_tee "$session_log") 2>&1 &
            local client_pid=$!
            start_client_watchers "$client_pid"
            wait "$client_pid" 2>/dev/null
            local rc=$?
            stop_client_watchers
            return "$rc"
            ;;
        gemini)
            local gemini_args=(--prompt "$prompt_content" --output-format "$AGENTMILL_GEMINI_OUTPUT_FORMAT")
            [[ -n "${MODEL:-}" ]] && gemini_args+=(--model "$MODEL")
            gemini_args+=(--approval-mode "$(client_gemini_cli_approval_mode)" --extensions none)
            client_run_with_write_root_sandbox "$REPO_DIR" "$AGENTMILL_GEMINI_COMMAND" "${gemini_args[@]}" \
                > >(redacted_tee "$session_log") 2>&1 &
            local client_pid=$!
            start_client_watchers "$client_pid"
            wait "$client_pid" 2>/dev/null
            local rc=$?
            stop_client_watchers
            return "$rc"
            ;;
        *)
            log_error "Client '${AGENTMILL_CLIENT}' is not implemented yet"
            return 2
            ;;
    esac
}

client_run_acp_tui() {
    local prompt="${AGENTMILL_ACP_PROMPT:-${CLAUDE_INITIAL_PROMPT:-}}"
    [[ -n "$prompt" ]] || prompt="Start an AgentMill ACP session for this repository."
    local acp_log="$LOG_DIR/acp-${AGENT_ID:-tui}-iter${ITERATION:-0}.jsonl"
    local -a bridge_cmd acp_cmd
    if [[ -x "$AGENTMILL_ACP_BRIDGE" ]]; then
        bridge_cmd=("$AGENTMILL_ACP_BRIDGE")
    else
        bridge_cmd=(python3 "$AGENTMILL_ACP_BRIDGE")
    fi
    case "${AGENTMILL_CLIENT:-claude}" in
        opencode) acp_cmd=("$AGENTMILL_OPENCODE_COMMAND" acp) ;;
        qwen) acp_cmd=("$AGENTMILL_QWEN_COMMAND" --acp) ;;
        *)
            log_error "ACP transport is not supported for client '${AGENTMILL_CLIENT:-claude}'"
            event_emit_kv policy.denied reason=unsupported_acp_client client="${AGENTMILL_CLIENT:-claude}"
            return 2
            ;;
    esac
    CLIENT_LAST_SESSION_LOG="$acp_log"
    event_emit_kv acp.started client="${AGENTMILL_CLIENT:-claude}" transport=stdio session_log="$acp_log"
    set +e
    client_run_with_write_root_sandbox "$REPO_DIR" "${bridge_cmd[@]}" --cwd "$REPO_DIR" --prompt "$prompt" -- "${acp_cmd[@]}" \
        > >(redacted_tee "$acp_log") 2>&1
    local rc=$?
    set -e
    event_emit_kv acp.completed client="${AGENTMILL_CLIENT:-claude}" transport=stdio session_log="$acp_log" exit_code="$rc"
    return "$rc"
}

client_run_tui() {
    CLIENT_LAST_SESSION_LOG=""
    if [[ "${AGENTMILL_CLIENT_TRANSPORT:-native}" == "acp" ]]; then
        client_run_acp_tui
        return $?
    fi
    case "${AGENTMILL_CLIENT:-claude}" in
        claude)
            if [[ "${SKIP_PROMPT:-false}" == "true" ]]; then
                "$AGENTMILL_CLAUDE_COMMAND" || true
            else
                "${AGENTMILL_AUTO_TRUST_COMMAND:-/auto-trust.exp}" || true
            fi
            ;;
        fake)
            if agentmill_truthy "$AGENTMILL_FAKE_CLIENT_TOUCH_DONE"; then
                touch "$DONE_FILE"
            fi
            ;;
        opencode)
            "$AGENTMILL_OPENCODE_COMMAND" "$REPO_DIR" || true
            ;;
        codex)
            (cd "$REPO_DIR" && "$AGENTMILL_CODEX_COMMAND") || true
            ;;
        qwen)
            (cd "$REPO_DIR" && "$AGENTMILL_QWEN_COMMAND") || true
            ;;
        gemini)
            (cd "$REPO_DIR" && "$AGENTMILL_GEMINI_COMMAND") || true
            ;;
        *)
            log_error "Client '${AGENTMILL_CLIENT}' is not implemented yet"
            return 2
            ;;
    esac
}

client_emit_completed() {
    local exit_code="${1:-}" done_signaled="${2:-false}" completion_accepted="${3:-false}" session_log="${4:-}"
    event_emit_kv agent.completed \
        client="${AGENTMILL_CLIENT:-claude}" \
        exit_code="$exit_code" \
        done_signaled="$done_signaled" \
        completion_accepted="$completion_accepted" \
        session_log="$session_log" \
        raw_event_type="${AGENTMILL_CLIENT:-claude}.completed"
    if [[ "${AGENTMILL_CLIENT:-claude}" == "claude" ]]; then
        event_emit_kv claude.completed exit_code="$exit_code" done_signaled="$done_signaled" completion_accepted="$completion_accepted" session_log="$session_log"
    fi
}

configure_git_identity() {
    local name="${1}${3:+-$3}"
    git config --global user.name "$name"
    git config --global user.email "$2"
}

prepare_repo_environment() {
    log "Preparing repo environment..."
    # shellcheck disable=SC1091
    . "$AGENTMILL_SETUP_REPO_ENV" "$1"
    log "Repo environment ready."
}

client_policy_ir_json() {
    python3 <<'PY'
import json
import os

profile = os.environ.get("AGENTMILL_PROFILE_LEVEL", "trusted").strip().lower()
client = os.environ.get("AGENTMILL_CLIENT", "claude").strip().lower() or "claude"
provider = os.environ.get("AGENTMILL_PROVIDER", "").strip()
network = os.environ.get("AGENTMILL_NETWORK", "").strip().lower()
mcp_allowlist = [item.strip() for item in os.environ.get("AGENTMILL_MCP_ALLOWLIST", "").split(",") if item.strip()]
shell_allowlist = [item.strip() for item in os.environ.get("AGENTMILL_SHELL_ALLOWLIST", "").split(",") if item.strip()]
shell_denylist = [item.strip() for item in os.environ.get("AGENTMILL_SHELL_DENYLIST", "").split(",") if item.strip()]
allow_shell_network = os.environ.get("AGENTMILL_ALLOW_SHELL_NETWORK", "").strip().lower() in {"1", "true", "yes", "on"}

high_risk_shell = ["sudo:*", "rm -rf:*", "chmod -R:*", "chown -R:*", "docker run:*", "docker compose up:*", "kubectl apply:*", "terraform apply:*"]
shell_network = ["curl:*", "wget:*", "nc:*", "ncat:*", "telnet:*"]
strict_network = ["git push:*", "git fetch:*", "git pull:*", "ssh:*", "scp:*", "npm install:*", "pnpm install:*", "yarn install:*", "pip install:*", "uv add:*", "go get:*", "cargo install:*"]

def unique(values):
    out = []
    for value in values:
        if value and value not in out:
            out.append(value)
    return out

if profile == "trusted":
    ir = {
        "version": 1,
        "client": client,
        "provider": provider,
        "profile": profile,
        "network": network or "allow",
        "read": {"default": "allow"},
        "edit": {"default": "allow"},
        "shell": {"default": "allowlist" if shell_allowlist else "allow", "allow": unique(shell_allowlist), "deny": unique(shell_denylist)},
        "web": {"default": "allow"},
        "mcp": {"default": "allow", "allowlist": mcp_allowlist},
        "subagent": {"default": "allow"},
        "project_config": {"import_host": True, "allow_project_local": True},
    }
elif profile == "standard":
    deny = list(high_risk_shell)
    if not allow_shell_network and network in {"", "deny", "allowlist"}:
        deny.extend(shell_network)
    if network == "deny":
        deny.extend(strict_network)
    deny.extend(shell_denylist)
    ir = {
        "version": 1,
        "client": client,
        "provider": provider,
        "profile": profile,
        "network": network or "allowlist",
        "read": {"default": "allow"},
        "edit": {"default": "allow"},
        "shell": {"default": "allowlist" if shell_allowlist else "allow", "allow": unique(shell_allowlist), "deny": unique(deny)},
        "web": {"default": "deny"},
        "mcp": {"default": "allowlist" if mcp_allowlist else "deny", "allowlist": mcp_allowlist},
        "subagent": {"default": "allow"},
        "project_config": {
            "import_host": False,
            "allow_project_local": bool(mcp_allowlist) or os.environ.get("AGENTMILL_FORWARD_HOST_MCP", "").lower() in {"1", "true", "yes", "on"},
        },
    }
elif profile == "untrusted":
    deny = []
    if shell_allowlist:
        deny.extend(high_risk_shell)
        if not allow_shell_network and (network or "deny") in {"", "deny", "allowlist"}:
            deny.extend(shell_network)
        if (network or "deny") == "deny":
            deny.extend(strict_network)
    else:
        deny.append("*")
    deny.extend(shell_denylist)
    ir = {
        "version": 1,
        "client": client,
        "provider": provider,
        "profile": profile,
        "network": network or "deny",
        "read": {"default": "allow"},
        "edit": {"default": "ask"},
        "shell": {"default": "allowlist" if shell_allowlist else "deny", "allow": unique(shell_allowlist), "deny": unique(deny)},
        "web": {"default": "deny"},
        "mcp": {"default": "deny", "allowlist": []},
        "subagent": {"default": "deny"},
        "project_config": {"import_host": False, "allow_project_local": False},
    }
else:
    raise SystemExit(f"unknown AGENTMILL_PROFILE_LEVEL: {profile}")

print(json.dumps(ir, sort_keys=True, separators=(",", ":")))
PY
}

# --- Project settings backup/restore ---
backup_project_settings() {
    SETTINGS_LOCAL_PATH="${1:-.claude/settings.local.json}"
    SETTINGS_BACKUP_FILE=""
    SETTINGS_BACKUP_EXISTS=false
    SETTINGS_BACKUP_KIND=missing
    SETTINGS_BACKUP_LINK_TARGET=""
    mkdir -p "$(dirname "$SETTINGS_LOCAL_PATH")"
    if [[ -L "$SETTINGS_LOCAL_PATH" ]]; then
        SETTINGS_BACKUP_KIND=symlink
        SETTINGS_BACKUP_LINK_TARGET="$(readlink "$SETTINGS_LOCAL_PATH")"
        if [[ -e "$SETTINGS_LOCAL_PATH" ]]; then
            SETTINGS_BACKUP_FILE="$(mktemp)"
            cp "$SETTINGS_LOCAL_PATH" "$SETTINGS_BACKUP_FILE"
            SETTINGS_BACKUP_EXISTS=true
        fi
    elif [[ -f "$SETTINGS_LOCAL_PATH" ]]; then
        SETTINGS_BACKUP_KIND=file
        SETTINGS_BACKUP_FILE="$(mktemp)"
        cp "$SETTINGS_LOCAL_PATH" "$SETTINGS_BACKUP_FILE"
        SETTINGS_BACKUP_EXISTS=true
    fi
}

write_project_settings() {
    [[ -n "${SETTINGS_LOCAL_PATH:-}" ]] || { echo "call backup_project_settings first" >&2; return 1; }
    printf '%s\n' "$1" > "$SETTINGS_LOCAL_PATH"
}

restore_project_settings() {
    local current_target target_abs
    [[ -n "${SETTINGS_LOCAL_PATH:-}" ]] || return 0
    case "${SETTINGS_BACKUP_KIND:-missing}" in
        symlink)
            current_target=""
            [[ -L "$SETTINGS_LOCAL_PATH" ]] && current_target="$(readlink "$SETTINGS_LOCAL_PATH")"
            if [[ ! -L "$SETTINGS_LOCAL_PATH" || "$current_target" != "${SETTINGS_BACKUP_LINK_TARGET:-}" ]]; then
                rm -f "$SETTINGS_LOCAL_PATH"
                ln -s "${SETTINGS_BACKUP_LINK_TARGET:-}" "$SETTINGS_LOCAL_PATH"
            fi
            if [[ "${SETTINGS_BACKUP_EXISTS:-false}" == "true" && -f "${SETTINGS_BACKUP_FILE:-}" ]]; then
                cp "$SETTINGS_BACKUP_FILE" "$SETTINGS_LOCAL_PATH"
            elif [[ -e "$SETTINGS_LOCAL_PATH" ]]; then
                target_abs="$(readlink -f "$SETTINGS_LOCAL_PATH" 2>/dev/null || true)"
                [[ -n "$target_abs" ]] && rm -f "$target_abs"
            fi
            ;;
        file)
            if [[ "${SETTINGS_BACKUP_EXISTS:-false}" == "true" && -f "${SETTINGS_BACKUP_FILE:-}" ]]; then
                cp "$SETTINGS_BACKUP_FILE" "$SETTINGS_LOCAL_PATH"
            else
                rm -f "$SETTINGS_LOCAL_PATH"
            fi
            ;;
        *)
            rm -f "$SETTINGS_LOCAL_PATH"
            ;;
    esac
    rm -f "${SETTINGS_BACKUP_FILE:-}"
    unset SETTINGS_LOCAL_PATH SETTINGS_BACKUP_FILE SETTINGS_BACKUP_EXISTS SETTINGS_BACKUP_KIND SETTINGS_BACKUP_LINK_TARGET
}

autonomous_settings_json() {
    python3 <<'PY'
import json
import os

profile = os.environ.get("AGENTMILL_PROFILE_LEVEL", "trusted")
network = os.environ.get("AGENTMILL_NETWORK", "").strip().lower()
allowlist = [
    item.strip()
    for item in os.environ.get("AGENTMILL_MCP_ALLOWLIST", "").split(",")
    if item.strip()
]
extra_shell_allows = [
    item.strip()
    for item in os.environ.get("AGENTMILL_SHELL_ALLOWLIST", "").split(",")
    if item.strip()
]
extra_shell_denies = [
    item.strip()
    for item in os.environ.get("AGENTMILL_SHELL_DENYLIST", "").split(",")
    if item.strip()
]
allow_shell_network = os.environ.get("AGENTMILL_ALLOW_SHELL_NETWORK", "").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}

HIGH_RISK_SHELL_DENY = [
    "sudo:*",
    "su:*",
    "rm -rf:*",
    "chmod:*",
    "chown:*",
    "dd:*",
    "mkfs:*",
    "mount:*",
    "umount:*",
    "docker:*",
    "podman:*",
    "kubectl:*",
    "helm:*",
]
SHELL_NETWORK_DENY = [
    "curl:*",
    "wget:*",
    "nc:*",
    "ncat:*",
    "netcat:*",
    "telnet:*",
    "ftp:*",
    "sftp:*",
    "scp:*",
    "rsync:*",
]
STRICT_NETWORK_DENY = [
    "git clone:*",
    "git fetch:*",
    "git pull:*",
    "git push:*",
    "npm install:*",
    "pnpm install:*",
    "yarn install:*",
    "pip install:*",
    "uv sync:*",
    "uv pip install:*",
    "cargo fetch:*",
    "cargo install:*",
    "go mod download:*",
]


def bash_pattern(pattern: str) -> str:
    return f"Bash({pattern})"


def append_shell_denies(patterns: list[str]) -> None:
    for pattern in patterns:
        permission = bash_pattern(pattern)
        if permission not in deny:
            deny.append(permission)


def append_shell_allows(patterns: list[str]) -> None:
    for pattern in patterns:
        permission = bash_pattern(pattern)
        if permission not in allow:
            allow.append(permission)

if profile == "trusted":
    allow = ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "Agent", "WebFetch", "WebSearch", "NotebookEdit", "mcp__*"]
    deny = []
    default_mode = "bypassPermissions"
elif profile == "standard":
    allow = ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "Agent", "NotebookEdit"]
    deny = ["WebFetch", "WebSearch"]
    default_mode = "bypassPermissions"
elif profile == "untrusted":
    allow = ["Read", "Edit", "Write", "Glob", "Grep"]
    deny = ["Bash", "Agent", "WebFetch", "WebSearch", "NotebookEdit"]
    default_mode = "acceptEdits"
else:
    allow = ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "Agent", "WebFetch", "WebSearch", "NotebookEdit", "mcp__*"]
    deny = []
    default_mode = "bypassPermissions"

if extra_shell_allows:
    allow = [item for item in allow if item != "Bash"]
    deny = [item for item in deny if item != "Bash"]
    append_shell_allows(extra_shell_allows)

for name in allowlist:
    if "mcp__*" not in allow:
        allow.append(f"mcp__{name}__*")
        allow.append(f"mcp__{name}.*")

if not allowlist and profile != "trusted":
    deny.append("mcp__*")

effective_network = network or ("deny" if profile == "untrusted" else network)
if profile != "trusted":
    append_shell_denies(HIGH_RISK_SHELL_DENY)
    if not allow_shell_network and effective_network in {"", "deny", "allowlist"}:
        append_shell_denies(SHELL_NETWORK_DENY)
    if effective_network == "deny":
        append_shell_denies(STRICT_NETWORK_DENY)

append_shell_denies(extra_shell_denies)

pretool_command = os.environ.get("AGENTMILL_PRETOOL_POLICY_COMMAND", "/agentmill-pretool-policy.py").strip()
pretool_enabled = bool(pretool_command) and (
    profile != "trusted"
    or bool(extra_shell_allows)
    or bool(extra_shell_denies)
    or bool(os.environ.get("AGENTMILL_WRITE_ROOTS", "").strip())
)

settings = {
    "permissions": {
        "allow": allow,
        "defaultMode": default_mode,
    },
    "enableAllProjectMcpServers": profile == "trusted" or bool(allowlist),
}
if deny:
    settings["permissions"]["deny"] = deny
if pretool_enabled:
    settings["hooks"] = {
        "PreToolUse": [
            {
                "matcher": "*",
                "hooks": [
                    {
                        "type": "command",
                        "command": pretool_command,
                        "timeout": 5,
                    }
                ],
            }
        ]
    }
print(json.dumps(settings, separators=(",", ":")))
PY
}

# --- Sentinel watcher: polls done file, signals target on completion ---
start_sentinel_watcher() {
    local target_pid="$1" mode="${2:-pid}" interval="${3:-1}"
    local done_file="${DONE_FILE:-/tmp/.agentmill-done}"
    local flag_file="${SENTINEL_SIGNAL_FLAG_FILE:-/tmp/.agentmill-sentinel-signal}"
    (
        while kill -0 "$target_pid" 2>/dev/null; do
            if [[ -f "$done_file" ]]; then
                sleep 2
                if [[ "$mode" == "process_group" ]]; then
                    : > "$flag_file"
                    kill -TERM 0 2>/dev/null || true
                else
                    kill -TERM "$target_pid" 2>/dev/null || true
                fi
                break
            fi
            sleep "$interval"
        done
    ) &
    SENTINEL_WATCHER_PID=$!
}

stop_sentinel_watcher() {
    [[ -n "${SENTINEL_WATCHER_PID:-}" ]] || return 0
    kill "$SENTINEL_WATCHER_PID" 2>/dev/null || true
    wait "$SENTINEL_WATCHER_PID" 2>/dev/null || true
    unset SENTINEL_WATCHER_PID
}

start_wall_clock_watcher() {
    local target_pid="$1" mode="${2:-pid}" interval="${3:-1}"
    local max_wall="${MAX_WALL_SECONDS:-0}" start_time="${RUN_START_TIME:-}"
    local flag_file="${WALL_CLOCK_SIGNAL_FLAG_FILE:-/tmp/.agentmill-wall-clock-signal}"
    local now elapsed remaining
    if ! is_nonnegative_int "$max_wall" || [[ "$max_wall" -eq 0 ]]; then
        return 0
    fi
    if ! is_nonnegative_int "$start_time"; then
        return 0
    fi
    now="$(date +%s)"
    elapsed=$((now - start_time))
    remaining=$((max_wall - elapsed))
    [[ "$remaining" -gt 0 ]] || remaining=0
    (
        [[ "$remaining" -gt 0 ]] && sleep "$remaining"
        while kill -0 "$target_pid" 2>/dev/null; do
            now="$(date +%s)"
            elapsed=$((now - start_time))
            if [[ "$elapsed" -ge "$max_wall" ]]; then
                : > "$flag_file"
                event_emit_kv budget.exhausted budget=wall_seconds elapsed_seconds="$elapsed" max_wall_seconds="$max_wall" scope=client
                if [[ "$mode" == "process_group" ]]; then
                    kill -TERM 0 2>/dev/null || true
                else
                    kill -TERM "$target_pid" 2>/dev/null || true
                fi
                break
            fi
            sleep "$interval"
        done
    ) &
    WALL_CLOCK_WATCHER_PID=$!
}

stop_wall_clock_watcher() {
    [[ -n "${WALL_CLOCK_WATCHER_PID:-}" ]] || return 0
    kill "$WALL_CLOCK_WATCHER_PID" 2>/dev/null || true
    wait "$WALL_CLOCK_WATCHER_PID" 2>/dev/null || true
    unset WALL_CLOCK_WATCHER_PID
}

start_client_watchers() {
    local target_pid="$1"
    start_sentinel_watcher "$target_pid"
    start_wall_clock_watcher "$target_pid"
}

stop_client_watchers() {
    stop_sentinel_watcher
    stop_wall_clock_watcher
}

push_failure_is_retryable() {
    case "$1" in
        *"[rejected]"*" (fetch first)"*|*"[rejected]"*" (non-fast-forward)"*|*"non-fast-forward"*) return 0 ;;
    esac
    return 1
}

# --- Shared markdown memory layer ---
# Append-only, lock-guarded, per-topic .md files in a shared memory/ directory.
# Safe for multi-agent concurrent writes. Uses flock (Linux) or mkdir (macOS/portable).

MEMORY_DIR="${MEMORY_DIR:-/workspace/memory}"

# Portable exclusive lock: flock if available, mkdir fallback
_lock_acquire() {
    local lockpath="$1" timeout="${2:-5}" i=0
    if command -v flock >/dev/null 2>&1; then
        exec 200>"$lockpath"
        flock -x -w "$timeout" 200
        return $?
    fi
    # mkdir-based fallback (atomic on POSIX)
    while ! mkdir "$lockpath.d" 2>/dev/null; do
        i=$((i + 1))
        [[ "$i" -ge "$((timeout * 10))" ]] && return 1
        sleep 0.1
    done
}

_lock_release() {
    local lockpath="$1"
    if command -v flock >/dev/null 2>&1; then
        exec 200>&-
    else
        rmdir "$lockpath.d" 2>/dev/null || true
    fi
}

memory_init() {
    mkdir -p "$MEMORY_DIR"
}

memory_topic_type() {
    case "$1" in
        findings) printf '%s\n' "findings" ;;
        sources) printf '%s\n' "sources" ;;
        contradictions) printf '%s\n' "contradictions" ;;
        open_questions) printf '%s\n' "open_questions" ;;
        *) printf '%s\n' "decisions" ;;
    esac
}

memory_topic_has_schema() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    python3 - "$file" <<'PY'
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore").splitlines()
if len(lines) < 2 or lines[0] != "---":
    raise SystemExit(1)
for line in lines[1:8]:
    if line == "---":
        raise SystemExit(0)
raise SystemExit(1)
PY
}

memory_topic_ensure_schema() {
    local topic="$1" file="$2" now topic_type tmp
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    topic_type="$(memory_topic_type "$topic")"
    if [[ ! -f "$file" ]]; then
        printf -- '---\ntype: %s\ncreated: %s\nlast_iteration: %s\n---\n' \
            "$topic_type" "$now" "${ITERATION:-0}" > "$file"
        return 0
    fi
    if ! memory_topic_has_schema "$file"; then
        tmp="$(mktemp)"
        {
            printf -- '---\ntype: %s\ncreated: %s\nlast_iteration: %s\n---\n' \
                "$topic_type" "$now" "${ITERATION:-0}"
            cat "$file"
        } > "$tmp"
        mv "$tmp" "$file"
    fi
}

memory_topic_update_last_iteration() {
    local file="$1" iteration="${ITERATION:-0}"
    python3 - "$file" "$iteration" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
iteration = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
if not lines or lines[0] != "---":
    raise SystemExit(0)
end = None
for index, line in enumerate(lines[1:8], start=1):
    if line == "---":
        end = index
        break
if end is None:
    raise SystemExit(0)

for index in range(1, end):
    if lines[index].startswith("last_iteration:"):
        lines[index] = f"last_iteration: {iteration}"
        break
else:
    lines.insert(end, f"last_iteration: {iteration}")
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

# memory_write <topic> <content> [agent_id]
# Appends a timestamped entry to memory/<topic>.md under exclusive lock.
memory_write() {
    local topic="$1" content="$2" agent="${3:-${AGENT_ID:-unknown}}"
    local file="$MEMORY_DIR/${topic}.md"
    local lock="$MEMORY_DIR/.${topic}.lock"
    memory_init

    if _lock_acquire "$lock" 5; then
        memory_topic_ensure_schema "$topic" "$file"
        memory_topic_update_last_iteration "$file"
        printf '\n---\nagent: %s\ntimestamp: %s\n---\n%s\n' \
            "$agent" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$content" >> "$file"
        _lock_release "$lock"
    else
        log "WARN: memory lock timeout for $topic"
        return 1
    fi
}

# memory_read <topic> [tail_lines]
# Reads memory/<topic>.md (no lock needed for reads).
memory_read() {
    local topic="$1" lines="${2:-50}"
    local file="$MEMORY_DIR/${topic}.md"
    [[ -f "$file" ]] || { echo "(no memory for topic: $topic)"; return 0; }
    tail -n "$lines" "$file"
}

# memory_list — show all topics
memory_list() {
    memory_init
    find "$MEMORY_DIR" -name '*.md' -exec basename {} .md \; 2>/dev/null | sort
}

# memory_search <pattern> — grep across all memory files
memory_search() {
    memory_init
    grep -rl "$1" "$MEMORY_DIR"/*.md 2>/dev/null | while read -r f; do
        echo "=== $(basename "$f" .md) ==="
        grep -n "$1" "$f"
    done
}

# memory_clear <topic> — remove a topic file (with lock)
memory_clear() {
    local topic="$1"
    local file="$MEMORY_DIR/${topic}.md"
    local lock="$MEMORY_DIR/.${topic}.lock"
    [[ -f "$file" ]] || { echo "(no memory for topic: $topic)"; return 0; }
    if _lock_acquire "$lock" 5; then
        rm -f "$file"
        _lock_release "$lock"
    else
        log "WARN: memory lock timeout clearing $topic"
        return 1
    fi
}

# --- Standard memory topics (long-running-Claude conventions) ---
# These are plain memory topics, but documented as first-class so prompts can
# rely on them existing. Adopted from smsharma/clax CLAUDE.md.
#
#   failed_approaches.md — dead ends with one-line reason (read at Orient,
#                          prevents re-trying what's already known broken)
#   in_progress.md       — flock-guarded task-claim file for multi-agent
#   open_questions.md    — research worklist
#   contradictions.md    — sources that disagree
#   findings.md          — primary research notes (verbatim quotes)
#   sources.md           — deduplicated URL list
#   decisions.md         — methodology / scope decisions

# failed_approaches_append <one-line-summary> <reason>
# Appends a structured failed-approach entry. Use when an approach is abandoned.
failed_approaches_append() {
    local summary="$1" reason="${2:-no reason given}"
    memory_write failed_approaches "$(printf -- '- **%s**\n  reason: %s' "$summary" "$reason")"
}

# --- Task-claim file (multi-agent coordination) ---
# Single file: one line per active claim, format:
#   <iso-timestamp>\t<agent-id>\t<task-id>
# Atomic via flock; readers can `grep <task-id> in_progress.md` before claiming.

CLAIMS_FILE="${CLAIMS_FILE:-${MEMORY_DIR:-/workspace/memory}/in_progress.md}"

claim_task() {
    local task="$1" agent="${2:-${AGENT_ID:-unknown}}"
    local lock="${CLAIMS_FILE}.lock"
    memory_init
    [[ -f "$CLAIMS_FILE" ]] || printf '# In-progress task claims\n\n' > "$CLAIMS_FILE"
    if _lock_acquire "$lock" 5; then
        if grep -qF "	${task}" "$CLAIMS_FILE" 2>/dev/null; then
            _lock_release "$lock"
            log_warn "claim_task: '$task' already claimed"
            return 1
        fi
        printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$task" >> "$CLAIMS_FILE"
        _lock_release "$lock"
    else
        log_warn "claim_task: lock timeout"
        return 1
    fi
}

release_task() {
    local task="$1"
    local lock="${CLAIMS_FILE}.lock"
    [[ -f "$CLAIMS_FILE" ]] || return 0
    if _lock_acquire "$lock" 5; then
        local tmp; tmp="$(mktemp)"
        grep -vF "	${task}" "$CLAIMS_FILE" > "$tmp" || true
        mv "$tmp" "$CLAIMS_FILE"
        _lock_release "$lock"
    else
        log_warn "release_task: lock timeout"
        return 1
    fi
}

list_claims() {
    [[ -f "$CLAIMS_FILE" ]] || { echo "(no active claims)"; return 0; }
    grep -v '^#\|^$' "$CLAIMS_FILE" || true
}

memory_topic_allowed_for_role() {
    local topic="$1" role="${AGENTMILL_ROLE:-}"
    case "$role" in
        researcher-*|researcher)
            case "$topic" in
                findings|sources|contradictions|open_questions) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        coder|refactor|reviewer)
            case "$topic" in
                decisions|failed_approaches|open_questions) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        memory-curator|"")
            return 0
            ;;
        *)
            case "$topic" in
                decisions|failed_approaches|open_questions) return 0 ;;
                *) return 1 ;;
            esac
            ;;
    esac
}

# memory_summary — one-line-per-topic overview (for iteration context)
memory_summary() {
    memory_init
    local file
    for file in "$MEMORY_DIR"/*.md; do
        [[ -f "$file" ]] || continue
        local topic count
        topic="$(basename "$file" .md)"
        memory_topic_allowed_for_role "$topic" || continue
        count="$(grep -c '^---$' "$file" 2>/dev/null)" || count=0
        if memory_topic_has_schema "$file" && [[ "$count" -ge 2 ]]; then
            count=$(( count - 2 ))
        fi
        count=$(( count / 2 ))
        printf '  [[%s]] (%d entries)\n' "$topic" "$count"
    done
}

# iteration_context — generate context from previous iteration for next run
# Writes to /tmp/.agentmill-iter-context.md
iteration_context() {
    local ctx="/tmp/.agentmill-iter-context.md"
    {
        echo "## Previous Iteration Context"
        echo ""
        echo "### Recent commits"
        git log --oneline -5 2>/dev/null || echo "(none)"
        echo ""
        echo "### Memory topics"
        memory_summary
        echo ""
        if memory_topic_allowed_for_role failed_approaches && [[ -f "${MEMORY_DIR:-/workspace/memory}/failed_approaches.md" ]]; then
            echo "### Recent failed approaches (do not retry)"
            tail -20 "${MEMORY_DIR:-/workspace/memory}/failed_approaches.md"
            echo ""
        fi
        if [[ -f "$CLAIMS_FILE" ]] && [[ -s "$CLAIMS_FILE" ]]; then
            echo "### Tasks currently claimed by other agents"
            list_claims
            echo ""
        fi
        if [[ -f "$RESULTS_LOG" ]]; then
            echo "### Last result"
            tail -1 "$RESULTS_LOG"
        fi
    } > "$ctx"
    echo "$ctx"
}

# --- Iteration and convergence logs (Karpathy autoresearch pattern) ---
# Append-only TSV: iteration | agent | timestamp | files_changed | commits | status | description
RESULTS_LOG="${RESULTS_LOG:-/workspace/logs/results.tsv}"
CONVERGENCE_LOG="${CONVERGENCE_LOG:-/workspace/logs/convergence.tsv}"

tsv_cell() {
    local value="$*"
    value="${value//$'\t'/ }"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    printf '%s' "$value"
}

results_log_init() {
    mkdir -p "$(dirname "$RESULTS_LOG")"
    [[ -f "$RESULTS_LOG" ]] || printf 'iteration\tagent\ttimestamp\tfiles_changed\tcommits\tstatus\tdescription\tinput_tokens\toutput_tokens\tcache_creation_input_tokens\tcache_read_input_tokens\ttotal_tokens\tcost_usd\n' > "$RESULTS_LOG"
}

# results_log_append <iteration> <agent> <files_changed> <commits> <status> <description> [usage fields...]
results_log_append() {
    local iter="$1" agent="$2" files="$3" commits="$4" status="$5" desc="$6"
    local input_tokens="${7:-}" output_tokens="${8:-}" cache_creation="${9:-}" cache_read="${10:-}" total_tokens="${11:-}" cost_usd="${12:-}"
    local lock="${RESULTS_LOG}.lock"
    results_log_init
    if _lock_acquire "$lock" 5; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$iter" "$agent" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$files" "$commits" "$status" "$desc" \
            "$input_tokens" "$output_tokens" "$cache_creation" "$cache_read" "$total_tokens" "$cost_usd" >> "$RESULTS_LOG"
        _lock_release "$lock"
    else
        log "WARN: results log lock timeout"
    fi
}

convergence_log_init() {
    mkdir -p "$(dirname "$CONVERGENCE_LOG")"
    [[ -f "$CONVERGENCE_LOG" ]] || printf 'iteration\tagent\ttimestamp\tgate\tpassed\tvalue\tthreshold\tevidence\thook_decision\n' > "$CONVERGENCE_LOG"
}

# convergence_log_append <iteration> <agent> <gate> <passed> <value> <threshold> <evidence> <hook_decision>
convergence_log_append() {
    local iter="$1" agent="$2" gate="$3" passed="$4" value="$5" threshold="$6" evidence="$7" hook_decision="$8"
    local lock="${CONVERGENCE_LOG}.lock"
    convergence_log_init
    if _lock_acquire "$lock" 5; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(tsv_cell "$iter")" \
            "$(tsv_cell "$agent")" \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            "$(tsv_cell "$gate")" \
            "$(tsv_cell "$passed")" \
            "$(tsv_cell "$value")" \
            "$(tsv_cell "$threshold")" \
            "$(tsv_cell "$evidence")" \
            "$(tsv_cell "$hook_decision")" >> "$CONVERGENCE_LOG"
        _lock_release "$lock"
    else
        log "WARN: convergence log lock timeout"
    fi
}

count_unresolved_open_questions() {
    local file="${1:-${MEMORY_DIR:-/workspace/memory}/open_questions.md}"
    python3 - "$file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print(0)
    raise SystemExit(0)

lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
start = 0
if lines and lines[0] == "---":
    start = len(lines)
    for idx, line in enumerate(lines[1:], start=1):
        if line == "---":
            start = idx + 1
            break
count = 0
for line in lines[start:]:
    stripped = line.strip()
    if not stripped or stripped == "---" or stripped.startswith("#"):
        continue
    if stripped.startswith(("- [x]", "- [X]")):
        continue
    if stripped.startswith("- [ ]") or stripped.startswith("-"):
        count += 1
print(count)
PY
}

research_zero_source_streak() {
    local results_log="${1:-$RESULTS_LOG}" required="${2:-3}"
    python3 - "$results_log" "$required" <<'PY'
import csv
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    required = int(sys.argv[2])
except ValueError:
    required = 3
required = max(required, 0)
if not path.exists():
    print(0)
    raise SystemExit(0)

try:
    rows = list(csv.DictReader(path.open(newline="", encoding="utf-8"), delimiter="\t"))
except csv.Error:
    rows = []

streak = 0
for row in reversed(rows):
    if "sources_added" not in row:
        continue
    raw = str(row.get("sources_added") or "").strip()
    try:
        value = int(float(raw))
    except ValueError:
        break
    if value == 0:
        streak += 1
        if required and streak >= required:
            break
    else:
        break
print(streak)
PY
}

completion_verifier_run() {
    local command="${AGENTMILL_VERIFIER_COMMAND:-}" log_file raw rc line
    COMPLETION_VERIFIER_STATUS="missing"
    COMPLETION_VERIFIER_LOG=""
    COMPLETION_VERIFIER_EXIT_CODE=""

    if [[ -z "$command" ]]; then
        return 2
    fi

    mkdir -p "$LOG_DIR"
    log_file="$LOG_DIR/completion-verifier-${AGENT_ID:-agent}-iter${ITERATION:-0}.log"
    raw="$(mktemp)"
    if bash -lc "$command" > "$raw" 2>&1; then
        rc=0
        COMPLETION_VERIFIER_STATUS="pass"
    else
        rc=$?
        COMPLETION_VERIFIER_STATUS="fail"
    fi

    : > "$log_file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$(redact_text "$line")" >> "$log_file"
    done < "$raw"
    rm -f "$raw"

    COMPLETION_VERIFIER_LOG="$log_file"
    COMPLETION_VERIFIER_EXIT_CODE="$rc"
    return "$rc"
}

git_line_delta_since() {
    local base="${1:-${AGENTMILL_BASE_SHA:-HEAD}}"
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '0\n'
        return 0
    fi
    git diff --numstat "$base" -- 2>/dev/null | awk '
        $1 != "-" && $2 != "-" { added += $1; deleted += $2 }
        END { print added - deleted + 0 }
    '
}

completion_gate_evaluate() {
    local gate="${1:-${AGENTMILL_COMPLETION_GATE:-done_file}}"
    local done_file="${DONE_FILE:-/tmp/.agentmill-done}"
    COMPLETION_GATE_NAME="$gate"
    COMPLETION_GATE_PASSED=false
    COMPLETION_GATE_VALUE="false"
    COMPLETION_GATE_THRESHOLD="true"
    COMPLETION_GATE_EVIDENCE="$done_file"

    case "$gate" in
        ""|done_file|sentinel)
            COMPLETION_GATE_NAME="done_file"
            if [[ -f "$done_file" ]]; then
                COMPLETION_GATE_PASSED=true
                COMPLETION_GATE_VALUE="true"
            fi
            ;;
        research_*|source_saturation|research_saturation)
            local required="${AGENTMILL_RESEARCH_SATURATION_ITERATIONS:-3}" max_open="${AGENTMILL_RESEARCH_OPEN_QUESTIONS_MAX:-0}"
            if ! is_nonnegative_int "$required" || [[ "$required" -lt 1 ]]; then
                required=3
            fi
            if ! is_nonnegative_int "$max_open"; then
                max_open=0
            fi
            local streak open_count open_file
            open_file="${MEMORY_DIR:-/workspace/memory}/open_questions.md"
            streak="$(research_zero_source_streak "$RESULTS_LOG" "$required")"
            open_count="$(count_unresolved_open_questions "$open_file")"
            COMPLETION_GATE_VALUE="zero_source_streak=${streak};open_questions=${open_count}"
            COMPLETION_GATE_THRESHOLD="zero_source_streak>=${required};open_questions<=${max_open}"
            COMPLETION_GATE_EVIDENCE="results=${RESULTS_LOG};open_questions=${open_file}"
            if [[ "$streak" -ge "$required" && "$open_count" -le "$max_open" ]]; then
                COMPLETION_GATE_PASSED=true
            fi
            ;;
        coder_*|coding_*|coder_verified|coding_verified)
            COMPLETION_GATE_NAME="coder_verified"
            local max_open="${AGENTMILL_CODER_OPEN_QUESTIONS_MAX:-0}" open_count open_file done_signaled verifier_status verifier_log
            if ! is_nonnegative_int "$max_open"; then
                max_open=0
            fi
            done_signaled=false
            [[ -f "$done_file" ]] && done_signaled=true
            open_file="${MEMORY_DIR:-/workspace/memory}/open_questions.md"
            open_count="$(count_unresolved_open_questions "$open_file")"
            verifier_status="not_run"
            verifier_log=""
            if [[ "$done_signaled" == true ]]; then
                if completion_verifier_run; then
                    :
                else
                    :
                fi
                verifier_status="$COMPLETION_VERIFIER_STATUS"
                verifier_log="$COMPLETION_VERIFIER_LOG"
            fi
            COMPLETION_GATE_VALUE="done=${done_signaled};verifier=${verifier_status};open_questions=${open_count}"
            COMPLETION_GATE_THRESHOLD="done=true;verifier=pass;open_questions<=${max_open}"
            COMPLETION_GATE_EVIDENCE="done_file=${done_file};verifier_log=${verifier_log:-none};open_questions=${open_file}"
            if [[ "$done_signaled" == true && "$verifier_status" == "pass" && "$open_count" -le "$max_open" ]]; then
                COMPLETION_GATE_PASSED=true
            fi
            ;;
        refactor_*|refactor_verified)
            COMPLETION_GATE_NAME="refactor_verified"
            local done_signaled verifier_status verifier_log loc_delta target tolerance min_delta max_delta max_allowed
            done_signaled=false
            [[ -f "$done_file" ]] && done_signaled=true
            loc_delta="$(git_line_delta_since "${AGENTMILL_REFACTOR_BASE_REF:-${AGENTMILL_BASE_SHA:-HEAD}}")"
            verifier_status="not_run"
            verifier_log=""
            if [[ "$done_signaled" == true ]]; then
                if completion_verifier_run; then
                    :
                else
                    :
                fi
                verifier_status="$COMPLETION_VERIFIER_STATUS"
                verifier_log="$COMPLETION_VERIFIER_LOG"
            fi
            if [[ -n "${AGENTMILL_REFACTOR_LOC_TARGET:-}" ]]; then
                target="${AGENTMILL_REFACTOR_LOC_TARGET:-0}"
                tolerance="${AGENTMILL_REFACTOR_LOC_TOLERANCE:-0}"
                if ! is_signed_int "$target"; then
                    target=0
                fi
                if ! is_nonnegative_int "$tolerance"; then
                    tolerance=0
                fi
                min_delta=$(( target - tolerance ))
                max_delta=$(( target + tolerance ))
                COMPLETION_GATE_THRESHOLD="done=true;verifier=pass;loc_delta>=${min_delta};loc_delta<=${max_delta}"
                if [[ "$done_signaled" == true && "$verifier_status" == "pass" && "$loc_delta" -ge "$min_delta" && "$loc_delta" -le "$max_delta" ]]; then
                    COMPLETION_GATE_PASSED=true
                fi
            else
                max_allowed="${AGENTMILL_REFACTOR_MAX_LOC_DELTA:-0}"
                if ! is_signed_int "$max_allowed"; then
                    max_allowed=0
                fi
                COMPLETION_GATE_THRESHOLD="done=true;verifier=pass;loc_delta<=${max_allowed}"
                if [[ "$done_signaled" == true && "$verifier_status" == "pass" && "$loc_delta" -le "$max_allowed" ]]; then
                    COMPLETION_GATE_PASSED=true
                fi
            fi
            COMPLETION_GATE_VALUE="done=${done_signaled};verifier=${verifier_status};loc_delta=${loc_delta}"
            COMPLETION_GATE_EVIDENCE="done_file=${done_file};verifier_log=${verifier_log:-none};base=${AGENTMILL_REFACTOR_BASE_REF:-${AGENTMILL_BASE_SHA:-HEAD}}"
            ;;
        *)
            if [[ -f "$done_file" ]]; then
                COMPLETION_GATE_PASSED=true
                COMPLETION_GATE_VALUE="true"
            fi
            COMPLETION_GATE_EVIDENCE="unknown_gate=${gate};fallback=${done_file}"
            ;;
    esac
}
