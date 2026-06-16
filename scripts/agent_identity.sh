#!/usr/bin/env bash
# Resolve the current shogun agent id without hard-coding tmux in callers.

set -euo pipefail

SCRIPT_DIR="${__AGENT_IDENTITY_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [ -n "${SHOGUN_AGENT_ID:-}" ]; then
    printf '%s\n' "$SHOGUN_AGENT_ID"
    exit 0
fi

if [ -n "${__STOP_HOOK_AGENT_ID:-}" ]; then
    printf '%s\n' "$__STOP_HOOK_AGENT_ID"
    exit 0
fi

if [ -f "$SCRIPT_DIR/lib/mux_adapter.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/mux_adapter.sh"
    if [ -n "${TMUX_PANE:-}" ]; then
        mux_display_message "$TMUX_PANE" '#{@agent_id}' | head -n 1
        exit 0
    fi
fi

exit 1
