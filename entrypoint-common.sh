#!/usr/bin/env bash

# Compatibility loader. Entrypoints keep sourcing this stable path while the
# implementation lives in focused modules under lib/agentmill/sh.
AGENTMILL_COMMON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${AGENTMILL_LIB_DIR:-}" ]]; then
    if [[ -f "$AGENTMILL_COMMON_DIR/lib/agentmill/sh/runtime.sh" ]]; then
        AGENTMILL_LIB_DIR="$AGENTMILL_COMMON_DIR/lib/agentmill/sh"
    else
        AGENTMILL_LIB_DIR="/lib/agentmill/sh"
    fi
fi

# shellcheck source=lib/agentmill/sh/runtime.sh
. "$AGENTMILL_LIB_DIR/runtime.sh"
