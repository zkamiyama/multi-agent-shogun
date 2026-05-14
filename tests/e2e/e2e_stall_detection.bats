#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E: stall 検知 daemon の supervisor 統合
#
# 検証:
#   1. watcher_supervisor.sh 起動 → stall_detector.sh process が現れる
#   2. 古い blocked report fixture を仕込むと、detector の scan が
#      Karo inbox (隔離 fixture root) に well-formed な type=stall_alert を書く
#   3. detector が exit すると supervisor が自動 restart する
#
# 隔離方針:
#   - scripts / lib / config / .venv を project-local の git-ignored fixture
#     root (tmp/stall_detector_tests/e2e.XXXX) にコピーし、supervisor をその
#     root から起動する。temp root を project tree 内に置くのは、teardown の
#     rm -rf を CLAUDE.md D002 (project tree 外への rm -rf 禁止) に抵触させない
#     ため。cleanup は safe_rm_test_root で project-bounded に限定する。
#   - PATH 先頭に stub を置く:
#       tmux  — 実 multiagent pane に触れない (pane は存在しない扱い)
#       pgrep — process 一致を $E2E_ROOT 配下に root-scope する。production の
#               stall_detector.sh が走っていても fixture-root supervisor が
#               それを「既に起動済」と誤認しないので、外部 daemon の有無に
#               関わらず e2e は deterministic。旧実装の `skip` guard
#               (CLAUDE.md SKIP=FAIL 違反) を不要にする。
#       sleep — global shutdown sentinel が現れたら非 0 で返り、supervisor 自身の
#               `set -e` に loop を畳ませる。`kill` を使わず supervisor を
#               cooperative に停止する (CLAUDE.md D006)。
#   - supervisor が起動する scripts/stall_detector.sh は cooperative wrapper
#     (tests/fixtures/stall_detector/e2e_detector_wrapper.sh)。daemon loop だけを
#     sentinel-exit 対応に差し替え、検知本体は production core (--once) に委譲する
#     ので、real detection → inbox_write → Karo inbox の path は実物が走る。
#   - wrapper から起動される core は SCRIPT_DIR=ROOT=$E2E_ROOT ゆえ IS_REAL_ROOT=1
#     となり、その root 配下の Karo inbox に実際に alert を書く。
#     detector は STALL_PANE_STATES_OVERRIDE 継承で tmux に触れない。
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"
load "../fixtures/stall_detector/safe_cleanup"

# ─── helpers ───

# _proc_alive <pid> — pid が生存しているか (/proc を見る。`kill -0` は使わない)
_proc_alive() {
    [ -n "${1:-}" ] && [ -e "/proc/$1" ]
}

# detector_pids — $E2E_ROOT を cwd に持つ stall_detector wrapper process の pid を列挙。
# test process 側ゆえ実 pgrep を使うが、cwd filter で root-scope 済 (production
# detector は cwd=PROJECT_ROOT ゆえ自然に除外される)。
detector_pids() {
    local pid cwd
    for pid in $(pgrep -f 'scripts/stall_detector.sh' 2>/dev/null || true); do
        cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
        [ "$cwd" = "$E2E_ROOT" ] && echo "$pid"
    done
    return 0
}

# wait_for_detector [timeout_sec] — E2E_ROOT 配下の detector が現れるまで待つ
wait_for_detector() {
    local timeout="${1:-25}"
    local elapsed=0 pids
    while [ "$elapsed" -lt "$timeout" ]; do
        pids="$(detector_pids)"
        [ -n "$pids" ] && { echo "$pids"; return 0; }
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# karo_has_stall_alert [agent] [kind] — fixture root の Karo inbox に、指定 agent /
# kind の well-formed な stall_alert (未読) が居るか。
# P2 finding 対策: from/type だけでなく agent・kind・severity・read flag まで assert
# する。低価値 alert (P2/P3 や malformed content) は受理しない。
karo_has_stall_alert() {
    local want_agent="${1:-ashigaru1}"
    local want_kind="${2:-blocked_report_unresolved}"
    python3 - "$E2E_ROOT/queue/inbox/karo.yaml" "$want_agent" "$want_kind" <<'PYEOF'
import re
import sys
try:
    import yaml
except Exception:
    sys.exit(2)
try:
    doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except FileNotFoundError:
    sys.exit(1)
want_agent, want_kind = sys.argv[2], sys.argv[3]
# core が書く content: "[<sev>] <kind> — <agent>[ (再通知#n)]: <evidence>"
pat = re.compile(r"^\[(P\d)\]\s+(\S+)\s+—\s+(\S+?)(?:\s+\(.*?\))?:\s")
for m in (doc.get("messages") or []):
    if not isinstance(m, dict):
        continue
    if m.get("from") != "stall_detector" or m.get("type") != "stall_alert":
        continue
    # inbox_write.sh は read: false で書く。配送前提 (未読で届いている) を assert。
    if m.get("read") is not False:
        continue
    hit = pat.match(str(m.get("content") or ""))
    if not hit:
        continue
    sev, kind, agent = hit.group(1), hit.group(2), hit.group(3)
    if agent != want_agent or kind != want_kind:
        continue
    # blocked_report_unresolved は threshold 超で P1、60m 超で P0。
    # P2/P3 (idle/assigned/informational) は弱い alert ゆえ受理しない。
    if sev not in ("P1", "P0"):
        continue
    print("%s %s %s read=%s" % (agent, kind, sev, m.get("read")))
    sys.exit(0)
sys.exit(1)
PYEOF
}

# ─── lifecycle ───

setup_file() {
    export PROJECT_ROOT FIXTURES E2E_ROOT SUPERVISOR_PID \
           DETECTOR_STOP_SENTINEL SHUTDOWN_SENTINEL
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    FIXTURES="$PROJECT_ROOT/tests/fixtures/stall_detector"

    # prereq は skip せず明示 fail させる (CLAUDE.md SKIP=FAIL mandate)。
    # setup_file の非 0 return は bats 上「全 test error」= 明示失敗であり skip ではない。
    if ! command -v python3 >/dev/null 2>&1; then
        echo "PREREQ FAIL: python3 not on PATH — required by stall_detector core" >&2
        return 1
    fi
    if ! python3 -c "import yaml" >/dev/null 2>&1; then
        echo "PREREQ FAIL: python3 yaml module missing — required by stall_detector core" >&2
        return 1
    fi

    # fixture root は project-local の git-ignored tree に置く (CLAUDE.md D002)。
    local root_base real_sleep
    root_base="$PROJECT_ROOT/tmp/stall_detector_tests"
    mkdir -p "$root_base"
    E2E_ROOT="$(mktemp -d "$root_base/e2e.XXXXXX")"
    E2E_ROOT="$(cd "$E2E_ROOT" && pwd -P)"
    mkdir -p "$E2E_ROOT/scripts" "$E2E_ROOT/lib" "$E2E_ROOT/config" "$E2E_ROOT/bin" \
             "$E2E_ROOT/queue/inbox" "$E2E_ROOT/queue/tasks" "$E2E_ROOT/queue/reports" \
             "$E2E_ROOT/queue/metrics" "$E2E_ROOT/logs"

    DETECTOR_STOP_SENTINEL="$E2E_ROOT/queue/.e2e_detector_stop"
    SHUTDOWN_SENTINEL="$E2E_ROOT/queue/.e2e_shutdown"

    # supervisor が起動する scripts/stall_detector.sh は cooperative wrapper。
    # 検知本体は production core を別名でコピーし wrapper が --once で委譲する。
    cp "$FIXTURES/e2e_detector_wrapper.sh"           "$E2E_ROOT/scripts/stall_detector.sh"
    cp "$PROJECT_ROOT/scripts/stall_detector.sh"     "$E2E_ROOT/scripts/_stall_detector_core.sh"
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

    # stub pgrep: process 一致を $E2E_ROOT 配下に root-scope する。
    # production stall_detector.sh が走っていても fixture-root supervisor が
    # 誤検知しない → 外部 process の有無に依存しない deterministic isolation。
    cat > "$E2E_ROOT/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
# e2e test stub for `pgrep` — root-scoped process matching.
# watcher_supervisor.sh が watcher / stall_detector の dedupe に使う system-wide
# `pgrep -f` を、cwd が $E2E_ROOT 配下の process だけに限定する。これにより
# fixture-root supervisor は production daemon から完全に隔離され、e2e は
# 外部 daemon の有無に関わらず deterministic になる (旧実装の skip guard 不要)。
set -u
pattern=""
for arg in "$@"; do
    case "$arg" in
        -*) ;;
        *)  pattern="$arg" ;;
    esac
done
root="${E2E_ROOT:-/nonexistent/e2e/root}"
found=1
for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    cmdline="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
    cmdline="${cmdline% }"
    [ -n "$cmdline" ] || continue
    printf '%s\n' "$cmdline" | grep -Eq -- "$pattern" || continue
    cwd="$(readlink -f "$d/cwd" 2>/dev/null || true)"
    case "$cwd" in
        "$root"|"$root"/*)
            printf '%s\n' "${d#/proc/}"
            found=0
            ;;
    esac
done
exit "$found"
STUB

    # stub sleep: global shutdown sentinel が現れたら非 0 で返る。supervisor の
    # loop 末尾は guard 無しの `sleep 5` ゆえ、supervisor 自身の `set -e` が loop を
    # 畳む = signal も `kill` も使わない cooperative 停止 (CLAUDE.md D006)。
    # sentinel が無い間は real sleep への透過 passthrough なので timing は不変。
    cat > "$E2E_ROOT/bin/sleep" <<'STUB'
#!/usr/bin/env bash
# e2e test stub for `sleep` — cooperative shutdown hook.
if [ -n "${STALL_E2E_SHUTDOWN:-}" ] && [ -e "$STALL_E2E_SHUTDOWN" ]; then
    exit 1
fi
exec "${STALL_E2E_REAL_SLEEP:-/usr/bin/sleep}" "$@"
STUB

    chmod +x "$E2E_ROOT/bin/tmux" "$E2E_ROOT/bin/pgrep" "$E2E_ROOT/bin/sleep"

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

    real_sleep="$(command -v sleep)"

    # supervisor 起動: stub を PATH 先頭に、detector は pane states override 継承で
    # tmux 非依存に。sentinel path / real sleep / interval を env で wrapper・stub に渡す。
    PATH="$E2E_ROOT/bin:$PATH" \
    STALL_PANE_STATES_OVERRIDE='{}' \
    STALL_E2E_DETECTOR_STOP="$DETECTOR_STOP_SENTINEL" \
    STALL_E2E_SHUTDOWN="$SHUTDOWN_SENTINEL" \
    STALL_E2E_REAL_SLEEP="$real_sleep" \
    STALL_E2E_INTERVAL_SEC=2 \
        nohup bash "$E2E_ROOT/scripts/watcher_supervisor.sh" \
        >> "$E2E_ROOT/logs/supervisor.log" 2>&1 &
    SUPERVISOR_PID=$!
}

teardown_file() {
    # ── cooperative shutdown — NO `kill`, NO signals (CLAUDE.md D006) ──
    # SHUTDOWN sentinel: stub 化された `sleep` が非 0 を返し supervisor 自身の
    # `set -e` が loop を畳む。DETECTOR_STOP sentinel: wrapper の _should_stop が
    # 次周期で自然 exit する。両者を立ててから自力終了を待つ。
    [ -n "${SHUTDOWN_SENTINEL:-}" ] && : > "$SHUTDOWN_SENTINEL"
    [ -n "${DETECTOR_STOP_SENTINEL:-}" ] && : > "$DETECTOR_STOP_SENTINEL"

    # supervisor と fixture-root detector が自力で終わるのを待つ
    # (/proc を見る — `kill -0` は使わない)。
    local elapsed=0 alive
    while [ "$elapsed" -lt 25 ]; do
        alive=0
        if [ -n "${SUPERVISOR_PID:-}" ] && _proc_alive "$SUPERVISOR_PID"; then
            alive=1
        fi
        if [ -n "$(detector_pids 2>/dev/null)" ]; then
            alive=1
        fi
        [ "$alive" -eq 0 ] && break
        sleep 1
        elapsed=$((elapsed + 1))
    done

    # project-bounded cleanup: rm -rf は tmp/stall_detector_tests/ 配下に限定
    # (CLAUDE.md D002)。E2E_ROOT が外に解決されたら safe_rm_test_root が拒否する。
    safe_rm_test_root "$PROJECT_ROOT" "${E2E_ROOT:-}"
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

@test "E2E-STALL-B: detector writes a well-formed stall_alert to Karo inbox for an old blocked report" {
    # detector wrapper は起動直後の周期で core --once を走らせる。Karo inbox を polling。
    local elapsed=0
    while [ "$elapsed" -lt 60 ]; do
        if karo_has_stall_alert ashigaru1 blocked_report_unresolved; then
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
    fail "Karo inbox did not receive a well-formed stall_alert (agent=ashigaru1 kind=blocked_report_unresolved sev=P1/P0 read=false) within 60s"
}

# ═══════════════════════════════════════════════════════════════
# E2E-STALL-C: detector が exit すると supervisor が restart する
# ═══════════════════════════════════════════════════════════════

@test "E2E-STALL-C: supervisor restarts stall_detector after it exits cooperatively" {
    local before after elapsed
    before="$(detector_pids | head -1)"
    [ -n "$before" ]

    # cooperative stop — sentinel file。`kill` は使わない (CLAUDE.md D006)。
    # wrapper の _should_stop が次周期でこれを見て自然 exit する。
    : > "$DETECTOR_STOP_SENTINEL"

    # `before` が実際に終わるのを待つ (/proc を見る — `kill -0` は使わない)。
    elapsed=0
    while _proc_alive "$before" && [ "$elapsed" -lt 15 ]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    # 協調 exit が効いて `before` が確かに死んだことを assert する。
    run _proc_alive "$before"
    assert_failure

    # sentinel を除去 → supervisor が次周期で「生きた」detector を起動できる。
    rm -f "$DETECTOR_STOP_SENTINEL"

    # before とは別の pid が現れ、かつ生存し続けることを確認する
    # (sentinel 残存中に supervisor が起こした短命 wrapper を取り違えないため、
    #  2 秒後も生きていることを確認してから success とする)。
    elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        after="$(detector_pids | head -1)"
        if [ -n "$after" ] && [ "$after" != "$before" ]; then
            sleep 2
            if _proc_alive "$after" && [ "$(detector_pids | head -1)" = "$after" ]; then
                return 0
            fi
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "--- supervisor.log ---" >&2
    cat "$E2E_ROOT/logs/supervisor.log" 2>/dev/null >&2 || true
    fail "stall_detector was not restarted by supervisor (before=$before after=${after:-none})"
}
