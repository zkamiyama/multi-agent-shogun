#!/usr/bin/env bats
# test_watcher_supervisor.bats — start_watcher_if_missing unit tests
#
# Tests the flock-protected start_watcher_if_missing logic via mocking.
#
# Test cases:
#   T-WS-001: pane does not exist → returns 0, no watcher started
#   T-WS-002: watcher already running for correct pane → no duplicate started
#   T-WS-003: lockfile path follows pattern /tmp/shogun_watcher_start_{agent}.lock
#   T-WS-004: no existing watcher → watcher is started
#   T-WS-005: stale watcher for same pane does not start duplicate
#   T-WS-006: inbox_watcher has agent-wide lifetime lock

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SUPERVISOR_SCRIPT="$PROJECT_ROOT/scripts/watcher_supervisor.sh"
export MUX_BACKEND=tmux

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/scripts"
    mkdir -p "$TEST_TMP/queue/inbox"
    mkdir -p "$TEST_TMP/logs"

    # Mock inbox_watcher.sh — records launch args
    cat > "$TEST_TMP/scripts/inbox_watcher.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../watcher_launched.log"
sleep 60
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_watcher.sh"

    # Default mock: pane does NOT exist
    MOCK_PANE_EXISTS=0

    # Default mock: no existing watcher pgrep hit
    MOCK_PGREP_CORRECT=1
    MOCK_PGREP_STALE=1
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Source the function under test with mocked dependencies injected via env overrides.
# We source the function definitions only, then call start_watcher_if_missing directly.
source_supervisor_functions() {
    # Override pane_exists and pgrep with shell functions in the current subshell.
    pane_exists() {
        return $MOCK_PANE_EXISTS
    }

    pgrep() {
        # Distinguish correct-pane vs stale-pane pgrep call by argument pattern
        local args="$*"
        if echo "$args" | grep -q "( |\$)"; then
            # correct-pane pattern (has trailing space or end anchor)
            return $MOCK_PGREP_CORRECT
        else
            return $MOCK_PGREP_STALE
        fi
    }

    ensure_inbox_file() {
        local agent="$1"
        touch "$TEST_TMP/queue/inbox/${agent}.yaml"
    }

    # Load only the start_watcher_if_missing function definition from the script.
    # We extract and eval it to avoid running the infinite loop at the bottom.
    eval "$(
        awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
            "$SUPERVISOR_SCRIPT"
    )"
}

source_stall_detector_function() {
    eval "$(
        awk '/^start_stall_detector_if_missing\(\)/{p=1} p{print} /^\}/{if(p){p=0}}' \
            "$SUPERVISOR_SCRIPT"
    )"
}

# ---------------------------------------------------------------------------
# T-WS-001: pane does not exist → function returns 0, no watcher started
# ---------------------------------------------------------------------------
@test "T-WS-001: pane does not exist returns 0 and does not start watcher" {
    (
        export MOCK_PANE_EXISTS=1   # non-zero = pane missing

        pane_exists() { return 1; }
        ensure_inbox_file() { :; }

        watcher_started=0
        nohup() { watcher_started=1; }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        start_watcher_if_missing "ashigaru1" "multiagent:agents.1" "/tmp/test_ws_001.log"
        result=$?

        [ "$result" -eq 0 ]
        [ "$watcher_started" -eq 0 ]
    )
}

# ---------------------------------------------------------------------------
# T-WS-002: watcher already running for correct pane → no duplicate started
# ---------------------------------------------------------------------------
@test "T-WS-002: watcher already running for correct pane does not start duplicate" {
    local launched_log="$TEST_TMP/watcher_launched.log"

    # Run a subprocess that:
    #   - pane exists
    #   - correct-pane pgrep returns 0 (watcher running)
    #   - records if inbox_watcher.sh gets executed
    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        pgrep() {
            # Simulate: correct-pane watcher IS running
            return 0
        }

        nohup_called=0
        # Override nohup so we can detect if watcher would be launched
        nohup() { nohup_called=1; echo "$@" >> "$launched_log"; }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"
        has_current_watcher() { return 0; }

        start_watcher_if_missing "ashigaru1" "multiagent:agents.1" "/tmp/test_ws_002.log"

        # If launched_log was created, a duplicate was (incorrectly) started
        [ ! -f "$launched_log" ]
    )
}

# ---------------------------------------------------------------------------
# T-WS-003: lockfile path follows /tmp/shogun_watcher_start_{agent}.lock
# ---------------------------------------------------------------------------
@test "T-WS-003: lockfile path follows /tmp/shogun_watcher_start_{agent}.lock pattern" {
    local agent="ashigaru3"
    local expected_lockfile="/tmp/shogun_watcher_start_${agent}.lock"

    # Confirm the script contains the expected lockfile pattern for any agent name
    grep -q 'lockfile="/tmp/shogun_watcher_start_\${agent}.lock"' "$SUPERVISOR_SCRIPT"
}

# ---------------------------------------------------------------------------
# T-WS-004: no existing watcher → watcher is started (nohup bash ... invoked)
# ---------------------------------------------------------------------------
@test "T-WS-004: no existing watcher causes inbox_watcher to be launched" {
    local launched_log="$TEST_TMP/watcher_launched.log"
    local lockfile="/tmp/shogun_watcher_start_ashigaru4_$$_test.lock"

    # Clean up stray lockfile from a previous failed run
    rm -f "$lockfile"

    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        pgrep() {
            # No watcher running
            return 1
        }

        tmux() {
            # Stub tmux show-options for @agent_cli
            echo "codex"
        }

        # Override nohup + bash to capture the launch without actually spawning
        nohup() {
            echo "launched: $*" >> "$launched_log"
        }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"
        has_current_watcher() { return 1; }

        # Use a test-specific lockfile to avoid collision with real supervisors
        # We re-define the lockfile variable inside the function scope by
        # calling with a modified env. Since lockfile is a local var built
        # from agent name, use a unique agent name for isolation.
        start_watcher_if_missing "ashigaru4_$$_test" "multiagent:agents.4" "$launched_log"
    )

    # A launched entry should exist in the log
    [ -f "$launched_log" ]
    grep -q "launched:" "$launched_log"
}

# ---------------------------------------------------------------------------
# T-WS-005: stale watcher for same pane → no duplicate started
# ---------------------------------------------------------------------------
@test "T-WS-005: stale watcher for same pane does not start duplicate" {
    local launched_log="$TEST_TMP/watcher_launched.log"

    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        nohup() { echo "launched: $*" >> "$launched_log"; }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"
        has_current_watcher() { return 0; }

        start_watcher_if_missing "ashigaru1" "multiagent:agents.1" "/tmp/test_ws_005.log"
        [ ! -f "$launched_log" ]
    )
}

# ---------------------------------------------------------------------------
# T-WS-006: inbox_watcher owns an agent-wide lifetime lock
# ---------------------------------------------------------------------------
@test "T-WS-006: inbox_watcher has agent-wide lifetime lock" {
    grep -q 'WATCHER_INSTANCE_LOCK="/tmp/shogun_inbox_watcher_\${AGENT_ID}.lock"' "$PROJECT_ROOT/scripts/inbox_watcher.sh"
    ! grep -q 'WATCHER_INSTANCE_LOCK="/tmp/shogun_inbox_watcher_\${AGENT_ID}_' "$PROJECT_ROOT/scripts/inbox_watcher.sh"
    grep -q 'flock -n 201' "$PROJECT_ROOT/scripts/inbox_watcher.sh"
    grep -q 'already running' "$PROJECT_ROOT/scripts/inbox_watcher.sh"
    grep -q 'pgrep -f "scripts/inbox_watcher.sh \${agent} "' "$SUPERVISOR_SCRIPT"
}

# ---------------------------------------------------------------------------
# T-WS-007/T-WS-008: detector process liveness is paired with scan heartbeat
# ---------------------------------------------------------------------------
@test "T-WS-007: live detector with stale heartbeat starts one replacement and one P0 alert" {
    mkdir -p "$TEST_TMP/queue"
    mkdir -p "$TEST_TMP/scripts"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF
    printf '%s\n' '#!/usr/bin/env bash' \
        'echo "$*" >> "$(dirname "$0")/../karo_alert.log"' \
        > "$TEST_TMP/scripts/inbox_write.sh"
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    (
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        export STALL_DETECTOR_STARTUP_GRACE_SECONDS=30

        pgrep() { printf '4321\n'; return 0; }
        ps() { printf '3600\n'; return 0; }
        nohup() { echo launched >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        output="$(start_stall_detector_if_missing 2>&1)"
        [ "$(wc -l < "$TEST_TMP/detector_launched.log")" -eq 1 ]
        [[ "$output" == *"heartbeat stale"* ]]
        [[ "$output" == *"starting one replacement"* ]]
        [[ "$output" == *"P0"* ]]
        grep -q 'karo .*stall_alert watcher_supervisor' "$TEST_TMP/karo_alert.log"

        output="$(start_stall_detector_if_missing 2>&1)"
        [ "$(wc -l < "$TEST_TMP/detector_launched.log")" -eq 1 ]
        [[ "$output" == *"replacement already attempted"* ]]
        [ "$(wc -l < "$TEST_TMP/karo_alert.log")" -eq 1 ]
    )
}

@test "T-WS-008: missing detector with stale heartbeat starts replacement" {
    mkdir -p "$TEST_TMP/queue"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF

    (
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STALE_SECONDS=60
        export STALL_DETECTOR_STARTUP_GRACE_SECONDS=30
        STALL_DETECTOR_STALE_WARNED=0

        pgrep() { return 1; }
        nohup() { echo "$*" >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        output="$(start_stall_detector_if_missing 2>&1)"
        sleep 0.1
        [ -f "$TEST_TMP/detector_launched.log" ]
        [[ "$output" == *"starting coordinated replacement"* ]]
    )
}

@test "T-WS-009: missing plus stale heartbeat does not double-launch during startup grace" {
    mkdir -p "$TEST_TMP/queue"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF
    (
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        export STALL_DETECTOR_STARTUP_GRACE_SECONDS=30

        pgrep() {
            if [ -e "$TEST_TMP/detector_started" ]; then
                printf '4321\n'
                return 0
            fi
            return 1
        }
        ps() { printf '0\n'; }
        nohup() {
            : > "$TEST_TMP/detector_started"
            echo launched >> "$TEST_TMP/detector_launched.log"
        }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        start_stall_detector_if_missing >/dev/null 2>&1
        [ "$(wc -l < "$TEST_TMP/detector_launched.log")" -eq 1 ]
    )
}

@test "T-WS-010: failed Karo P0 delivery retries without a second replacement" {
    mkdir -p "$TEST_TMP/queue" "$TEST_TMP/scripts"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF
    cat > "$TEST_TMP/scripts/inbox_write.sh" <<'EOF'
#!/usr/bin/env bash
calls="$(dirname "$0")/../p0_calls"
count=0
[ -f "$calls" ] && count="$(cat "$calls")"
count=$((count + 1))
printf '%s\n' "$count" > "$calls"
printf '%s %s\n' "${DEDUP_KEY:-}" "$*" >> "$(dirname "$0")/../p0_args"
[ "$count" -ge 2 ]
EOF

    (
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        export STALL_DETECTOR_STARTUP_GRACE_SECONDS=30

        pgrep() { printf '4321\n'; return 0; }
        ps() { printf '3600\n'; return 0; }
        nohup() { echo launched >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        start_stall_detector_if_missing >/dev/null 2>&1
        [ "$(wc -l < "$TEST_TMP/detector_launched.log")" -eq 1 ]
        [ "$(cat "$TEST_TMP/p0_calls")" -eq 2 ]
        [ "$(grep -c 'stall-detector-heartbeat-stale:42:' "$TEST_TMP/p0_args")" -eq 2 ]
        grep -q '^p0_delivered=true$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
    )
}

@test "T-WS-011: heartbeat refreshed before recovery decision cancels replacement" {
    mkdir -p "$TEST_TMP/queue"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF

    (
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        export STALL_DETECTOR_STARTUP_GRACE_SECONDS=30
        export TOCTOU_REFRESHED=0

        # Simulate a detector scan completing after the stale observation but
        # before the recovery transaction takes its locked snapshot.
        flock() {
            if [ "${1:-}" = "-n" ] && [ "${2:-}" = "9" ] \
                    && [ "$TOCTOU_REFRESHED" -eq 0 ]; then
                touch "$TEST_TMP/queue/stall_detector.heartbeat"
                TOCTOU_REFRESHED=1
            fi
            return 0
        }
        pgrep() { printf '4321\n'; return 0; }
        ps() { printf '3600\n'; return 0; }
        nohup() { echo launched >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        [ ! -e "$TEST_TMP/detector_launched.log" ]
        [ ! -e "$TEST_TMP/queue/stall_detector_recovery.yaml" ]
    )
}

@test "T-WS-012: test-mode stale recovery records suppressed P0 as undelivered" {
    mkdir -p "$TEST_TMP/queue"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF

    (
        unset SCRIPT_DIR
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        export STALL_DETECTOR_STARTUP_GRACE_SECONDS=30

        pgrep() { return 1; }
        nohup() { echo launched >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        [ "$(wc -l < "$TEST_TMP/detector_launched.log")" -eq 1 ]
        grep -q '^p0_delivered=false$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
        grep -q '^delivery_mode=suppressed$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
    )
}

@test "T-WS-014: deleted fixture root maintenance never starts a detector" {
    local deleted_root="$TEST_TMP/deleted-fixture-root"
    mkdir -p "$deleted_root/queue"
    rmdir "$deleted_root/queue"
    rmdir "$deleted_root"

    (
        export SCRIPT_DIR="$deleted_root"
        pgrep() { printf '4321\n'; return 0; }
        nohup() { echo launched >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function
        start_stall_detector_if_missing >/dev/null 2>&1
        [ ! -e "$TEST_TMP/detector_launched.log" ]
    )
}

@test "T-WS-015: stale recovery proceeds while detector state lock is held" {
    mkdir -p "$TEST_TMP/queue"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF

    (
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        export STALL_DETECTOR_STARTUP_GRACE_SECONDS=30

        exec 8>"$TEST_TMP/queue/stall_detector_state.yaml.lock"
        flock -n 8
        pgrep() { return 1; }
        nohup() { echo launched >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        start_stall_detector_if_missing >"$TEST_TMP/recovery.log" 2>&1
        [ -f "$TEST_TMP/detector_launched.log" ]
        grep -q 'starting coordinated replacement' "$TEST_TMP/recovery.log"
    )
}

@test "T-WS-016: fresh heartbeat still retries a legacy undelivered P0 debt" {
    mkdir -p "$TEST_TMP/queue" "$TEST_TMP/scripts"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF
    cat > "$TEST_TMP/queue/stall_detector_recovery.yaml" <<'EOF'
fingerprint=42:2026-05-15T00:00:00+09:00
replacement_started=true
replacement_pid=4321
replacement_started_at=0
replacement_grace_deadline=30
first_scan_pid=4321
first_scan_at=2026-05-15T00:00:01+09:00
first_scan_fingerprint=42:2026-05-15T00:00:00+09:00
p0_delivered=true
EOF
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s %s\\n" "${DEDUP_KEY:-}" "$*" >> "$(dirname "$0")/../p0_args"' \
        > "$TEST_TMP/scripts/inbox_write.sh"
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"
    touch "$TEST_TMP/queue/stall_detector.heartbeat"

    (
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        pgrep() { printf '4321\n'; return 0; }
        ps() { printf '3600\n'; return 0; }
        nohup() { echo unexpected_launch >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        [ ! -e "$TEST_TMP/detector_launched.log" ]
        [ "$(wc -l < "$TEST_TMP/p0_args")" -eq 1 ]
        grep -q '^p0_delivered=true$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
        grep -q '^delivery_mode=inbox$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
    )
}

@test "T-WS-017: replacement that dies before first scan is retried after grace" {
    mkdir -p "$TEST_TMP/queue"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF
    cat > "$TEST_TMP/queue/stall_detector_recovery.yaml" <<'EOF'
fingerprint=42:2026-05-15T00:00:00+09:00
replacement_started=true
replacement_pid=4321
replacement_started_at=0
replacement_grace_deadline=1
first_scan_pid=
first_scan_at=
first_scan_fingerprint=
p0_delivered=true
delivery_mode=inbox
EOF

    (
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        export STALL_DETECTOR_STARTUP_GRACE_SECONDS=1
        pgrep() { return 1; }
        nohup() { echo retried >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        [ "$(wc -l < "$TEST_TMP/detector_launched.log")" -eq 1 ]
    )
}

@test "T-WS-018: state commit before heartbeat cancels stale replacement" {
    mkdir -p "$TEST_TMP/queue"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF
    cat > "$TEST_TMP/queue/stall_detector_recovery.yaml" <<'EOF'
fingerprint=42:2026-05-15T00:00:00+09:00
replacement_started=false
replacement_pid=4321
p0_delivered=true
delivery_mode=inbox
EOF

    (
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        pgrep() {
            if [ -e "$TEST_TMP/pgrep_seen" ]; then
                cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 43
last_scan: "2026-05-15T00:01:00+09:00"
EOF
            else
                : > "$TEST_TMP/pgrep_seen"
            fi
            printf '4321\n'
            return 0
        }
        ps() { printf '3600\n'; }
        nohup() { echo unexpected_launch >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        [ ! -e "$TEST_TMP/detector_launched.log" ]
        [ -e "$TEST_TMP/queue/stall_detector_recovery.yaml" ]
        grep -q '^scan_count: 43$' "$TEST_TMP/queue/stall_detector_state.yaml"
    )
}

@test "T-WS-019: lease is acquired before heartbeat and child launch closes descriptors" {
    local lease_line heartbeat_line
    lease_line="$(grep -n 'flock -n 7' "$SUPERVISOR_SCRIPT" | tail -1 | cut -d: -f1)"
    heartbeat_line="$(grep -n 'date +%s > \"\$HEARTBEAT_FILE\"' "$SUPERVISOR_SCRIPT" | tail -1 | cut -d: -f1)"
    [ -n "$lease_line" ]
    [ -n "$heartbeat_line" ]
    [ "$heartbeat_line" -gt "$lease_line" ]
    grep -q 'nohup bash scripts/inbox_watcher.sh' "$SUPERVISOR_SCRIPT"
    grep -q '7>&- 8>&- 9>&-' "$SUPERVISOR_SCRIPT"
}

@test "T-WS-020: fresh detector without recovery marker does not create a false P0" {
    mkdir -p "$TEST_TMP/queue"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF

    (
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        pgrep() { printf '4321\n'; return 0; }
        ps() { printf '3600\n'; }
        nohup() { echo unexpected_launch >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        [ ! -e "$TEST_TMP/detector_launched.log" ]
        [ ! -e "$TEST_TMP/queue/stall_detector_recovery.yaml" ]
    )
}

@test "T-WS-021: legacy fingerprint debt retries the original dedup identity" {
    mkdir -p "$TEST_TMP/queue" "$TEST_TMP/scripts"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 43
last_scan: "2026-05-15T01:00:00+09:00"
EOF
    cat > "$TEST_TMP/queue/stall_detector_recovery.yaml" <<'EOF'
fingerprint=42:2026-05-15T00:00:00+09:00
replacement_started=true
p0_delivered=true
recovered_at=2026-05-15T00:30:00+09:00
EOF
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s %s\\n" "${DEDUP_KEY:-}" "$*" >> "$(dirname "$0")/../p0_args"' \
        > "$TEST_TMP/scripts/inbox_write.sh"

    (
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_INBOX_WRITER="$TEST_TMP/scripts/inbox_write.sh"
        export STALL_DETECTOR_STALE_SECONDS=60
        pgrep() {
            if [ -e "$TEST_TMP/next_cycle" ]; then
                return 1
            fi
            printf '4321\n'
            return 0
        }
        ps() { printf '3600\n'; }
        nohup() { echo launched >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        # The fresh-heartbeat cycle accepts the legacy four-field marker and
        # delivers the original F42 debt even though current state is F43.
        start_stall_detector_if_missing >/dev/null 2>&1
        [ ! -e "$TEST_TMP/detector_launched.log" ]
        [ "$(wc -l < "$TEST_TMP/p0_args")" -eq 1 ]
        grep -q '^stall-detector-heartbeat-stale:42:2026-05-15T00:00:00+09:00 ' "$TEST_TMP/p0_args"
        grep -q '^debt_fingerprint=42:2026-05-15T00:00:00+09:00$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
        grep -q '^fingerprint=42:2026-05-15T00:00:00+09:00$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
        grep -q '^delivery_mode=inbox$' "$TEST_TMP/queue/stall_detector_recovery.yaml"

        # On the next stale-heartbeat cycle, current F43 gets a new replacement
        # and its own retry identity; the delivered F42 debt is never relabeled.
        python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
        : > "$TEST_TMP/next_cycle"
        start_stall_detector_if_missing >/dev/null 2>&1
        [ "$(wc -l < "$TEST_TMP/detector_launched.log")" -eq 1 ]
        [ "$(wc -l < "$TEST_TMP/p0_args")" -eq 2 ]
        sed -n '2p' "$TEST_TMP/p0_args" | grep -q '^stall-detector-heartbeat-stale:43:2026-05-15T01:00:00+09:00 '
        grep -q '^fingerprint=43:2026-05-15T01:00:00+09:00$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
        grep -q '^debt_fingerprint=43:2026-05-15T01:00:00+09:00$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
    )
}

@test "T-WS-022: state commit between final read and heartbeat stat cancels replacement" {
    mkdir -p "$TEST_TMP/queue"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF

    (
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        STAT_COUNT_FILE="$TEST_TMP/stat_count"
        printf '0\n' > "$STAT_COUNT_FILE"
        stat() {
            STAT_COUNT=$(cat "$STAT_COUNT_FILE")
            STAT_COUNT=$((STAT_COUNT + 1))
            printf '%s\n' "$STAT_COUNT" > "$STAT_COUNT_FILE"
            if [ "$STAT_COUNT" -eq 2 ]; then
                cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'STATE'
scan_count: 43
last_scan: "2026-05-15T01:00:00+09:00"
STATE
            fi
            command stat "$@"
        }
        pgrep() { printf '4321\n'; return 0; }
        ps() { printf '3600\n'; }
        nohup() { echo unexpected_launch >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        [ ! -e "$TEST_TMP/detector_launched.log" ]
        [ ! -e "$TEST_TMP/queue/stall_detector_recovery.yaml" ]
        grep -q '^scan_count: 43$' "$TEST_TMP/queue/stall_detector_state.yaml"
    )
}

@test "T-WS-023: old-pane watcher is recognized by the agent-wide owner check" {
    local pattern_file="$TEST_TMP/pgrep_pattern"
    (
        eval "$(
            awk '/^has_current_watcher\(\)/{p=1} p{print} /^\}/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"
        watcher_is_current() { return 1; }
        pgrep() {
            printf '%s\n' "$*" > "$pattern_file"
            printf '4321\n'
            return 0
        }
        output="$(has_current_watcher ashigaru6 zellij:multiagent:terminal_new 2>&1)"
        [ "$?" -eq 0 ]
        grep -q 'scripts/inbox_watcher.sh ashigaru6 ' "$pattern_file"
        ! grep -q 'terminal_new' "$pattern_file"
    )
}

@test "T-WS-024: recovery commit lock stays held until replacement launch" {
    mkdir -p "$TEST_TMP/queue"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    python3 - "$TEST_TMP/queue/stall_detector.heartbeat" <<'PYEOF'
import os, sys
os.utime(sys.argv[1], (946684800, 946684800))
PYEOF
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF

    (
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_STALE_SECONDS=60
        export STALL_DETECTOR_STARTUP_GRACE_SECONDS=30
        flock() {
            if [ "${1:-}" = "-u" ] && [ "${2:-}" = "8" ] \
                    && [ ! -e "$TEST_TMP/replacement_launched" ]; then
                : > "$TEST_TMP/unlock_before_launch"
            fi
            return 0
        }
        pgrep() { return 1; }
        nohup() { : > "$TEST_TMP/replacement_launched"; }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        [ -e "$TEST_TMP/replacement_launched" ]
        [ ! -e "$TEST_TMP/unlock_before_launch" ]
    )
}

@test "T-WS-025: exact four-field marker discriminator is nounset-safe" {
    mkdir -p "$TEST_TMP/queue" "$TEST_TMP/scripts"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF
    cat > "$TEST_TMP/queue/stall_detector_recovery.yaml" <<'EOF'
fingerprint=42:2026-05-15T00:00:00+09:00
replacement_started=true
p0_delivered=true
recovered_at=2026-05-15T00:30:00+09:00
EOF
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s %s\\n" "${DEDUP_KEY:-}" "$*" >> "$(dirname "$0")/../p0_args"' \
        > "$TEST_TMP/scripts/inbox_write.sh"
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    (
        set -u
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_DETECTOR_INBOX_WRITER="$TEST_TMP/scripts/inbox_write.sh"
        export STALL_DETECTOR_STALE_SECONDS=60
        pgrep() { printf '4321\n'; return 0; }
        ps() { printf '3600\n'; return 0; }
        nohup() { echo unexpected_launch >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        start_stall_detector_if_missing >/dev/null 2>&1
        [ ! -e "$TEST_TMP/detector_launched.log" ]
        [ "$(wc -l < "$TEST_TMP/p0_args")" -eq 1 ]
        grep -q '^stall-detector-heartbeat-stale:42:2026-05-15T00:00:00+09:00 ' "$TEST_TMP/p0_args"
    )
}

@test "T-WS-026: transient P0 failure preserves debt identity for exact retry" {
    mkdir -p "$TEST_TMP/queue" "$TEST_TMP/scripts"
    : > "$TEST_TMP/queue/stall_detector.heartbeat"
    cat > "$TEST_TMP/queue/stall_detector_state.yaml" <<'EOF'
scan_count: 42
last_scan: "2026-05-15T00:00:00+09:00"
EOF
    cat > "$TEST_TMP/queue/stall_detector_recovery.yaml" <<'EOF'
fingerprint=42:2026-05-15T00:00:00+09:00
replacement_started=true
p0_delivered=true
recovered_at=2026-05-15T00:30:00+09:00
EOF
    cat > "$TEST_TMP/scripts/inbox_write.sh" <<'EOF'
#!/usr/bin/env bash
root="$(dirname "$0")/.."
count=0
[ -f "$root/p0_calls" ] && count="$(<"$root/p0_calls")"
count=$((count + 1))
printf '%s\n' "$count" > "$root/p0_calls"
printf '%s\n' "${DEDUP_KEY:-}" >> "$root/p0_keys"
[ "$count" -ne 1 ]
EOF
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    (
        set -u
        export SCRIPT_DIR="$TEST_TMP"
        export STALL_DETECTOR_HEARTBEAT="$TEST_TMP/queue/stall_detector.heartbeat"
        export STALL_DETECTOR_STATE="$TEST_TMP/queue/stall_detector_state.yaml"
        export STALL_DETECTOR_RECOVERY_FILE="$TEST_TMP/queue/stall_detector_recovery.yaml"
        export STALL_SUPERVISOR_INBOX_WRITER="$TEST_TMP/scripts/inbox_write.sh"
        export STALL_DETECTOR_STALE_SECONDS=60
        pgrep() { printf '4321\n'; return 0; }
        ps() { printf '3600\n'; return 0; }
        nohup() { echo unexpected_launch >> "$TEST_TMP/detector_launched.log"; }
        source_stall_detector_function

        # The first fresh-heartbeat retry fails after the marker has been
        # upgraded with durable debt fields; the next cycle must still retry
        # the same debt identity and succeed without launching a detector.
        start_stall_detector_if_missing >/dev/null 2>&1
        start_stall_detector_if_missing >/dev/null 2>&1
        [ ! -e "$TEST_TMP/detector_launched.log" ]
        [ "$(wc -l < "$TEST_TMP/p0_keys")" -eq 2 ]
        [ "$(sed -n '1p' "$TEST_TMP/p0_keys")" = "$(sed -n '2p' "$TEST_TMP/p0_keys")" ]
        [ "$(sed -n '1p' "$TEST_TMP/p0_keys")" = "stall-detector-heartbeat-stale:42:2026-05-15T00:00:00+09:00" ]
        grep -q '^debt_fingerprint=42:2026-05-15T00:00:00+09:00$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
        grep -q '^debt_dedup_key=stall-detector-heartbeat-stale:42:2026-05-15T00:00:00+09:00$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
        grep -q '^p0_delivered=true$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
        grep -q '^delivery_mode=inbox$' "$TEST_TMP/queue/stall_detector_recovery.yaml"
    )
}
