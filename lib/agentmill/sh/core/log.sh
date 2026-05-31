#!/usr/bin/env bash

LOG_DIR="${LOG_DIR:-/workspace/logs}"
mkdir -p "$LOG_DIR"

log() {
    local msg logfile
    if [[ -n "${AGENT_ID:-}" ]]; then
        msg="[agentmill:agent-${AGENT_ID} $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
        logfile="$LOG_DIR/agent-${AGENT_ID}.log"
    else
        msg="[agentmill $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
        logfile="$LOG_DIR/agent.log"
    fi
    echo "$msg"
    echo "$msg" >> "$logfile"
}

# Greppable error/warn helpers (clax convention): one line, literal ERROR/WARN
# token + reason. Use these so `grep -E '^.*ERROR' logs/agent-*.log` finds every
# real failure regardless of phrasing.
log_error() { log "ERROR $*"; }
log_warn()  { log "WARN $*";  }
