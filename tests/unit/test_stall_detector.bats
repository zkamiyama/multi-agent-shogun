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

@test "assigned_no_progress: 60m target resume is one-shot and re-arms after progress" {
    load_fixture assigned_no_progress

    # First scan establishes the idle streak; the second crosses 60m since the
    # task timestamp and must keep the existing Karo alert plus emit one target
    # resume request.  Fixture roots must suppress real inbox delivery.
    scan "2026-05-15T00:59:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    scan "2026-05-15T01:00:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESUME (test-mode, inbox suppressed)"* ]]
    [[ "$output" == *"type=stall_resume_required"* ]]
    [[ "$output" == *"queue/tasks/ashigaru1.yaml"* ]]
    [[ "$output" == *"progress or blocker report"* ]]
    [[ "$output" == *"DEDUP_KEY=stall-resume:ashigaru1:fixture_assigned_task:"* ]]
    run alerts_lines
    [[ "$output" == *"ashigaru1 assigned_no_progress"* ]]

    # Same task and same last-progress timestamp: no duplicate target nudge.
    scan "2026-05-15T01:01:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [[ "$output" != *"RESUME (test-mode, inbox suppressed)"* ]]

    # A newer report timestamp is observable progress and re-arms the same
    # task's next 60m episode.
    cat > "$STALL_ROOT/queue/reports/ashigaru1_report.yaml" <<'EOF'
report:
  - task_id: fixture_assigned_task
    status: in_progress
    timestamp: "2026-05-15T01:02:00"
EOF
    scan "2026-05-15T02:02:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESUME (test-mode, inbox suppressed)"* ]]
    run python3 - "$STALL_ROOT/queue/stall_detector_state.yaml" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
entry = (doc.get("resume_notifications") or {}).get("ashigaru1") or {}
assert entry.get("task_id") == "fixture_assigned_task"
assert entry.get("delivered") is True
assert entry.get("progress_at", "").startswith("2026-05-15T01:02:00")
assert entry.get("episode_key", "").endswith("2026-05-15T01:02:00+09:00")
assert entry.get("dedup_key", "").startswith("stall-resume:ashigaru1:fixture_assigned_task:")
PYEOF
    [ "$status" -eq 0 ]
}

@test "normal scan atomically updates detector heartbeat" {
    load_fixture assigned_no_progress
    scan "2026-05-15T00:01:00" '{}'
    [ "$status" -eq 0 ]
    [ -f "$STALL_ROOT/queue/stall_detector.heartbeat" ]
    run python3 - "$STALL_ROOT/queue/stall_detector.heartbeat" <<'PYEOF'
import sys
value = open(sys.argv[1], encoding="utf-8").read().strip()
assert value.isdigit(), value
assert int(value) > 0, value
PYEOF
    [ "$status" -eq 0 ]
    [ "$(cat "$STALL_ROOT/queue/stall_detector.heartbeat")" -eq "$(epoch '2026-05-15T00:01:00')" ]
    [ -z "$(find "$STALL_ROOT/queue" -maxdepth 1 -name 'stall_detector.heartbeat.tmp.*' -print -quit)" ]
}

@test "60m target resume is based on last_progress even when pane is busy" {
    load_fixture assigned_no_progress
    scan "2026-05-15T01:00:00" '{"ashigaru1":"busy"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESUME (test-mode, inbox suppressed)"* ]]
}

@test "60m target resume includes assigned Gunshi and Gunshi2 workers" {
    load_fixture assigned_no_progress
    cat > "$STALL_ROOT/queue/tasks/gunshi.yaml" <<'EOF'
task:
  task_id: fixture_gunshi_task
  parent_cmd: cmd_fixture_gunshi
  status: assigned
  type: analysis
  timestamp: "2026-05-15T00:00:00"
EOF
    cat > "$STALL_ROOT/queue/tasks/gunshi2.yaml" <<'EOF'
task:
  task_id: fixture_gunshi2_task
  parent_cmd: cmd_fixture_gunshi2
  status: assigned
  type: analysis
  timestamp: "2026-05-15T00:00:00"
EOF
    scan "2026-05-15T01:00:00" '{}'
    [ "$status" -eq 0 ]
    [ "$(grep -c 'type=stall_resume_required' <<<"$output")" -eq 3 ]
    [[ "$output" == *"gunshi task=fixture_gunshi_task"* ]]
    [[ "$output" == *"gunshi2 task=fixture_gunshi2_task"* ]]
    [ "$(find "$STALL_ROOT/queue/inbox" -type f -name '*.yaml' -print -exec grep -l 'stall_resume_required' {} \; | wc -l)" -eq 0 ]
}

@test "60m target resume ignores a prior task's terminal report" {
    load_fixture assigned_no_progress
    cat > "$STALL_ROOT/queue/reports/ashigaru1_report.yaml" <<'EOF'
report:
  - task_id: prior_task
    status: done
    timestamp: "2026-05-15T00:59:00"
EOF

    scan "2026-05-15T01:00:00" '{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"type=stall_resume_required"* ]]
    run python3 - "$STALL_ROOT/queue/stall_detector_state.yaml" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
entry = (doc.get("resume_notifications") or {}).get("ashigaru1") or {}
assert entry.get("task_id") == "fixture_assigned_task"
assert entry.get("progress_at", "").startswith("2026-05-15T00:00:00")
PYEOF
    [ "$status" -eq 0 ]
}

@test "report extractor preserves worker_id-first record boundaries" {
    load_fixture assigned_no_progress
    cat > "$STALL_ROOT/queue/reports/ashigaru1_report.yaml" <<'EOF'
report:
  - task_id: fixture_assigned_task
    status: done
    timestamp: "2026-05-15T00:59:00"
  - worker_id: ashigaru7
    status: in_progress
    timestamp: "2026-05-15T01:00:00"
EOF

    scan "2026-05-15T02:00:00" '{}'
    [ "$status" -eq 0 ]
    [[ "$output" != *"type=stall_resume_required"* ]]
}

@test "report extractor streams the current-size report without safe_load_all" {
    load_fixture assigned_no_progress
    cp "$PROJECT_ROOT/queue/reports/gunshi_report.yaml" \
       "$STALL_ROOT/queue/reports/gunshi_report.yaml"
    cat > "$STALL_ROOT/queue/tasks/gunshi.yaml" <<'EOF'
task:
  task_id: fixture_large_report_task
  parent_cmd: cmd_fixture_large_report
  status: assigned
  type: analysis
  timestamp: "2026-05-15T00:00:00"
EOF
    run timeout 20 env STALL_ROOT="$STALL_ROOT" \
        STALL_NOW="$(epoch '2026-05-15T00:01:00')" \
        STALL_PANE_STATES_OVERRIDE='{}' \
        bash "$DETECTOR" --once
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUMMARY:"* ]]
    [ -f "$STALL_ROOT/queue/stall_detector.heartbeat" ]
    ! grep -q 'safe_load_all' "$DETECTOR"
}

@test "resume episode persists only after delivery and retries the same dedup key" {
    local copied_root="$STALL_ROOT/copy-root"
    mkdir -p "$copied_root/scripts" "$copied_root/queue/tasks" \
             "$copied_root/queue/reports" "$copied_root/queue/inbox" \
             "$copied_root/logs"
    cp "$DETECTOR" "$copied_root/scripts/stall_detector.sh"
    cp "$PROJECT_ROOT/scripts/stall_state.py" "$copied_root/scripts/stall_state.py"
    cp "$FIXTURES/assigned_no_progress/queue/tasks/ashigaru1.yaml" \
       "$copied_root/queue/tasks/ashigaru1.yaml"
    cat > "$copied_root/scripts/inbox_write.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/../resume_delivery.log"
if [ ! -f "$(dirname "$0")/../allow_delivery" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$copied_root/scripts/inbox_write.sh"

    run env -u STALL_ROOT \
            STALL_NOW="$(epoch '2026-05-15T01:00:00')" \
            STALL_PANE_STATES_OVERRIDE='{}' \
            bash "$copied_root/scripts/stall_detector.sh" --once
    [ "$status" -eq 0 ]
    [[ "$output" == *"inbox_write.sh failed"* ]]
    run python3 - "$copied_root/queue/stall_detector_state.yaml" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
entry = (doc.get("resume_notifications") or {}).get("ashigaru1") or {}
assert entry.get("delivered") is False
assert entry.get("dedup_key", "").startswith("stall-resume:ashigaru1:fixture_assigned_task:")
PYEOF
    [ "$status" -eq 0 ]

    : > "$copied_root/allow_delivery"
    run env -u STALL_ROOT \
            STALL_NOW="$(epoch '2026-05-15T01:00:00')" \
            STALL_PANE_STATES_OVERRIDE='{}' \
            bash "$copied_root/scripts/stall_detector.sh" --once
    [ "$status" -eq 0 ]
    run python3 - "$copied_root/queue/stall_detector_state.yaml" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
entry = (doc.get("resume_notifications") or {}).get("ashigaru1") or {}
assert entry.get("delivered") is True
assert entry.get("delivered_at")
PYEOF
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$copied_root/resume_delivery.log")" -eq 2 ]
    grep -q 'ashigaru1 .* stall_resume_required stall_detector' "$copied_root/resume_delivery.log"
    grep -q 'DEDUP_KEY=stall-resume:ashigaru1:fixture_assigned_task:' "$copied_root/resume_delivery.log"
}

@test "overlapping detector scans preserve a delivered resume state" {
    local copied_root="$STALL_ROOT/concurrent-root"
    mkdir -p "$copied_root/scripts" "$copied_root/queue/tasks" \
             "$copied_root/queue/reports" "$copied_root/queue/inbox" \
             "$copied_root/logs"
    cp "$DETECTOR" "$copied_root/scripts/stall_detector.sh"
    cp "$PROJECT_ROOT/scripts/stall_state.py" "$copied_root/scripts/stall_state.py"
    cp "$FIXTURES/assigned_no_progress/queue/tasks/ashigaru1.yaml" \
       "$copied_root/queue/tasks/ashigaru1.yaml"
    cat > "$copied_root/scripts/inbox_write.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$copied_root/scripts/inbox_write.sh"
    cat > "$copied_root/queue/stall_detector_state.yaml" <<'EOF'
last_scan: null
last_error: null
scan_count: 0
pane_idle_streak: {}
worktree_progress: {}
gunshi2_escalations: {}
resume_notifications: {}
EOF
    printf 'alerts: []\n' > "$copied_root/queue/stall_alerts.yaml"

    env -u STALL_ROOT STALL_NOW="$(epoch '2026-05-15T01:00:00')" \
        STALL_PANE_STATES_OVERRIDE='{}' STALL_TEST_STATE_LOCK_HOLD_SEC=0.2 \
        bash "$copied_root/scripts/stall_detector.sh" --once \
        >"$copied_root/scan-a.log" 2>&1 &
    local scan_a=$!
    env -u STALL_ROOT STALL_NOW="$(epoch '2026-05-15T01:00:00')" \
        STALL_PANE_STATES_OVERRIDE='{}' STALL_TEST_STATE_LOCK_HOLD_SEC=0.2 \
        bash "$copied_root/scripts/stall_detector.sh" --once \
        >"$copied_root/scan-b.log" 2>&1 &
    local scan_b=$!
    wait "$scan_a"
    wait "$scan_b"

    run python3 - "$copied_root/queue/stall_detector_state.yaml" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
entry = (doc.get("resume_notifications") or {}).get("ashigaru1") or {}
assert entry.get("delivered") is True, entry
assert entry.get("dedup_key", "").startswith("stall-resume:ashigaru1:fixture_assigned_task:")
PYEOF
    [ "$status" -eq 0 ]
}

@test "overlapping alert commits merge records and claim one Karo notification" {
    local alerts_file="$STALL_ROOT/queue/stall_alerts.yaml"
    printf 'alerts: []\n' > "$alerts_file"
    run python3 - "$PROJECT_ROOT/scripts" "$alerts_file" <<'PYEOF'
import copy
import sys
import threading
import yaml

sys.path.insert(0, sys.argv[1])
from stall_state import merge_alerts

path = sys.argv[2]
now = "2026-05-15T01:00:00+09:00"

def proposal(key, evidence):
    return [{
        "key": key,
        "agent": "ashigaru1",
        "task_id": key,
        "kind": "assigned_no_progress",
        "severity": "P2",
        "first_seen": now,
        "last_seen": now,
        "last_notified": now,
        "count": 1,
        "status": "open",
        "evidence": evidence,
    }]

early = proposal("earliest-key", "older observation")
early[0]["first_seen"] = "2026-05-15T00:00:00+09:00"
early[0]["last_seen"] = "2026-05-15T00:30:00+09:00"
merge_alerts(path, [], early, {"earliest-key"}, [], early[0]["last_seen"], 30)
late = proposal("earliest-key", "newer observation")
late[0]["first_seen"] = "2026-05-15T00:45:00+09:00"
late[0]["last_seen"] = "2026-05-15T01:00:00+09:00"
merge_alerts(path, early, late, {"earliest-key"}, [], late[0]["last_seen"], 30)
doc = yaml.safe_load(open(path, encoding="utf-8")) or {}
earliest = [a for a in doc.get("alerts", []) if a.get("key") == "earliest-key"]
assert earliest[0].get("first_seen") == "2026-05-15T00:00:00+09:00", earliest

same_results = []
def same_worker():
    same_results.append(merge_alerts(
        path, [], proposal("same-key", "same observation"), {"same-key"},
        [{"key": "same-key", "severity": "P2", "summary": "same", "dedup_key": "stall-alert:same-key"}],
        now, 30,
    ))

threads = [threading.Thread(target=same_worker) for _ in range(2)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
assert sum(len(result[1]) for result in same_results) == 1, same_results
claimed = [claim for result in same_results for claim in result[1]]
assert claimed[0].get("dedup_key") == "stall-alert:same-key:1", claimed
doc = yaml.safe_load(open(path, encoding="utf-8")) or {}
same = [a for a in doc.get("alerts", []) if a.get("key") == "same-key"]
assert len(same) == 1 and same[0].get("count") == 1, same

with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump({"alerts": []}, stream, sort_keys=False)
distinct_results = []
def distinct_worker(key):
    distinct_results.append(merge_alerts(
        path, [], proposal(key, key), {key},
        [{"key": key, "severity": "P2", "summary": key, "dedup_key": f"stall-alert:{key}"}],
        now, 30,
    ))

threads = [threading.Thread(target=distinct_worker, args=(key,)) for key in ("key-a", "key-b")]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
assert sum(len(result[1]) for result in distinct_results) == 2, distinct_results
doc = yaml.safe_load(open(path, encoding="utf-8")) or {}
assert {a.get("key") for a in doc.get("alerts", [])} == {"key-a", "key-b"}, doc
PYEOF
    [ "$status" -eq 0 ]
}

@test "alert observations are monotonic across stale active and resolving scans" {
    local alerts_file="$STALL_ROOT/queue/stall_alerts.yaml"
    printf 'alerts: []\n' > "$alerts_file"
    run python3 - "$PROJECT_ROOT/scripts" "$alerts_file" <<'PYEOF'
import sys
import yaml

sys.path.insert(0, sys.argv[1])
from stall_state import merge_alerts

path = sys.argv[2]

def record(status, observed, last_notified):
    return [{
        "key": "monotonic-key",
        "agent": "ashigaru1",
        "task_id": "monotonic-task",
        "kind": "assigned_no_progress",
        "severity": "P2",
        "first_seen": "2026-05-15T00:00:00+09:00",
        "last_seen": observed,
        "observed_at": observed,
        "last_notified": last_notified,
        "count": 1,
        "status": status,
        "evidence": status,
    }]

def intent():
    return [{
        "key": "monotonic-key",
        "severity": "P2",
        "summary": "monotonic",
        "dedup_key": "stall-alert:monotonic-key",
    }]

def current():
    return (yaml.safe_load(open(path, encoding="utf-8")) or {}).get("alerts", [])

# A newer resolution must not be reopened by an older active scan.
seed = record("open", "2026-05-15T00:00:00+09:00", "2026-05-15T00:00:00+09:00")
seed[0]["last_seen"] = "2026-05-15T01:00:00+09:00"
merge_alerts(path, [], seed, {"monotonic-key"}, intent(), seed[0]["observed_at"], 30)
resolved = record("resolved", "2026-05-15T02:00:00+09:00", "2026-05-15T02:00:00+09:00")
resolved[0]["last_seen"] = "2026-05-15T00:30:00+09:00"
merge_alerts(path, seed, resolved, set(), [], resolved[0]["observed_at"], 30)
assert current()[0]["last_seen"] == "2026-05-15T01:00:00+09:00", current()
stale_active = record("open", "2026-05-15T01:00:00+09:00", "2026-05-15T01:00:00+09:00")
result = merge_alerts(path, seed, stale_active, {"monotonic-key"}, intent(), stale_active[0]["observed_at"], 30)
assert result[1] == [], result
alert = current()[0]
# An exact observation tie is deterministic: terminal resolution wins in both
# commit orders rather than depending on which contender acquired the lock.
assert alert["status"] == "resolved", alert
assert alert["last_notified"] == "2026-05-15T02:00:00+09:00", alert

# Conversely, a newer active observation must not be closed by an older resolver.
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump({"alerts": []}, stream, sort_keys=False)
merge_alerts(path, [], seed, {"monotonic-key"}, intent(), seed[0]["observed_at"], 30)
active = record("open", "2026-05-15T02:00:00+09:00", "2026-05-15T02:00:00+09:00")
merge_alerts(path, seed, active, {"monotonic-key"}, intent(), active[0]["observed_at"], 30)
stale_resolved = record("resolved", "2026-05-15T01:00:00+09:00", "2026-05-15T01:00:00+09:00")
result = merge_alerts(path, active, stale_resolved, set(), [], stale_resolved[0]["observed_at"], 30)
assert result[1] == [], result
alert = current()[0]
assert alert["status"] == "open", alert
assert alert["last_notified"] == "2026-05-15T02:00:00+09:00", alert

# Equal observed_at commits choose terminal resolution deterministically, while
# first_seen remains monotonic in either commit order after the alert lock is
# released.
older = record("open", "2026-05-15T03:00:00+09:00", "2026-05-15T03:00:00+09:00")
older[0]["first_seen"] = "2026-05-15T00:00:00+09:00"
newer = record("resolved", "2026-05-15T03:00:00+09:00", "2026-05-15T03:00:00+09:00")
newer[0]["first_seen"] = "2026-05-15T01:00:00+09:00"
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump({"alerts": []}, stream, sort_keys=False)
merge_alerts(path, [], older, {"monotonic-key"}, [], older[0]["observed_at"], 30)
merge_alerts(path, older, newer, set(), [], newer[0]["observed_at"], 30)
alert = current()[0]
assert alert["status"] == "resolved", alert
assert alert["first_seen"] == "2026-05-15T00:00:00+09:00", alert

with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump({"alerts": []}, stream, sort_keys=False)
merge_alerts(path, [], newer, set(), [], newer[0]["observed_at"], 30)
merge_alerts(path, newer, older, {"monotonic-key"}, [], older[0]["observed_at"], 30)
alert = current()[0]
assert alert["status"] == "resolved", alert
assert alert["first_seen"] == "2026-05-15T00:00:00+09:00", alert

# A losing older observation still contributes its earlier first_seen, in both
# arrival orders.  Status follows the newer observation generation.
def generation(observed, first_seen):
    value = record("open", observed, observed)
    value[0]["first_seen"] = first_seen
    return value

older_generation = generation(
    "2026-05-15T04:00:00+09:00", "2026-05-15T00:00:00+09:00")
newer_generation = generation(
    "2026-05-15T05:00:00+09:00", "2026-05-15T01:00:00+09:00")
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump({"alerts": []}, stream, sort_keys=False)
merge_alerts(path, [], newer_generation, {"monotonic-key"}, [],
             newer_generation[0]["observed_at"], 30)
merge_alerts(path, newer_generation, older_generation, {"monotonic-key"}, [],
             older_generation[0]["observed_at"], 30)
assert current()[0]["first_seen"] == "2026-05-15T00:00:00+09:00", current()

with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump({"alerts": []}, stream, sort_keys=False)
merge_alerts(path, [], older_generation, {"monotonic-key"}, [],
             older_generation[0]["observed_at"], 30)
merge_alerts(path, older_generation, newer_generation, {"monotonic-key"}, [],
             newer_generation[0]["observed_at"], 30)
assert current()[0]["first_seen"] == "2026-05-15T00:00:00+09:00", current()
PYEOF
    [ "$status" -eq 0 ]
}

@test "short state transaction preserves resume delivery and RCA dispatch across a scan" {
    load_fixture rca_elapsed
    cat > "$STALL_ROOT/queue/stall_detector_state.yaml" <<'EOF'
last_scan: null
last_error: null
scan_count: 0
pane_idle_streak: {}
worktree_progress: {}
gunshi2_escalations: {}
gunshi2_capacity_notices: {}
rca_parent_cooldowns: {}
rca_elapsed:
  direct_lord_rca_shortcut_20260710|rca_direct_01:
    parent_cmd: direct_lord_rca_shortcut_20260710
    family_id: rca_direct_01
    started_at: "2026-05-15T00:00:00+09:00"
    checkpoint: {state: pending, notified_at: null}
    escalation: {state: pending, due_at: null, dispatched_at: null, gunshi2_task_id: null}
resume_notifications:
  ashigaru1:
    task_id: rca_probe_01
    episode_key: "ashigaru1:rca_probe_01:2026-05-15T00:00:00+09:00"
    dedup_key: "stall-resume:ashigaru1:rca_probe_01:2026-05-15T00:00:00+09:00"
    progress_at: "2026-05-15T00:00:00+09:00"
    delivered: false
EOF

    env STALL_ROOT="$STALL_ROOT" \
        STALL_NOW="$(epoch '2026-05-15T01:00:00')" \
        STALL_PANE_STATES_OVERRIDE='{"ashigaru1":"busy"}' \
        STALL_TEST_STATE_LOCK_HOLD_SEC=0.4 \
        bash "$DETECTOR" --once >"$STALL_ROOT/scan.log" 2>&1 &
    local scan_pid=$!
    sleep 0.1
    run python3 "$PROJECT_ROOT/scripts/stall_state.py" mark-delivered \
        "$STALL_ROOT/queue/stall_detector_state.yaml" ashigaru1 rca_probe_01 \
        "ashigaru1:rca_probe_01:2026-05-15T00:00:00+09:00" \
        "2026-05-15T00:00:00+09:00" \
        "stall-resume:ashigaru1:rca_probe_01:2026-05-15T00:00:00+09:00"
    [ "$status" -eq 0 ]
    run python3 "$PROJECT_ROOT/scripts/stall_state.py" mark-rca \
        "$STALL_ROOT/queue/stall_detector_state.yaml" \
        direct_lord_rca_shortcut_20260710 rca_direct_01 P1 \
        "2026-05-15T01:00:00+09:00" gunshi2_escalation_test 360
    [ "$status" -eq 0 ]
    wait "$scan_pid"

    run python3 - "$STALL_ROOT/queue/stall_detector_state.yaml" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
resume = (doc.get("resume_notifications") or {}).get("ashigaru1") or {}
rca = (doc.get("rca_elapsed") or {}).get("direct_lord_rca_shortcut_20260710|rca_direct_01") or {}
assert resume.get("delivered") is True, resume
assert (rca.get("escalation") or {}).get("state") == "dispatched", rca
assert (doc.get("scan_count") or 0) == 1, doc
PYEOF
    [ "$status" -eq 0 ]
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
