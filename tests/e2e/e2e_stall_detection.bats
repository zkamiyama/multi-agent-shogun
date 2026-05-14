#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E: stall 検知 daemon の supervisor 統合
#
# 検証:
#   1. watcher_supervisor.sh 起動 → stall_detector.sh process が現れる
#   2. 古い blocked report fixture を仕込むと、detector の scan が
#      Karo inbox (隔離 fixture root) に type=stall_alert を書く
#   3. detector を kill → supervisor が自動 restart する
#
# 隔離方針: scripts / lib / config / .venv を tmp fixture root にコピーし、
#   supervisor を그 root から起動する。stub tmux を PATH 先頭に置くことで
#   supervisor は実 multiagent pane に対し watcher を起こさない。
#   detector は STALL_PANE_STATES_OVERRIDE 継承で tmux に触れない。
#   fixture root から起動した detector は IS_REAL_ROOT=1 となり、
#   その root 配下の Karo inbox に実際に alert を書く。
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

# ─── helpers ───

# detector_pids — E2E_ROOT を cwd に持つ stall_detector process の pid を列挙
detector_pids() {
    local pid cwd
    for pid in $(pgrep -f 'scripts/stall_detector.sh' 2>/dev/null); do
        cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
        [ "$cwd" = "$E2E_ROOT" ] && echo "$pid"
    done
}

# wait_for_detector [timeout_sec] — E2E_ROOT 配下の detector が現れるまで待つ
wait_for_detector() {
    local timeout="${1:-25}" elapsed=0 pids
    while [ "$elapsed" -lt "$timeout" ]; do
        pids="$(detector_pids)"
        [ -n "$pids" ] && { echo "$pids"; return 0; }
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# karo_has_stall_alert — fixture root の Karo inbox に stall_detector 発の stall_alert があるか
karo_has_stall_alert() {
    python3 - "$E2E_ROOT/queue/inbox/karo.yaml" <<'PYEOF'
import sys, yaml
try:
    doc = yaml.safe_load(open(sys.argv[1])) or {}
except FileNotFoundError:
    sys.exit(1)
msgs = doc.get("messages") or []
ok = any(m.get("from") == "stall_detector" and m.get("type") == "stall_alert"
         for m in msgs if isinstance(m, dict))
sys.exit(0 if ok else 1)
PYEOF
}

# ─── lifecycle ───

setup_file() {
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -c "import yaml" 2>/dev/null || skip "python3-yaml not available"

    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    # 隔離前提: 外部の stall_detector が既に走っていると supervisor の
    # global pgrep dedupe により test 用 detector が起動しない。
    if pgrep -f "scripts/stall_detector.sh$" >/dev/null 2>&1; then
        skip "an external stall_detector.sh is already running — cannot isolate this e2e"
    fi

    export E2E_ROOT
    E2E_ROOT="$(mktemp -d /tmp/e2e_stall_XXXXXX)"
    E2E_ROOT="$(cd "$E2E_ROOT" && pwd -P)"
    mkdir -p "$E2E_ROOT/scripts" "$E2E_ROOT/lib" "$E2E_ROOT/config" "$E2E_ROOT/bin" \
             "$E2E_ROOT/queue/inbox" "$E2E_ROOT/queue/tasks" "$E2E_ROOT/queue/reports" \
             "$E2E_ROOT/queue/metrics" "$E2E_ROOT/logs"

    cp "$PROJECT_ROOT/scripts/stall_detector.sh"     "$E2E_ROOT/scripts/"
    cp "$PROJECT_ROOT/scripts/watcher_supervisor.sh" "$E2E_ROOT/scripts/"
    cp "$PROJECT_ROOT/scripts/inbox_write.sh"        "$E2E_ROOT/scripts/"
    cp "$PROJECT_ROOT/scripts/inbox_watcher.sh"      "$E2E_ROOT/scripts/"
    cp "$PROJECT_ROOT/lib/agent_status.sh"           "$E2E_ROOT/lib/" 2>/dev/null || true
    cp "$PROJECT_ROOT/lib/cli_adapter.sh"            "$E2E_ROOT/lib/" 2>/dev/null || true
    cp "$PROJECT_ROOT/config/settings.yaml"          "$E2E_ROOT/config/" 2>/dev/null || true

    # .venv: inbox_write.sh / stall_detector.sh は $SCRIPT_DIR/.venv/bin/python3 を使う
    if [ -x "$PROJECT_ROOT/.venv/bin/python3" ]; then
        ln -sf "$PROJECT_ROOT/.venv" "$E2E_ROOT/.venv"
    else
        mkdir -p "$E2E_ROOT/.venv/bin"
        ln -sf "$(command -v python3)" "$E2E_ROOT/.venv/bin/python3"
    fi

    # stub tmux: list-panes は空 → supervisor の pane_exists が常に false →
    # 実 multiagent pane に対する watcher 起動を防ぐ
    cat > "$E2E_ROOT/bin/tmux" <<'STUB'
#!/usr/bin/env bash
# e2e test stub: 実 tmux server には触れない。pane は存在しない扱い。
case "${1:-}" in
  list-panes) exit 0 ;;
  *) exit 0 ;;
esac
STUB
    chmod +x "$E2E_ROOT/bin/tmux"

    local a
    for a in shogun karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 gunshi; do
        printf 'messages: []\n' > "$E2E_ROOT/queue/inbox/${a}.yaml"
    done

    # 古い blocked report fixture (実時間相対 — supervisor 経由の detector は実 now を使う)
    local task_ts report_ts
    task_ts="$(date -d '120 minutes ago' '+%Y-%m-%dT%H:%M:%S')"
    report_ts="$(date -d '25 minutes ago' '+%Y-%m-%dT%H:%M:%S')"
    cat > "$E2E_ROOT/queue/tasks/ashigaru1.yaml" <<EOF
task:
  task_id: e2e_stall_blocked
  type: infra_implementation
  status: assigned
  worktree: null
  timestamp: "$task_ts"
EOF
    cat > "$E2E_ROOT/queue/reports/ashigaru1_report.yaml" <<EOF
report:
  - task_id: e2e_stall_blocked
    status: blocked
    timestamp: "$report_ts"
    summary: "e2e fixture — blocked awaiting decision"
EOF

    # supervisor 起動: stub tmux を PATH 先頭に、detector は pane states override 継承で
    # tmux 非依存に
    export SUPERVISOR_PID
    PATH="$E2E_ROOT/bin:$PATH" STALL_PANE_STATES_OVERRIDE='{}' \
        nohup bash "$E2E_ROOT/scripts/watcher_supervisor.sh" \
        >> "$E2E_ROOT/logs/supervisor.log" 2>&1 &
    SUPERVISOR_PID=$!
}

teardown_file() {
    # supervisor を先に止めてから (再 spawn を防ぐ) detector を止める
    if [ -n "${SUPERVISOR_PID:-}" ]; then
        kill "$SUPERVISOR_PID" 2>/dev/null || true
    fi
    sleep 1
    if [ -n "${E2E_ROOT:-}" ]; then
        local pid cwd
        for pid in $(pgrep -f 'scripts/stall_detector.sh' 2>/dev/null); do
            cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
            [ "$cwd" = "$E2E_ROOT" ] && kill "$pid" 2>/dev/null || true
        done
        # stub tmux が効かなかった場合の保険: fixture root の inbox_watcher も止める
        for pid in $(pgrep -f 'scripts/inbox_watcher.sh' 2>/dev/null); do
            cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
            [ "$cwd" = "$E2E_ROOT" ] && kill "$pid" 2>/dev/null || true
        done
        sleep 1
        rm -rf "$E2E_ROOT"
    fi
}

# ═══════════════════════════════════════════════════════════════
# E2E-STALL-A: supervisor が stall_detector を起動する
# ═══════════════════════════════════════════════════════════════

@test "E2E-STALL-A: watcher_supervisor starts stall_detector as a process" {
    run wait_for_detector 25
    assert_success
    [ -n "$output" ]
}

# ═══════════════════════════════════════════════════════════════
# E2E-STALL-B: detector が古い blocked report を Karo inbox に alert する
# ═══════════════════════════════════════════════════════════════

@test "E2E-STALL-B: detector writes a stall_alert to Karo inbox for an old blocked report" {
    # detector daemon は起動直後に 1 回目の scan を走らせる。Karo inbox を polling。
    local elapsed=0
    while [ "$elapsed" -lt 60 ]; do
        if karo_has_stall_alert; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "--- supervisor.log ---" >&2
    cat "$E2E_ROOT/logs/supervisor.log" 2>/dev/null >&2 || true
    echo "--- stall_detector.log ---" >&2
    cat "$E2E_ROOT/logs/stall_detector.log" 2>/dev/null >&2 || true
    echo "--- karo inbox ---" >&2
    cat "$E2E_ROOT/queue/inbox/karo.yaml" 2>/dev/null >&2 || true
    fail "Karo inbox did not receive a stall_alert within 60s"
}

# ═══════════════════════════════════════════════════════════════
# E2E-STALL-C: detector を kill すると supervisor が restart する
# ═══════════════════════════════════════════════════════════════

@test "E2E-STALL-C: supervisor restarts stall_detector after it is killed" {
    local before after elapsed
    before="$(detector_pids | head -1)"
    [ -n "$before" ]

    kill "$before" 2>/dev/null || true
    # 実際に死ぬのを待つ
    elapsed=0
    while kill -0 "$before" 2>/dev/null && [ "$elapsed" -lt 10 ]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    # supervisor loop は 5s 周期。新 pid (≠ before) が現れるのを待つ
    elapsed=0
    while [ "$elapsed" -lt 25 ]; do
        after="$(detector_pids | head -1)"
        if [ -n "$after" ] && [ "$after" != "$before" ]; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    fail "stall_detector was not restarted by supervisor (before=$before after=${after:-none})"
}
