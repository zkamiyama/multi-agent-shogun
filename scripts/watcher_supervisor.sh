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
STALL_DETECTOR_HEARTBEAT="${STALL_DETECTOR_HEARTBEAT:-${SCRIPT_DIR}/queue/stall_detector.heartbeat}"
STALL_DETECTOR_STATE="${STALL_DETECTOR_STATE:-${SCRIPT_DIR}/queue/stall_detector_state.yaml}"
STALL_DETECTOR_RECOVERY_FILE="${STALL_DETECTOR_RECOVERY_FILE:-${SCRIPT_DIR}/queue/stall_detector_recovery.yaml}"
STALL_DETECTOR_STALE_SECONDS="${STALL_DETECTOR_STALE_SECONDS:-180}"
STALL_DETECTOR_STARTUP_GRACE_SECONDS="${STALL_DETECTOR_STARTUP_GRACE_SECONDS:-30}"
SUPERVISOR_LEASE_FILE="${SUPERVISOR_LEASE_FILE:-${SCRIPT_DIR}/queue/watcher_supervisor.lease}"

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
    local found_for_agent=0

    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        found_for_agent=1
        if watcher_is_current "$pid"; then
            return 0
        fi
    done < <(pgrep -f "scripts/inbox_watcher.sh ${agent} " 2>/dev/null || true)

    # A stale watcher for any pane still owns the agent-wide lifetime lock.
    # Starting a fresh watcher would either duplicate delivery on older code or
    # immediately exit on the lock with newer code.  Pane remaps are handled by
    # the existing watcher re-resolving agent_id immediately before each send.
    if [ "$found_for_agent" -eq 1 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] stale watcher still running for ${agent} (expected pane=${pane}); not starting duplicate" >&2
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
        # Do not leak the supervisor lifetime lease or the per-start lock into
        # a long-lived inbox watcher.  A child retaining FD7 would keep the
        # repository lease held after this supervisor generation exits.
        nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" \
            7>&- 8>&- 9>&- >> "$log_file" 2>&1 &
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [START] inbox_watcher started for ${agent} pane=${pane} PID=$!" >&2
    ) 9>"$lockfile"
}

start_stall_detector_if_missing() {
    # stall_detector.sh は 60 秒周期で task/report stall を scan する永続 daemon。
    # supervisor はプロセス存在だけでなく、正常 scan 後の heartbeat 鮮度も監督する。
    # scan ロジックは detector の責務ゆえ supervisor には持ち込まない。
    # pattern を行末 $ で anchor するのは `stall_detector.sh --once` (test/verify 用の
    # 短命プロセス) を daemon と誤検知しないため。
    # A fixture/repository root that disappeared must not get a new child.
    if [ -n "${SCRIPT_DIR:-}" ] \
            && { [ ! -d "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/queue" ]; }; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] supervisor root is absent; no detector replacement started" >&2
        return 0
    fi
    local detector_pid heartbeat_age process_age
    local heartbeat_file state_file recovery_file recovery_lock commit_lock
    local heartbeat_ts now state_snapshot scan_count last_scan fingerprint initial_fingerprint
    local final_fingerprint_before final_fingerprint_after final_heartbeat_age
    local marker_snapshot marker_exists previous_fingerprint replacement_started p0_delivered delivery_mode
    local recovered_at legacy_four_field debt_fingerprint debt_dedup_key replacement_evidence
    local replacement_pid replacement_started_at grace_deadline first_scan_pid first_scan_at
    local first_scan_fingerprint heartbeat_root script_root alert_dedup alert_summary inbox_writer
    local launch_replacement retry_p0 legacy_pending replacement_alive first_scan_seen
    local commit_lock_held=0
    heartbeat_file="${STALL_DETECTOR_HEARTBEAT:-${SCRIPT_DIR}/queue/stall_detector.heartbeat}"
    state_file="${STALL_DETECTOR_STATE:-$(dirname "$heartbeat_file")/stall_detector_state.yaml}"
    recovery_file="${STALL_DETECTOR_RECOVERY_FILE:-$(dirname "$heartbeat_file")/stall_detector_recovery.yaml}"
    inbox_writer="${STALL_SUPERVISOR_INBOX_WRITER:-${SCRIPT_DIR}/scripts/inbox_write.sh}"
    recovery_lock="${recovery_file}.lock"
    commit_lock="${STALL_DETECTOR_COMMIT_LOCK:-$(dirname "$state_file")/stall_detector_commit.lock}"

    (
        # Serialize only supervisor recovery metadata and P0 delivery.  The
        # detector's potentially blocking STATE_FILE.lock is never acquired
        # here, so stale recovery proceeds while a scan is stuck.
        flock -n 9 || exit 0

        # Local helper: preserve the receipt fields while atomically replacing
        # the small recovery marker.  The detector first-scan writer uses the
        # same recovery lock, so its receipt cannot be overwritten mid-commit.
        write_marker() {
            local marker_tmp="${recovery_file}.tmp.$$"
            if ! {
                echo "fingerprint=${fingerprint}"
                echo "debt_fingerprint=${debt_fingerprint:-}"
                echo "debt_dedup_key=${debt_dedup_key:-}"
                echo "replacement_started=${replacement_started:-false}"
                echo "replacement_pid=${replacement_pid:-}"
                echo "replacement_started_at=${replacement_started_at:-}"
                echo "replacement_grace_deadline=${grace_deadline:-}"
                echo "first_scan_pid=${first_scan_pid:-}"
                echo "first_scan_at=${first_scan_at:-}"
                echo "first_scan_fingerprint=${first_scan_fingerprint:-}"
                echo "p0_delivered=${p0_delivered:-false}"
                echo "delivery_mode=${delivery_mode:-undelivered}"
                echo "recovered_at=${now_iso_marker:-$(date -Iseconds)}"
            } > "$marker_tmp"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] recovery marker write failed; preserving current process" >&2
                return 1
            fi
            mv -f "$marker_tmp" "$recovery_file"
        }

        # Debt-only delivery must not rewrite the current detector episode into
        # the old replacement receipt.  Keep the old primary fingerprint until
        # the next stale episode reserves its own replacement marker.
        write_debt_marker() {
            local current_fingerprint="$fingerprint"
            if [ "$legacy_pending" -eq 1 ] \
                    && [ -n "$previous_fingerprint" ] \
                    && [ "$previous_fingerprint" != "$current_fingerprint" ]; then
                fingerprint="$previous_fingerprint"
            fi
            write_marker || true
            fingerprint="$current_fingerprint"
        }

        # Local helper: P0 debt is independently retryable.  Test-mode
        # suppression remains explicitly undelivered and is never trusted as a
        # production receipt.
        send_p0() {
            local debt_key="${debt_dedup_key:-stall-detector-heartbeat-stale:${debt_fingerprint:-$fingerprint}}"
            local debt_id="${debt_fingerprint:-$fingerprint}"
            alert_dedup="$debt_key"
            alert_summary="[P0] stall_detector_heartbeat_stale — stall_detector: heartbeat age=${heartbeat_age}s threshold=${STALL_DETECTOR_STALE_SECONDS}s fingerprint=${debt_id}; one replacement started without kill/signal/context reset."
            if [ -n "$heartbeat_root" ] && [ "$heartbeat_root" = "$script_root" ] \
                    && [ -n "${SCRIPT_DIR:-}" ] \
                    && [ -f "$inbox_writer" ]; then
                if DEDUP_KEY="$alert_dedup" bash "$inbox_writer" \
                        karo "$alert_summary" stall_alert watcher_supervisor >/dev/null 2>&1; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [P0] Karo notified for stale detector fingerprint=${fingerprint}" >&2
                    p0_delivered=true
                    delivery_mode=inbox
                else
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Karo stale-detector alert delivery failed fingerprint=${fingerprint}" >&2
                    p0_delivered=false
                    delivery_mode=undelivered
                fi
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [P0] stale detector alert (test-mode, inbox suppressed) fingerprint=${fingerprint}" >&2
                p0_delivered=false
                delivery_mode=suppressed
            fi
        }

        normalize_state_scalar() {
            local value="${1:-}"
            value="${value//\"/}"
            value="${value//\'/}"
            printf '%s\n' "$value"
        }

        detector_pid="$(pgrep -f "scripts/stall_detector.sh$" 2>/dev/null | head -n 1 || true)"
        heartbeat_age=999999
        if [ -f "$heartbeat_file" ]; then
            heartbeat_ts=$(stat -c %Y "$heartbeat_file" 2>/dev/null || echo 0)
            now=$(date +%s 2>/dev/null || echo 0)
            if [[ "$heartbeat_ts" =~ ^[0-9]+$ ]] && [[ "$now" =~ ^[0-9]+$ ]]; then
                if [ "$now" -ge "$heartbeat_ts" ]; then heartbeat_age=$((now - heartbeat_ts)); else heartbeat_age=0; fi
            fi
        fi
        process_age=999999
        if [ -n "$detector_pid" ]; then
            process_age=$(ps -o etimes= -p "$detector_pid" 2>/dev/null | tr -d '[:space:]' || true)
            [[ "$process_age" =~ ^[0-9]+$ ]] || process_age=999999
        fi

        state_snapshot=""
        [ -f "$state_file" ] && state_snapshot="$(<"$state_file")"
        scan_count=$(printf '%s\n' "$state_snapshot" | sed -n 's/^scan_count:[[:space:]]*//p' | head -n 1 || true)
        last_scan=$(printf '%s\n' "$state_snapshot" | sed -n 's/^last_scan:[[:space:]]*//p' | head -n 1 || true)
        scan_count=$(normalize_state_scalar "$scan_count")
        last_scan=$(normalize_state_scalar "$last_scan")
        scan_count="${scan_count:-unknown}"
        last_scan="${last_scan:-unknown}"
        fingerprint="${scan_count}:${last_scan}"
        initial_fingerprint="$fingerprint"

        marker_snapshot=""
        marker_exists=0
        if [ -f "$recovery_file" ]; then
            marker_exists=1
            marker_snapshot="$(<"$recovery_file")"
        fi
        previous_fingerprint=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^fingerprint=//p' | head -n 1 || true)
        debt_fingerprint=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^debt_fingerprint=//p' | head -n 1 || true)
        debt_dedup_key=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^debt_dedup_key=//p' | head -n 1 || true)
        replacement_started=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^replacement_started=//p' | head -n 1 || true)
        replacement_pid=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^replacement_pid=//p' | head -n 1 || true)
        replacement_started_at=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^replacement_started_at=//p' | head -n 1 || true)
        grace_deadline=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^replacement_grace_deadline=//p' | head -n 1 || true)
        first_scan_pid=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^first_scan_pid=//p' | head -n 1 || true)
        first_scan_at=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^first_scan_at=//p' | head -n 1 || true)
        first_scan_fingerprint=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^first_scan_fingerprint=//p' | head -n 1 || true)
        p0_delivered=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^p0_delivered=//p' | head -n 1 || true)
        delivery_mode=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^delivery_mode=//p' | head -n 1 || true)
        recovered_at=$(printf '%s\n' "$marker_snapshot" | sed -n 's/^recovered_at=//p' | head -n 1 || true)
        heartbeat_root="$(cd "$(dirname "$heartbeat_file")/.." 2>/dev/null && pwd -P || true)"
        script_root="$(cd "${SCRIPT_DIR:-.}" 2>/dev/null && pwd -P || true)"
        # The retained production marker predates delivery_mode and the child
        # receipt fields.  Its exact four fields are still a real recovery
        # attempt: fingerprint, replacement_started, p0_delivered, recovered_at.
        # Do not confuse an empty/missing marker with legacy debt.
        legacy_four_field=0
        if [ "$marker_exists" -eq 1 ] \
                && [ -n "$previous_fingerprint" ] \
                && [ "$replacement_started" = "true" ] \
                && [ -n "$p0_delivered" ] \
                && [ -n "$recovered_at" ] \
                && [ -z "$debt_fingerprint" ] \
                && [ -z "$debt_dedup_key" ] \
                && [ -z "$replacement_pid" ] \
                && [ -z "$replacement_started_at" ] \
                && [ -z "$grace_deadline" ] \
                && [ -z "$first_scan_pid" ] \
                && [ -z "$first_scan_at" ] \
                && [ -z "$first_scan_fingerprint" ] \
                && [ -z "$delivery_mode" ]; then
            legacy_four_field=1
        fi
        replacement_evidence=0
        if [ "$legacy_four_field" -eq 1 ] \
                || { [ "$replacement_started" = "true" ] \
                && [ -n "$previous_fingerprint" ] \
                && { [ -n "$replacement_pid" ] || [ -n "$replacement_started_at" ] \
                     || [ -n "$first_scan_pid" ] || [ -n "$first_scan_at" ]; }; }; then
            replacement_evidence=1
        fi
        if [ -z "$debt_fingerprint" ] && [ "$replacement_evidence" -eq 1 ]; then
            debt_fingerprint="$previous_fingerprint"
        fi
        if [ -z "$debt_dedup_key" ] && [ -n "$debt_fingerprint" ]; then
            debt_dedup_key="stall-detector-heartbeat-stale:${debt_fingerprint}"
        fi
        legacy_pending=0
        if [ "$marker_exists" -eq 1 ] \
                && { [ "$replacement_evidence" -eq 1 ] || [ -n "$debt_fingerprint" ]; } \
                && [ -n "$heartbeat_root" ] && [ "$heartbeat_root" = "$script_root" ] \
                && { [ "$p0_delivered" != "true" ] || [ "$delivery_mode" != "inbox" ]; }; then
            legacy_pending=1
            p0_delivered=false
        fi
        first_scan_seen=0
        [ -n "$first_scan_pid" ] && first_scan_seen=1

        # A fresh heartbeat is authoritative for replacement, but it must not
        # suppress a production legacy P0 debt.  Debt delivery is independent
        # of whether a new detector is needed.
        if [ -n "$detector_pid" ] && [ "$heartbeat_age" -lt "$STALL_DETECTOR_STALE_SECONDS" ]; then
            if [ "$legacy_pending" -eq 1 ]; then
                send_p0
                now_iso_marker="$(date -Iseconds)"
                write_debt_marker
            fi
            return 0
        fi

        now=$(date +%s 2>/dev/null || echo 0)
        replacement_alive=0
        if [[ "$replacement_pid" =~ ^[0-9]+$ ]]; then
            [ -e "/proc/$replacement_pid" ] && replacement_alive=1
            if printf '%s\n' "$(pgrep -f "scripts/stall_detector.sh$" 2>/dev/null || true)" \
                    | grep -qx "$replacement_pid"; then
                replacement_alive=1
            fi
        fi

        # Startup grace is tied to the replacement receipt, not just process
        # age.  A replacement may die before its first scan; keep one attempt
        # suppressed during grace, then permit a bounded retry.
        launch_replacement=0
        retry_p0=0
        if [ "$replacement_started" = "true" ] \
                && [ "$previous_fingerprint" = "$fingerprint" ]; then
            if [ "$p0_delivered" != "true" ]; then retry_p0=1; fi
            if [ "$replacement_alive" -eq 1 ]; then
                launch_replacement=0
            elif [ "$first_scan_seen" -eq 0 ] \
                    && [[ "$grace_deadline" =~ ^[0-9]+$ ]] \
                    && [ "$now" -lt "$grace_deadline" ]; then
                launch_replacement=0
            else
                launch_replacement=1
            fi
        elif [ -n "$detector_pid" ] \
                && [ "${process_age:-999999}" -lt "$STALL_DETECTOR_STARTUP_GRACE_SECONDS" ]; then
            launch_replacement=0
        else
            launch_replacement=1
        fi

        # Final recovery observation is a state+heartbeat transaction.  The
        # detector takes this same short commit lock while publishing its
        # state generation and heartbeat, so a scan cannot commit between the
        # final state read and the heartbeat stat.  Reading state once more
        # after stat is an inexpensive defense for old/test detector writers.
        read_state_fingerprint() {
            state_snapshot=""
            [ -f "$state_file" ] && state_snapshot="$(<"$state_file")"
            scan_count=$(printf '%s\n' "$state_snapshot" | sed -n 's/^scan_count:[[:space:]]*//p' | head -n 1 || true)
            last_scan=$(printf '%s\n' "$state_snapshot" | sed -n 's/^last_scan:[[:space:]]*//p' | head -n 1 || true)
            scan_count=$(normalize_state_scalar "$scan_count")
            last_scan=$(normalize_state_scalar "$last_scan")
            printf '%s:%s\n' "${scan_count:-unknown}" "${last_scan:-unknown}"
        }

        final_fingerprint_before=""
        final_fingerprint_after=""
        final_heartbeat_age=999999
        exec 8>"$commit_lock"
        if ! flock -x 8; then
            exec 8>&-
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] detector commit lock unavailable; preserving current process" >&2
            return 0
        fi
        commit_lock_held=1

        release_commit_lock() {
            if [ "$commit_lock_held" -eq 1 ]; then
                flock -u 8
                exec 8>&-
                commit_lock_held=0
            fi
        }

        final_fingerprint_before="$(read_state_fingerprint)"
        if [ -f "$heartbeat_file" ]; then
            heartbeat_ts=$(stat -c %Y "$heartbeat_file" 2>/dev/null || echo 0)
            now=$(date +%s 2>/dev/null || echo 0)
            if [[ "$heartbeat_ts" =~ ^[0-9]+$ ]] && [[ "$now" =~ ^[0-9]+$ ]] \
                    && [ "$now" -ge "$heartbeat_ts" ]; then
                final_heartbeat_age=$((now - heartbeat_ts))
            else
                final_heartbeat_age=0
            fi
        fi
        final_fingerprint_after="$(read_state_fingerprint)"
        heartbeat_age="$final_heartbeat_age"
        fingerprint="$final_fingerprint_after"
        if [ "$final_fingerprint_before" != "$initial_fingerprint" ] \
                || [ "$final_fingerprint_after" != "$final_fingerprint_before" ]; then
            release_commit_lock
            if [ "$legacy_pending" -eq 1 ]; then
                send_p0
                now_iso_marker="$(date -Iseconds)"
                write_debt_marker
            fi
            return 0
        fi
        if [ -n "$detector_pid" ] \
                && [ "$final_heartbeat_age" -lt "$STALL_DETECTOR_STALE_SECONDS" ]; then
            release_commit_lock
            if [ "$legacy_pending" -eq 1 ]; then
                send_p0
                now_iso_marker="$(date -Iseconds)"
                write_debt_marker
            fi
            return 0
        fi

        if [ "$launch_replacement" -eq 1 ]; then
            mkdir -p "$(dirname "$recovery_file")" 2>/dev/null || true
            replacement_started=true
            replacement_started_at="$now"
            grace_deadline=$((now + STALL_DETECTOR_STARTUP_GRACE_SECONDS))
            replacement_pid=""
            first_scan_pid=""
            first_scan_at=""
            first_scan_fingerprint=""
            # A legacy marker may carry an undelivered F42 debt while the
            # current state has already advanced to F43.  The replacement
            # receipt is allowed to move to F43, but its P0 debt identity must
            # remain F42 until that delivery commits; otherwise the next
            # cycle cannot retry the original stable dedup key.
            if [ "$legacy_pending" -ne 1 ] || [ -z "$debt_fingerprint" ]; then
                debt_fingerprint="$fingerprint"
                debt_dedup_key="stall-detector-heartbeat-stale:${debt_fingerprint}"
            elif [ -z "$debt_dedup_key" ]; then
                debt_dedup_key="stall-detector-heartbeat-stale:${debt_fingerprint}"
            fi
            p0_delivered=false
            delivery_mode=undelivered
            now_iso_marker="$(date -Iseconds)"
            if ! write_marker; then
                release_commit_lock
                return 0
            fi
            if [ -n "$detector_pid" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] stall_detector process=${detector_pid} heartbeat stale age=${heartbeat_age}s threshold=${STALL_DETECTOR_STALE_SECONDS}s fingerprint=${fingerprint}; preserving stale process and starting one replacement" >&2
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] stall_detector process missing heartbeat stale age=${heartbeat_age}s threshold=${STALL_DETECTOR_STALE_SECONDS}s fingerprint=${fingerprint}; starting coordinated replacement" >&2
            fi
            # Close supervisor/recovery descriptors in every detector child.
            # The child receives the receipt path and can record first scan
            # only after its state+heartbeat commit.
            nohup env \
                STALL_DETECTOR_RECOVERY_FILE="$recovery_file" \
                STALL_DETECTOR_STATE="$state_file" \
                STALL_DETECTOR_COMMIT_LOCK="$commit_lock" \
                bash scripts/stall_detector.sh \
                7>&- 8>&- 9>&- >> logs/stall_detector.log 2>&1 &
            replacement_pid="$!"
            retry_p0=1
            now_iso_marker="$(date -Iseconds)"
            write_marker || true
        elif [ "$retry_p0" -eq 0 ] && [ "$legacy_pending" -eq 0 ]; then
            release_commit_lock
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] stall_detector process=${detector_pid:-missing} heartbeat stale fingerprint=${fingerprint}; replacement already attempted, suppressing duplicate launch" >&2
            return 0
        fi

        # Keep the detector commit lock through marker reservation and child
        # launch.  A detector cannot publish a fresh state/heartbeat in the
        # validation-to-launch window, so stale recovery is linearized with the
        # generation it is replacing.  Release before external P0 delivery.
        release_commit_lock

        # Track replacement_started separately from P0 delivery.  Failed
        # inbox_write leaves p0_delivered=false and retries this stable key;
        # no second replacement is launched during the same startup grace.
        if [ "$launch_replacement" -eq 1 ] || [ "$retry_p0" -eq 1 ] || [ "$legacy_pending" -eq 1 ]; then
            send_p0
            now_iso_marker="$(date -Iseconds)"
            write_marker || true
        fi
    ) 9>"$recovery_lock"
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

# One lifetime lease per repository root.  flock releases it cooperatively
# when the owner exits, so a stale fixture-root process cannot be "repaired"
# by starting more supervisors against the same files.  Read-only
# --print-watchers intentionally bypasses this lease above.
exec 7>"$SUPERVISOR_LEASE_FILE"
if ! flock -n 7; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] watcher_supervisor lease is already held; no second supervisor started" >&2
    exit 0
fi

# Heartbeat is a post-lease receipt.  A losing duplicate must not make the
# supervisor appear healthy before it has established ownership.
date +%s > "$HEARTBEAT_FILE" 2>/dev/null || true

while true; do
    if [ ! -d "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/queue" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] supervisor root disappeared; exiting without starting children" >&2
        exit 0
    fi
    date +%s > "$HEARTBEAT_FILE" 2>/dev/null || true
    start_all_watchers
    start_stall_detector_if_missing
    sleep 5
done
