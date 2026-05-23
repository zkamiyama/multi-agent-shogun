#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# Unit tests for stall_detector.sh — review/analysis task blind spot
#
# 動機: 直近の review 系 task (`type: review` または `type: analysis`) は read-only ゆえ
# task YAML status を assigned のままに保ち、report 側だけ verdict を書く慣例。verdict は
# "CLEAR" / "CMD_xxx_COMPLETE_PHASE_..." / "completed_pending_qc" 等 TERMINAL_STATUSES
# に literal 一致しないことが多く、idle_with_active_task / assigned_no_progress が
# false-positive で頻発していた。
#
# 本 suite は task type=review に対する canonical fingerprint (該当 task_id の report
# entry を直接 lookup) と broad terminal 判定が正しく機能するかを 5 sub-case で検証する。
# 既存 mesh/impl path の regression が無いことも明示確認。
#
# fixture anchor: 2026-05-15T00:00:00 基準。STALL_NOW を anchor からの相対時刻で与える。
# ═══════════════════════════════════════════════════════════════

load "../fixtures/stall_detector/safe_cleanup"

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    DETECTOR="$PROJECT_ROOT/scripts/stall_detector.sh"
    FIXTURES="$PROJECT_ROOT/tests/fixtures/stall_detector"
    # project-local の git-ignored tree に test root を置く (CLAUDE.md D002 遵守)。
    TEST_ROOT_BASE="$PROJECT_ROOT/tmp/stall_detector_tests"
    mkdir -p "$TEST_ROOT_BASE"
    STALL_ROOT="$(mktemp -d "$TEST_ROOT_BASE/review_blind_spot.XXXXXX")"
    mkdir -p "$STALL_ROOT/queue/tasks" "$STALL_ROOT/queue/reports" "$STALL_ROOT/queue/inbox"
}

teardown() {
    safe_rm_test_root "$PROJECT_ROOT" "${STALL_ROOT:-}"
}

# ─── helpers ───

epoch() { date -d "$1" +%s; }

load_fixture() {
    cp -r "$FIXTURES/$1/queue/." "$STALL_ROOT/queue/"
}

# scan <now_iso> [pane_json]
scan() {
    local now_iso="$1"
    local pane_json="${2:-}"
    [ -n "$pane_json" ] || pane_json='{}'
    run env STALL_ROOT="$STALL_ROOT" \
            STALL_NOW="$(epoch "$now_iso")" \
            STALL_PANE_STATES_OVERRIDE="$pane_json" \
            bash "$DETECTOR" --once
}

# alerts_lines — 1 alert = "<agent> <kind> <severity> <status> <count>"
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

count_alerts() { alerts_lines | grep -c . || true; }

# ═══════════════════════════════════════════════════════════════
# sub-case 1: review task + report status=done → alert skip (false-positive 防止)
# ═══════════════════════════════════════════════════════════════

@test "review blind spot 1: review task with report status=done suppresses idle_with_active_task" {
    load_fixture review_done
    # 35m 経過 — idle_with_active_task threshold (30m) を idle 2 連続で踏む条件。
    # 通常なら P2 alert が立つが、review task ゆえ report.status=done が canonical
    # fingerprint として認識され suppress される。
    scan "2026-05-15T00:35:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    scan "2026-05-15T00:35:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
    # assigned_no_progress threshold (45m) も同様に suppress される。
    scan "2026-05-15T00:50:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    scan "2026-05-15T00:50:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# sub-case 2: review task + report 不在 → 通常 alert (legitimate stall)
# ═══════════════════════════════════════════════════════════════

@test "review blind spot 2: review task with no report still emits idle_with_active_task (legitimate stall)" {
    load_fixture review_no_report
    # report が無いと canonical fingerprint も無い ゆえ suppress 発動条件を満たさず、
    # 通常 path で P2 alert が立つ (agent が review に着手すらしていない疑い)。
    scan "2026-05-15T00:35:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    scan "2026-05-15T00:35:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "ashigaru1 idle_with_active_task P2 open"* ]]
}

# ═══════════════════════════════════════════════════════════════
# sub-case 3: 既存 impl task path は regression なし
# ═══════════════════════════════════════════════════════════════

@test "review blind spot 3: non-review (impl) task path is unchanged (regression check)" {
    # 既存 assigned_no_progress fixture (type: infra_implementation) を再利用し、
    # review-suppression が impl path に副作用していないことを確認する。
    load_fixture assigned_no_progress
    scan "2026-05-15T00:50:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
    scan "2026-05-15T00:50:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "ashigaru1 assigned_no_progress P2 open"* ]]
}

# ═══════════════════════════════════════════════════════════════
# sub-case 4: review task + report status=in_progress → 通常 alert (legitimate)
# ═══════════════════════════════════════════════════════════════

@test "review blind spot 4: review task with in_progress report still emits alert (mid-work stall)" {
    load_fixture review_in_progress
    # fixture: 同一 task_id の in_progress report (timestamp は task assignment より前) を仕込み、
    # report_newer_than_task の既存 progress signal を意図的に外す。これにより、本 fix の
    # review-suppression が in_progress を terminal と誤認していないことを純粋に検証できる。
    # is_review_terminal_status("in_progress") == False → suppression 発動せず通常 path で
    # idle_with_active_task が threshold 30m を超えた時点で P2 alert。
    scan "2026-05-15T00:35:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    scan "2026-05-15T00:35:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "ashigaru1 idle_with_active_task P2 open"* ]]
}

# ═══════════════════════════════════════════════════════════════
# sub-case 5: review task + report status=blocked → escalation path 保持
# ═══════════════════════════════════════════════════════════════

@test "review blind spot 5: review task with blocked report routes to blocked_report_unresolved (P1)" {
    load_fixture review_blocked
    # status=blocked は REVIEW_NON_TERMINAL_TOKENS に含まれゆえ review-suppression が
    # 発動せず、is_blocked_report() を経て blocked_report_unresolved が threshold 超で
    # P1 alert を出す。本 escalation path は本 fix で保持されるべき。
    scan "2026-05-15T00:25:00"
    [ "$status" -eq 0 ]
    run alerts_lines
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "ashigaru1 blocked_report_unresolved P1 open 1" ]
}

# ═══════════════════════════════════════════════════════════════
# extra: 直近 false-positive を再現する freeform verdict も suppress 対象
# ═══════════════════════════════════════════════════════════════

@test "review blind spot extra: freeform CMD_xxx_COMPLETE_... verdict is recognized as terminal and suppresses" {
    load_fixture review_verdict_freeform
    # 直近 ashigaru2:subtask_phase39b_w*_review_a2 alerts で観測された
    # 'CMD_001_COMPLETE_PHASE_39A2_FOUNDATION_FULL_LAND' verdict。
    # REVIEW_TERMINAL_PREFIXES の "cmd_" prefix で terminal と認識される。
    scan "2026-05-15T00:35:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    scan "2026-05-15T00:35:00" '{"ashigaru1":"idle"}'
    [ "$status" -eq 0 ]
    [ "$(count_alerts)" -eq 0 ]
}
