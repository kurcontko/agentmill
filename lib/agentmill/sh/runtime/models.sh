#!/usr/bin/env bash

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

    # Already a fully-qualified model ID - passthrough.
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

    # Unknown - warn (to stderr so the caller's $(resolve_model) is clean)
    # and pass through. Lets users pin newly-released model IDs without
    # blocking on this function being updated.
    log_warn "Unknown MODEL alias '$input' - passing through to claude CLI as-is" >&2
    printf '%s' "$input"
}

# Log the installed Claude Code CLI version + warn loudly if it's older than
# the floor that knows about the requested MODEL. Stale CLIs ship with stale
# alias tables and capability metadata and silently downshift to older models
# - this turns the silent failure into a visible WARN.
#
# Refs: https://github.com/anthropics/claude-code/issues/50810
log_claude_version() {
    local model="${1:-}"
    local raw version major minor patch
    raw="$(claude --version 2>/dev/null | head -1 || true)"
    version="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -z "$version" ]]; then
        log_warn "Could not parse claude CLI version (output: '$raw')"
        return 0
    fi
    log "Claude Code CLI version: $version"

    # Floor checks - bump these as new model lines ship.
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
                log_warn "claude CLI $version is older than the floor $floor for model '$m' - silent downshift likely. Bump CLAUDE_CODE_VERSION in Dockerfile and rebuild."
            fi
        fi
    done
}
