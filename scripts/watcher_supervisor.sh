#!/usr/bin/env bash
set -euo pipefail

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

source "$SCRIPT_DIR/lib/agent_registry.sh"
source "$SCRIPT_DIR/lib/mux_adapter.sh"

mkdir -p logs queue/inbox

HEARTBEAT_FILE="${SCRIPT_DIR}/queue/supervisor.heartbeat"

# Heartbeat write on startup so any hook check shortly after spawn sees us alive.
date +%s > "$HEARTBEAT_FILE" 2>/dev/null || true

get_multiagent_pane_base() {
    if [ -n "${SHOGUN_PANE_BASE:-}" ]; then
        echo "$SHOGUN_PANE_BASE"
        return 0
    fi
    local pane_base
    pane_base=$(mux_show_global_option pane-base-index 2>/dev/null || true)
    echo "${pane_base:-0}"
}

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

pane_exists() {
    local pane="$1"
    mux_list_panes 2>/dev/null | grep -qx "$pane"
}

watcher_is_current() {
    local pid="$1"
    local script_path="${SCRIPT_DIR}/scripts/inbox_watcher.sh"
    local script_age proc_age

    # If the watcher script was edited after a daemon started, the daemon keeps
    # running old code. Treat it as stale and start a fresh watcher alongside it;
    # the old process is left untouched by design.
    script_age=$(( $(date +%s) - $(stat -c %Y "$script_path" 2>/dev/null || date +%s) ))
    proc_age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$proc_age" ] || return 1
    [ "$proc_age" -le "$script_age" ]
}

has_current_watcher() {
    local agent="$1"
    local pane="$2"
    local pid
    local found_for_pane=0

    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        found_for_pane=1
        if watcher_is_current "$pid"; then
            return 0
        fi
    done < <(pgrep -f "scripts/inbox_watcher.sh ${agent} ${pane}( |$)" 2>/dev/null || true)

    # A stale-but-correct watcher still owns the lifetime lock. Starting a fresh
    # one would either duplicate keystroke delivery on older code or immediately
    # exit on the lock with newer code. Log and wait for an operator/runtime
    # restart instead of creating parallel watchers.
    if [ "$found_for_pane" -eq 1 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] stale watcher still running for ${agent} pane=${pane}; not starting duplicate" >&2
        return 0
    fi

    return 1
}

start_watcher_if_missing() {
    local agent="$1"
    local pane="$2"
    local log_file="$3"
    local cli
    local lockfile="/tmp/shogun_watcher_start_${agent}.lock"

    ensure_inbox_file "$agent"
    if ! pane_exists "$pane"; then
        return 0
    fi

    (
        flock -n 9 || return 0
        if has_current_watcher "$agent" "$pane"; then
            return 0
        fi

        if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] stale watcher detected for ${agent}; starting watcher for expected pane ${pane}" >&2
        fi

        cli=$(mux_get_meta "$pane" agent_cli 2>/dev/null || echo "codex")
        nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [START] inbox_watcher started for ${agent} pane=${pane} PID=$!" >&2
    ) 9>"$lockfile"
}

start_stall_detector_if_missing() {
    # stall_detector.sh は 60 秒周期で task/report stall を scan する永続 daemon。
    # supervisor は inbox_watcher と同じ作法で liveness のみ監督し、missing/死亡なら起動する。
    # scan ロジックは detector の責務ゆえ supervisor には持ち込まない。
    # pattern を行末 $ で anchor するのは `stall_detector.sh --once` (test/verify 用の
    # 短命プロセス) を daemon と誤検知しないため。
    if pgrep -f "scripts/stall_detector.sh$" >/dev/null 2>&1; then
        return 0
    fi
    nohup bash scripts/stall_detector.sh >> logs/stall_detector.log 2>&1 &
}

watcher_specs() {
    local pane_base
    local agent
    pane_base=$(get_multiagent_pane_base)

    while IFS= read -r agent; do
        [ -z "$agent" ] && continue
        local pane
        if [ "$(mux_backend_name)" != "tmux" ]; then
            pane=$(mux_find_pane_by_agent "$agent" 2>/dev/null || true)
            [ -n "$pane" ] || continue
        elif ! pane=$(agent_registry_pane_for_agent "$agent" "$pane_base"); then
            continue
        fi
        printf '%s\t%s\tlogs/inbox_watcher_%s.log\n' "$agent" "$pane" "$agent"
    done < <(agent_registry_agents)
}

start_all_watchers() {
    local agent pane log_file
    while IFS=$'\t' read -r agent pane log_file; do
        start_watcher_if_missing "$agent" "$pane" "$log_file"
    done < <(watcher_specs)
}

if [ "${1:-}" = "--print-watchers" ]; then
    watcher_specs
    exit 0
fi

while true; do
    date +%s > "$HEARTBEAT_FILE" 2>/dev/null || true
    start_all_watchers
    start_stall_detector_if_missing
    sleep 5
done
