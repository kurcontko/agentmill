#!/usr/bin/env bash

AGENTMILL_LIB_DIR="${AGENTMILL_LIB_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# shellcheck source=lib/agentmill/sh/core/log.sh
. "$AGENTMILL_LIB_DIR/core/log.sh"
# shellcheck source=lib/agentmill/sh/runtime/models.sh
. "$AGENTMILL_LIB_DIR/runtime/models.sh"
# shellcheck source=lib/agentmill/sh/runtime/auth.sh
. "$AGENTMILL_LIB_DIR/runtime/auth.sh"
# shellcheck source=lib/agentmill/sh/runtime/settings.sh
. "$AGENTMILL_LIB_DIR/runtime/settings.sh"
# shellcheck source=lib/agentmill/sh/runtime/watchers.sh
. "$AGENTMILL_LIB_DIR/runtime/watchers.sh"
# shellcheck source=lib/agentmill/sh/runtime/git.sh
. "$AGENTMILL_LIB_DIR/runtime/git.sh"
# shellcheck source=lib/agentmill/sh/runtime/memory.sh
. "$AGENTMILL_LIB_DIR/runtime/memory.sh"
