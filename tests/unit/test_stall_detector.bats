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
