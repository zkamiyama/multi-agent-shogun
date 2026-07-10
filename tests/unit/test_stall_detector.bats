#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# Unit tests for scripts/stall_detector.sh — 長時間 Stall 検知 core daemon
#
# 検証方式: stall_detector.sh の test hook を使って scan を決定論的に再現する:
#   STALL_ROOT                  — queue/ パス root を tmp fixture copy に差し替え
#   STALL_NOW                   — 「現在時刻」を epoch で固定 (閾値テスト用)
#   STALL_PANE_STATES_OVERRIDE  — pane 状態を tmux 非依存で JSON 固定
# STALL_ROOT が実 repo と異なるため Karo inbox への実通知は抑止され、
# 結果は queue/stall_alerts.yaml に現れる。それを検証する。
#
# fixture anchor: tests/fixtures/stall_detector/*/queue/... の timestamp は
#   2026-05-15T00:00:00 を基準に固定。各 test は STALL_NOW を anchor からの
#   相対時刻で与えて threshold を出し分ける。
# ═══════════════════════════════════════════════════════════════

load "../fixtures/stall_detector/safe_cleanup"

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    DETECTOR="$PROJECT_ROOT/scripts/stall_detector.sh"
    FIXTURES="$PROJECT_ROOT/tests/fixtures/stall_detector"
    # 一時 root は project-local の git-ignored tree に置く。$BATS_TMPDIR (通常 /tmp)
    # は project working tree 外ゆえ、teardown の rm -rf が CLAUDE.md D002
    # (project tree 外への rm -rf 禁止) 違反になる。
    TEST_ROOT_BASE="$PROJECT_ROOT/tmp/stall_detector_tests"
    mkdir -p "$TEST_ROOT_BASE"
    STALL_ROOT="$(mktemp -d "$TEST_ROOT_BASE/unit.XXXXXX")"
    mkdir -p "$STALL_ROOT/queue/tasks" "$STALL_ROOT/queue/reports" "$STALL_ROOT/queue/inbox"
}

teardown() {
    # project-bounded cleanup: rm -rf は tmp/stall_detector_tests/ 配下に限定。
    safe_rm_test_root "$PROJECT_ROOT" "${STALL_ROOT:-}"
}

# ─── helpers ───

# epoch <iso8601> — ISO 8601 (local tz) を Unix epoch に変換
epoch() { date -d "$1" +%s; }

# load_fixture <scenario> — fixture の queue/ tree を STALL_ROOT に展開
load_fixture() {
    cp -r "$FIXTURES/$1/queue/." "$STALL_ROOT/queue/"
}

# scan <now_iso> [pane_json] — detector を --once で 1 回走らせる
scan() {
    local now_iso="$1"
    local pane_json="${2:-}"
    [ -n "$pane_json" ] || pane_json='{}'
    run env STALL_ROOT="$STALL_ROOT" \
            STALL_NOW="$(epoch "$now_iso")" \
            STALL_PANE_STATES_OVERRIDE="$pane_json" \
            bash "$DETECTOR" --once
}

# Same isolated fixture scan, but explicitly enables the Gunshi2 writer so its
# task/state transaction can be tested without touching a live mux or agent.
scan_with_gunshi2_writer() {
    local now_iso="$1"
    local pane_json="${2:-{}}"
    run env STALL_ROOT="$STALL_ROOT" \
            STALL_NOW="$(epoch "$now_iso")" \
            STALL_PANE_STATES_OVERRIDE="$pane_json" \
            STALL_TEST_ALLOW_GUNSHI2_WRITE=1 \
            bash "$DETECTOR" --once
}

# alerts_lines — stall_alerts.yaml の各 alert を
#   "<agent> <kind> <severity> <status> <count>" 1 行で出す
alerts_lines() {
    python3 - "$STALL_ROOT/queue/stall_alerts.yaml" <<'PYEOF'
import sys, yaml
try:
    doc = yaml.safe_load(open(sys.argv[1])) or {}
except FileNotFoundError:
    doc = {}
for a in (doc.get("alerts") or []):
    print("%s %s %s %s %s" % (a.get("agent"), a.get("kind"),
                              a.get("severity"), a.get("status"), a.get("count")))
PYEOF
}

# count_alerts — alert 総数
count_alerts() { alerts_lines | grep -c . || true; }

alert_evidence() {
    python3 - "$STALL_ROOT/queue/stall_alerts.yaml" <<'PYEOF'
import sys, yaml
try:
    doc = yaml.safe_load(open(sys.argv[1])) or {}
except FileNotFoundError:
    doc = {}
for a in (doc.get("alerts") or []):
    print(a.get("evidence") or "")
PYEOF
}

rca_state() {
    python3 - "$STALL_ROOT/queue/stall_detector_state.yaml" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
for key, value in (doc.get("rca_elapsed") or {}).items():
    print("%s %s %s" % (key, value.get("checkpoint", {}).get("state"),
                         value.get("escalation", {}).get("state")))
PYEOF
}

rca_entry() {
    python3 - "$STALL_ROOT/queue/stall_detector_state.yaml" "$1" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
print(yaml.safe_dump((doc.get("rca_elapsed") or {}).get(sys.argv[2]) or {}, sort_keys=True))
PYEOF
}

# ═══════════════════════════════════════════════════════════════
# Explicit RCA elapsed clock (all scans use isolated STALL_ROOT fixtures)
# ═══════════════════════════════════════════════════════════════

@test "RCA elapsed: 59m quiet, 60m checkpoint once, 119m no escalation, 120m one intent" {
    load_fixture rca_elapsed
    scan "2026-05-15T00:59:00" '{"ashigaru1":"busy"}'
    [ "$status" -eq 0 ]
    run rca_state
    [ "${lines[0]}" = "direct_lord_rca_shortcut_20260710|rca_direct_01 pending pending" ]
    scan "2026-05-15T01:00:00" '{"ashigaru1":"busy"}'
    [[ "$output" == *"rca_checkpoint_due"* ]]
    scan "2026-05-15T01:59:00" '{"ashigaru1":"busy"}'
    [[ "$output" != *"rca_elapsed_120m"* ]]
    scan "2026-05-15T02:00:00" '{"ashigaru1":"busy"}'
    [[ "$output" == *"rca_elapsed_120m"* ]]
    scan "2026-05-15T02:01:00" '{"ashigaru1":"busy"}'
    [[ "$output" != *"rca_elapsed_120m"* ]]
}

@test "RCA elapsed: matching outcome suppresses only its own family" {
    load_fixture rca_elapsed
    cat >> "$STALL_ROOT/queue/reports/ashigaru1_report.yaml" <<'EOF'
rca_events:
  - event: outcome
    parent_cmd: direct_lord_rca_shortcut_20260710
    family_id: rca_direct_01
    outcome: completed
    timestamp: "2026-05-15T01:30:00+09:00"
EOF
    scan "2026-05-15T02:00:00" '{"ashigaru1":"busy"}'
    [ "$status" -eq 0 ]
    [[ "$output" != *"rca_elapsed_120m"* ]]
    run rca_state
    [[ "${lines[0]}" == *"suppressed_terminal" ]]
}

@test "RCA elapsed: different family terminal does not suppress and markerless task stays legacy" {
    load_fixture rca_elapsed
    cat >> "$STALL_ROOT/queue/reports/ashigaru1_report.yaml" <<'EOF'
rca_events:
  - event: outcome
    parent_cmd: direct_lord_rca_shortcut_20260710
    family_id: other_family
    outcome: failed
EOF
    cat > "$STALL_ROOT/queue/tasks/ashigaru2.yaml" <<'EOF'
task:
  task_id: markerless_build
  parent_cmd: cmd_legacy
  status: assigned
  type: build
  timestamp: "2026-05-15T00:00:00+09:00"
EOF
    scan "2026-05-15T02:00:00" '{"ashigaru1":"busy","ashigaru2":"busy"}'
    [[ "$output" == *"rca_elapsed_120m"* ]]
    [[ "$output" != *"cmd_legacy\trca_elapsed_120m"* ]]
}

@test "RCA elapsed: occupied Gunshi2 slot remains byte-identical then dispatches once when free" {
    load_fixture rca_elapsed
    cat > "$STALL_ROOT/queue/tasks/gunshi2.yaml" <<'EOF'
task:
  task_id: unrelated_gunshi2_work
  parent_cmd: cmd_other
  status: assigned
EOF
    local before after
    before="$(sha256sum "$STALL_ROOT/queue/tasks/gunshi2.yaml")"
    scan "2026-05-15T02:00:00" '{"ashigaru1":"busy"}'
    [ "$status" -eq 0 ]
    after="$(sha256sum "$STALL_ROOT/queue/tasks/gunshi2.yaml")"
    [ "$before" = "$after" ]
    run rca_state
    [[ "${lines[0]}" == *"pending_gunshi2_slot" ]]
    sed -i 's/status: assigned/status: done/' "$STALL_ROOT/queue/tasks/gunshi2.yaml"
    scan "2026-05-15T02:01:00" '{"ashigaru1":"busy"}'
    [[ "$output" == *"rca_elapsed_120m"* ]]
    scan "2026-05-15T02:02:00" '{"ashigaru1":"busy"}'
    [[ "$output" != *"rca_elapsed_120m"* ]]
}

@test "RCA elapsed: parent cooldown preserves another family, invalid thresholds fail closed, and terminal wins" {
    load_fixture rca_elapsed_edgecases
    scan "2026-05-15T02:00:00" '{"ashigaru1":"busy","ashigaru2":"busy"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RCA threshold invalid"* ]]
    run rca_entry "cmd_parent_cooldown|family_waiting"
    [[ "$output" == *"pending_parent_cooldown"* ]]
    run rca_entry "cmd_invalid_thresholds|family_invalid"
    [[ "$output" == *"suppressed_invalid_threshold"* ]]
    [[ "$output" == *"invalid_fail_closed"* ]]
    cat >> "$STALL_ROOT/queue/reports/ashigaru1_report.yaml" <<'EOF'
rca_events:
  - event: outcome
    parent_cmd: cmd_parent_cooldown
    family_id: family_waiting
    outcome: completed
    timestamp: "2026-05-15T02:01:00+09:00"
EOF
    scan "2026-05-15T02:01:00" '{"ashigaru1":"busy","ashigaru2":"busy"}'
    run rca_entry "cmd_parent_cooldown|family_waiting"
    [[ "$output" == *"suppressed_terminal"* ]]
}

@test "RCA elapsed: expired parent cooldown dispatches and P0 bypasses it" {
    load_fixture rca_elapsed_edgecases
    scan "2026-05-15T07:31:00" '{"ashigaru1":"busy","ashigaru2":"busy"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rca_elapsed_120m"* ]]

    load_fixture rca_elapsed_edgecases
    cp "$FIXTURES/rca_elapsed_edgecases/queue/stall_detector_state.yaml" \
       "$STALL_ROOT/queue/stall_detector_state.yaml"
    sed -i "/family_id: family_waiting/a\\    escalation_severity: P0" "$STALL_ROOT/queue/tasks/ashigaru1.yaml"
    scan "2026-05-15T02:00:00" '{"ashigaru1":"busy","ashigaru2":"busy"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rca_elapsed_120m"* ]]
    run rca_entry "cmd_parent_cooldown|family_waiting"
    [[ "$output" == *"intent_emitted"* ]]
}

@test "RCA writer: A dispatch cools raw parent, B waits then dispatches, and P0 bypass keeps P0 priority" {
    load_fixture rca_elapsed
    cat > "$STALL_ROOT/queue/tasks/ashigaru2.yaml" <<'EOF'
task:
  task_id: rca_family_b
  parent_cmd: direct_lord_rca_shortcut_20260710
  status: assigned
  rca_tracking:
    enabled: true
    family_id: family_b
    started_at: "2026-05-15T00:00:00+09:00"
EOF
    scan_with_gunshi2_writer "2026-05-15T02:00:00" '{"ashigaru1":"busy","ashigaru2":"busy"}'
    [ "$status" -eq 0 ]
    # The isolated writer is allowed to change only STALL_ROOT.  Its explicit
    # suppression log distinguishes this from the real-agent inbox branch.
    [[ "$output" == *"inbox suppressed"* ]]
    scan_with_gunshi2_writer "2026-05-15T02:01:00" '{"ashigaru1":"busy","ashigaru2":"busy"}'
    [ "$status" -eq 0 ]
    run rca_entry "direct_lord_rca_shortcut_20260710|family_b"
    [[ "$output" == *"pending_parent_cooldown"* ]]
    run python3 - "$STALL_ROOT/queue/stall_detector_state.yaml" <<'PYEOF'
import sys, yaml
record = (yaml.safe_load(open(sys.argv[1])) or {}).get("rca_parent_cooldowns", {}).get("direct_lord_rca_shortcut_20260710") or {}
assert record.get("family_id") == "rca_direct_01"
assert record.get("severity") == "P1"
assert record.get("dispatched_at") and record.get("expires_at")
PYEOF
    [ "$status" -eq 0 ]
    sed -i 's/status: assigned/status: done/' "$STALL_ROOT/queue/tasks/gunshi2.yaml"
    scan_with_gunshi2_writer "2026-05-15T08:01:00" '{"ashigaru1":"busy","ashigaru2":"busy"}'
    [ "$status" -eq 0 ]
    run rca_entry "direct_lord_rca_shortcut_20260710|family_b"
    [[ "$output" == *"dispatched"* ]]
    sed -i 's/status: assigned/status: done/' "$STALL_ROOT/queue/tasks/gunshi2.yaml"
    cat > "$STALL_ROOT/queue/tasks/ashigaru3.yaml" <<'EOF'
task:
  task_id: rca_family_p0
  parent_cmd: direct_lord_rca_shortcut_20260710
  status: assigned
  rca_tracking:
    enabled: true
    family_id: family_p0
    started_at: "2026-05-15T00:00:00+09:00"
    escalation_severity: P0
EOF
    scan_with_gunshi2_writer "2026-05-15T08:02:00" '{"ashigaru1":"busy","ashigaru2":"busy","ashigaru3":"busy"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"inbox suppressed"* ]]
    run python3 - "$STALL_ROOT/queue/tasks/gunshi2.yaml" <<'PYEOF'
import sys, yaml
task = (yaml.safe_load(open(sys.argv[1])) or {}).get("task") or {}
assert task.get("priority") == "P0"
assert (task.get("trigger") or {}).get("severity") == "P0"
PYEOF
    [ "$status" -eq 0 ]
}

@test "RCA elapsed: clock ignores busy, worktree and ordinary report progress after checkpoint" {
    load_fixture rca_elapsed
    mkdir -p "$STALL_ROOT/worktree"
    sed -i "/type: implementation/a\\  worktree: $STALL_ROOT/worktree" "$STALL_ROOT/queue/tasks/ashigaru1.yaml"
    scan "2026-05-15T00:59:00" '{"ashigaru1":"busy"}'
    [[ "$output" != *"rca_checkpoint_due"* ]]
    scan "2026-05-15T01:00:00" '{"ashigaru1":"busy"}'
    [[ "$output" == *"rca_checkpoint_due"* ]]
    touch "$STALL_ROOT/worktree/progress"
    cat > "$STALL_ROOT/queue/reports/ashigaru1_report.yaml" <<'EOF'
report:
  task_id: unrelated_progress
  status: in_progress
  timestamp: "2026-05-15T01:30:00+09:00"
EOF
    scan "2026-05-15T02:00:00" '{"ashigaru1":"busy"}'
    [[ "$output" == *"rca_elapsed_120m"* ]]
}

@test "Gunshi2 capacity notices are deduplicated for RCA and generic intents" {
    load_fixture rca_elapsed
    cat > "$STALL_ROOT/queue/tasks/gunshi2.yaml" <<'EOF'
task:
  task_id: unrelated_gunshi2_work
  parent_cmd: cmd_other
  status: assigned
EOF
    cat > "$STALL_ROOT/queue/tasks/ashigaru2.yaml" <<'EOF'
task:
  task_id: generic_stall
  parent_cmd: cmd_generic
  status: assigned
  type: implementation
  timestamp: "2026-05-15T00:00:00+09:00"
EOF
    scan "2026-05-15T02:00:00" '{"ashigaru1":"busy","ashigaru2":"idle"}'
    [[ "$output" == *"rca_gunshi2_capacity"* ]]
    scan "2026-05-15T02:01:00" '{"ashigaru1":"busy","ashigaru2":"idle"}'
    [[ "$output" != *"rca_gunshi2_capacity"* ]]
    [[ "$output" == *"gunshi2_capacity"* ]]
    scan "2026-05-15T02:02:00" '{"ashigaru1":"busy","ashigaru2":"idle"}'
    [[ "$output" != *"gunshi2_capacity"* ]]
    run python3 - "$STALL_ROOT/queue/stall_detector_state.yaml" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
notices = doc.get("gunshi2_capacity_notices") or {}
assert notices["rca:direct_lord_rca_shortcut_20260710:rca_direct_01"]["notified_at"]
assert notices["generic:cmd_generic:assigned_no_progress"]["notified_at"]
PYEOF
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# kind: blocked_report_unresolved
# ═══════════════════════════════════════════════════════════════

@test "blocked_report_unresolved: blocked report past 15m threshold emits one P1 alert" {
    load_fixture blocked_unresolved
    scan "2026-05-15T00:25:00"
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "ashigaru1 blocked_report_unresolved P1 open 1" ]
}

@test "blocked_report_unresolved: blocked report below 15m threshold emits no alert" {
    load_fixture blocked_unresolved
    scan "2026-05-15T00:10:00"
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
}

@test "blocked_report_unresolved: blocked report past 60m escalates to P0" {
    load_fixture blocked_unresolved
    scan "2026-05-15T01:10:00"
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "ashigaru1 blocked_report_unresolved P0 open 1" ]
}

# ═══════════════════════════════════════════════════════════════
# kind: assigned_no_progress  (+ worktree progress false-positive control)
# ═══════════════════════════════════════════════════════════════

@test "assigned_no_progress: idle pane + stale assigned task past 45m emits P2 alert" {
    load_fixture assigned_no_progress
    # idle_streak >= 2 が必要 — 1 回目の scan ではまだ alert しない
    scan "2026-05-15T00:50:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
    # 2 回連続 idle scan → threshold (45m) 超で alert
    scan "2026-05-15T00:50:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "ashigaru1 assigned_no_progress P2 open"* ]]
}

@test "assigned_no_progress: worktree HEAD/mtime progress suppresses the alert" {
    # assigned_worktree fixture の placeholder worktree を test 制御の tmp dir に差し替える。
    # 上の test と同条件 (idle 2 連続, 50m 経過) だが worktree 進捗があるため抑制される、
    # という対比で worktree progress tracking を検証する。
    local wt="$STALL_ROOT/wt"
    mkdir -p "$wt"
    : > "$wt/file_a"
    touch -d "2026-05-14T00:00:00" "$wt/file_a" "$wt"
    load_fixture assigned_worktree
    sed -i "s#@@WORKTREE@@#$wt#" "$STALL_ROOT/queue/tasks/ashigaru1.yaml"

    scan "2026-05-15T00:50:00" '{"ashigaru1":"idle"}'   # scan1: baseline signature
    [ "$status" -eq 0 ]
    # worktree に進捗を起こす (mtime 前進 → signature 変化)
    : > "$wt/file_b"
    touch -d "2026-05-15T06:00:00" "$wt/file_b" "$wt"
    scan "2026-05-15T00:50:00" '{"ashigaru1":"idle"}'   # scan2: progress 検出 → 抑制
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# kind: idle_with_active_task
# ═══════════════════════════════════════════════════════════════

@test "idle_with_active_task: idle pane holding active task past 30m emits P2 alert" {
    load_fixture assigned_no_progress
    # 35m 経過 (>=30m idle_with_active, <45m assigned_no_progress) を idle 2 連続で
    scan "2026-05-15T00:35:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
    scan "2026-05-15T00:35:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "ashigaru1 idle_with_active_task P2 open"* ]]
}

# ═══════════════════════════════════════════════════════════════
# dedupe / cooldown
# ═══════════════════════════════════════════════════════════════

@test "dedupe/cooldown: repeated scan within cooldown does not duplicate or re-notify" {
    load_fixture blocked_unresolved
    scan "2026-05-15T00:25:00"
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "ashigaru1 blocked_report_unresolved P1 open 1" ]
    # 同一 STALL_NOW で再 scan → cooldown (30m) 内ゆえ count 据え置き / alert 重複なし
    scan "2026-05-15T00:25:00"
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "ashigaru1 blocked_report_unresolved P1 open 1" ]
}

# ═══════════════════════════════════════════════════════════════
# auto-resolve
# ═══════════════════════════════════════════════════════════════

@test "auto-resolve: blocked report turning terminal auto-resolves the open alert" {
    load_fixture blocked_unresolved
    scan "2026-05-15T00:25:00"
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${lines[0]}" = "ashigaru1 blocked_report_unresolved P1 open 1" ]
    # report の最新 entry が done (terminal) に変化
    cp "$FIXTURES/blocked_resolved/queue/reports/ashigaru1_report.yaml" \
       "$STALL_ROOT/queue/reports/ashigaru1_report.yaml"
    scan "2026-05-15T01:35:00"
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "ashigaru1 blocked_report_unresolved P1 resolved 1" ]
}

# ═══════════════════════════════════════════════════════════════
# false-positive controls
# ═══════════════════════════════════════════════════════════════

@test "false-positive: status idle + task_id null never alerts" {
    load_fixture fp_idle_null
    scan "2026-05-15T12:00:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
}

@test "false-positive: task with blocked_by (intentional dependency hold) never alerts" {
    load_fixture fp_blocked_by
    scan "2026-05-15T12:00:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# kind: agent_unread_unprocessed
# ═══════════════════════════════════════════════════════════════

@test "agent_unread_unprocessed: ashigaru unread idle past threshold emits alert with dedupe metadata" {
    load_fixture unread_ashigaru_idle
    scan "2026-05-15T00:20:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "ashigaru1 agent_unread_unprocessed P2 open"* ]]
    run alert_evidence
    [[ "${lines[0]}" == *"pane=idle"* ]]
    [[ "${lines[0]}" == *"retry_count=2"* ]]
    [[ "${lines[0]}" == *"last_notified_at=2026-05-15T00:05:00"* ]]
}

@test "agent_unread_unprocessed: karo unread busy is included and reported as busy evidence" {
    load_fixture unread_karo_busy
    scan "2026-05-15T00:50:00" '{"karo":"busy"}'
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "karo agent_unread_unprocessed P3 open"* ]]
    run alert_evidence
    [[ "${lines[0]}" == *"pane=busy"* ]]
    [[ "${lines[0]}" == *"threshold=45m"* ]]
}

@test "agent_unread_unprocessed: gunshi unread is suppressed when report progressed after message timestamp" {
    load_fixture unread_resolved_report_progress
    scan "2026-05-15T00:30:00" '{"gunshi":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
}

@test "agent_unread_unprocessed: unread is suppressed when task timestamp progressed after message timestamp" {
    load_fixture unread_resolved_task_progress
    scan "2026-05-15T00:30:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
}

@test "agent_unread_unprocessed: blocked P0/P1 is not hidden by lower-severity unread" {
    load_fixture blocked_with_unread
    scan "2026-05-15T01:05:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "ashigaru1 blocked_report_unresolved P0 open 1" ]
}

@test "agent_unread_unprocessed: unread is suppressed when task completed_at progressed after message timestamp" {
    load_fixture unread_resolved_task_completed_at
    scan "2026-05-15T00:30:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
}
