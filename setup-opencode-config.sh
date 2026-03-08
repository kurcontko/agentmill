#!/usr/bin/env bash
# Generates opencode.json config for OpenCode engine.
# Called from entrypoints when ENGINE=opencode.
set -euo pipefail

MODEL="${MODEL:-sonnet}"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-}"

# If user provides a custom opencode.json via OPENCODE_CONFIG, use it
if [[ -n "$OPENCODE_CONFIG" && -f "$OPENCODE_CONFIG" ]]; then
    cp "$OPENCODE_CONFIG" opencode.json
    return 0 2>/dev/null || exit 0
fi

# Auto-detect provider and model from env
PROVIDER=""
OC_MODEL=""

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    PROVIDER="openai"
    case "$MODEL" in
        gpt-4o|gpt-4o-mini|o1|o1-mini|o3|o3-mini|o4-mini)
            OC_MODEL="$MODEL" ;;
        *)
            OC_MODEL="gpt-4o" ;;
    esac
elif [[ -n "${GEMINI_API_KEY:-}" ]]; then
    PROVIDER="google"
    case "$MODEL" in
        gemini-2.5-pro|gemini-2.5-flash|gemini-2.0-flash)
            OC_MODEL="$MODEL" ;;
        *)
            OC_MODEL="gemini-2.5-pro" ;;
    esac
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    PROVIDER="anthropic"
    case "$MODEL" in
        opus|claude-opus-4-6)
            OC_MODEL="claude-opus-4-6" ;;
        sonnet|claude-sonnet-4-6)
            OC_MODEL="claude-sonnet-4-6" ;;
        haiku|claude-haiku-4-5-20251001)
            OC_MODEL="claude-haiku-4-5-20251001" ;;
        *)
            OC_MODEL="claude-sonnet-4-6" ;;
    esac
fi

# Generate opencode.json
python3 -c "
import json

config = {
    'provider': {
        'default': '$PROVIDER'
    },
    'model': {
        'default': '$OC_MODEL'
    }
}

json.dump(config, open('opencode.json', 'w'), indent=2)
" 2>/dev/null || {
    cat > opencode.json <<EOF
{
  "provider": {
    "default": "$PROVIDER"
  },
  "model": {
    "default": "$OC_MODEL"
  }
}
EOF
}
