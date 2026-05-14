#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# e2e_detector_wrapper.sh — cooperative stand-in for the stall_detector
# daemon loop. Used ONLY by tests/e2e/e2e_stall_detection.bats.
#
# Why this exists
# ---------------
# The production scripts/stall_detector.sh daemon loop has no file-based
# exit — it only stops on SIGTERM/SIGINT. Terminating it from the e2e would
# require the `kill` command, which CLAUDE.md D006 bans outright (even in
# test code). This wrapper keeps the whole e2e cooperative:
#
#   * The supervisor still launches `scripts/stall_detector.sh` exactly as
#     in production, so watcher_supervisor integration is exercised unchanged.
#   * The daemon loop, however, exits cleanly the moment a sentinel file
#     appears — no signal, no `kill`.
#
# Detection itself is NOT faked. Each cycle delegates to the real detector
# core (copied alongside this file as _stall_detector_core.sh by the e2e
# setup) via `--once`, so the real detection → inbox_write → Karo inbox path
# is exercised end to end.
#
# Sentinels (absolute paths supplied via env by the e2e harness):
#   STALL_E2E_DETECTOR_STOP — exit 0 when this file exists. Per-detector
#                             stop; used by the restart test and teardown.
#   STALL_E2E_SHUTDOWN      — exit 0 when this file exists. Global teardown.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

WRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$WRAP_DIR/_stall_detector_core.sh"
INTERVAL="${STALL_E2E_INTERVAL_SEC:-2}"

# SIGTERM/SIGINT は使わない設計だが、万一外から来ても綺麗に畳む。
trap 'exit 0' SIGTERM SIGINT

_should_stop() {
    if [ -n "${STALL_E2E_DETECTOR_STOP:-}" ] && [ -e "$STALL_E2E_DETECTOR_STOP" ]; then
        return 0
    fi
    if [ -n "${STALL_E2E_SHUTDOWN:-}" ] && [ -e "$STALL_E2E_SHUTDOWN" ]; then
        return 0
    fi
    return 1
}

if [ ! -f "$CORE" ]; then
    echo "e2e_detector_wrapper: core not found at $CORE" >&2
    exit 1
fi

while true; do
    _should_stop && exit 0
    # 実検知ロジックは production core に委譲する (--once = daemon 1 周期と等価)。
    bash "$CORE" --once || true
    slept=0
    while [ "$slept" -lt "$INTERVAL" ]; do
        _should_stop && exit 0
        sleep 1
        slept=$((slept + 1))
    done
done
