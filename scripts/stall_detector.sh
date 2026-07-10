#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# stall_detector.sh — 長時間 Stall 検知 core daemon (Phase 1 / v1)
#
# 殿直命「長時間Stallを仕組み化して防いで」への恒久対策。
# inbox delivery は inbox_watcher.sh が見るが、配送後の task/report が
# blocked のまま放置される事象は誰も見ていなかった (2026-05-14 a3 6h stall)。
# 本 daemon は 60 秒周期で queue/tasks・queue/reports・pane idle・inbox unread を
# 軽量スキャンし、重複抑止つきで Karo inbox へ stall_alert を送る。
#
# 設計 SSOT: gunshi_report.yaml id=gunshi_stall_detection_design_20260514_211827
#
# Usage:
#   bash scripts/stall_detector.sh           # 60 秒周期 daemon
#   bash scripts/stall_detector.sh --once    # 1 回 scan して終了 (test / verify 用)
#
# テスト用フック (Phase 2 bats が利用する interface):
#   STALL_ROOT=<dir>   全 queue/ パスをこの root 配下に切り替える (fixture 隔離)
#   STALL_NOW=<epoch>  「現在時刻」を固定する (閾値テスト用)
#   STALL_PANE_STATES_OVERRIDE=<json>  pane 状態を tmux 非依存で固定する
#       (例: '{"ashigaru1":"idle"}'。worktree progress fixture の idle streak 制御用)
#   STALL_ROOT が実 repo と異なる場合は Karo inbox への実通知を抑止し、
#   stall_alerts.yaml への append のみ行う (test 隔離)。
#
# v1 scope 外 (Phase 2):
#   - watcher_supervisor.sh 統合による自動起動    (ashigaru6)
#   - bats unit/e2e tests                        (ashigaru5)
#   - CLAUDE.md / instructions 更新              (ashigaru4)
#   - ntfy / phone 通知 (殿裁可)。secondary escalation の hook point のみ構造化。
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── path root (テスト時は STALL_ROOT で差し替え) ──
ROOT="${STALL_ROOT:-$SCRIPT_DIR}"
ROOT="$(cd "$ROOT" && pwd)"

# 実 repo に対する scan か (= 本番通知してよいか) を判定する。
# STALL_ROOT が実 repo と一致する時のみ Karo inbox へ実通知する。
IS_REAL_ROOT=0
if [ "$ROOT" = "$SCRIPT_DIR" ]; then
    IS_REAL_ROOT=1
fi
# Test roots never notify a live agent.  This explicit opt-in permits Bats to
# exercise the otherwise real-root-only Gunshi2 task writer against its
# isolated fixture tree.
CAN_WRITE_GUNSHI2=0
if [ "$IS_REAL_ROOT" -eq 1 ] || [ "${STALL_TEST_ALLOW_GUNSHI2_WRITE:-0}" = "1" ]; then
    CAN_WRITE_GUNSHI2=1
fi

LOG_DIR="${ROOT}/logs"
LOG_FILE="${LOG_DIR}/stall_detector.log"
STATE_FILE="${ROOT}/queue/stall_detector_state.yaml"
ALERTS_FILE="${ROOT}/queue/stall_alerts.yaml"
mkdir -p "$LOG_DIR" "${ROOT}/queue"

# ── python 実体 (既存 script 作法に合わせ .venv を優先) ──
PYTHON="${SCRIPT_DIR}/.venv/bin/python3"
if [ ! -x "$PYTHON" ]; then
    PYTHON="python3"
fi

# ── 監視対象 agent → tmux pane (watcher_supervisor.sh と同じ割当) ──
# shogun は殿が操作する pane ゆえ stall 監視対象外。
AGENTS=(karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 gunshi gunshi2)
declare -A AGENT_PANE=(
    [karo]="multiagent:agents.0"
    [ashigaru1]="multiagent:agents.1"
    [ashigaru2]="multiagent:agents.2"
    [ashigaru3]="multiagent:agents.3"
    [ashigaru4]="multiagent:agents.4"
    [ashigaru5]="multiagent:agents.5"
    [ashigaru6]="multiagent:agents.6"
    [ashigaru7]="multiagent:agents.7"
    [gunshi]="multiagent:agents.8"
    [gunshi2]="multiagent:agents.9"
)

SCAN_INTERVAL_SEC="${STALL_SCAN_INTERVAL_SEC:-60}"

# ── logging ──
log() {
    local msg="$1"
    local line
    line="[$(date '+%Y-%m-%dT%H:%M:%S')] $msg"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    echo "$line" >&2
}

# ── graceful shutdown ──
RUNNING=1
shutdown() {
    RUNNING=0
    log "SIGTERM/SIGINT received — graceful shutdown"
    exit 0
}
trap shutdown SIGTERM SIGINT

# ─── pane idle/busy 判定 (lib/agent_status.sh を再利用) ───
# 軍師 infrastructure_findings 指摘どおり共有ライブラリの関数を使う。
# 重い tmux capture-pane は 1 agent 1 回のみ。daemon 自体を軽量に保つ。
_agent_status_lib="${SCRIPT_DIR}/lib/agent_status.sh"
if [ -f "$_agent_status_lib" ]; then
    # shellcheck source=lib/agent_status.sh
    source "$_agent_status_lib"
fi

resolve_agent_pane() {
    local agent="$1"
    if type mux_backend_name &>/dev/null && [ "$(mux_backend_name)" != "tmux" ]; then
        mux_find_pane_by_agent "$agent" 2>/dev/null || true
        return 0
    fi
    printf '%s\n' "${AGENT_PANE[$agent]:-}"
}

# compute_pane_states — 全 agent の pane 状態を JSON で stdout に出す。
# {"karo":"idle","ashigaru1":"busy",...}  state ∈ idle|busy|absent|unknown
compute_pane_states() {
    local json="{"
    local first=1
    local agent pane state rc
    for agent in "${AGENTS[@]}"; do
        pane="$(resolve_agent_pane "$agent")"
        state="unknown"
        if [ -z "$pane" ]; then
            state="absent"
        elif type agent_is_busy_check &>/dev/null; then
            set +e
            agent_is_busy_check "$pane"
            rc=$?
            set -e
            case "$rc" in
                0) state="busy" ;;
                1) state="idle" ;;
                2) state="absent" ;;
                *) state="unknown" ;;
            esac
        fi
        if [ "$first" -eq 1 ]; then first=0; else json+=","; fi
        json+="\"${agent}\":\"${state}\""
    done
    json+="}"
    echo "$json"
}

# ─── secondary escalation hook point (v1 = no-op stub) ───
# 殿裁可 (2026-05-14): v1 は Karo inbox alert のみ。ntfy / phone 通知は v1 では
# 一切実装しない。但し v2 で ntfy fallback を足せるよう、関数境界として hook point
# を構造化しておく。alert severity field は stall_alerts.yaml に既に持たせてある。
# v2 ではここで severity==P0 かつ Karo unresponsive な alert に対し scripts/ntfy.sh
# を呼ぶ。v1 では何もしない。
escalate_secondary() {
    local severity="$1"
    local summary="$2"
    : "$severity" "$summary"  # v1: 引数は v2 hook 用。現状は参照のみ。
    # v1: intentionally no-op (殿裁可で ntfy 送信コードは書かない)。
    # v2 hook: [ "$severity" = "P0" ] && bash scripts/ntfy.sh ... here.
    return 0
}

# ─── 1 回の scan ───
run_scan() {
    local pane_states
    # テスト用フック: STALL_PANE_STATES_OVERRIDE が設定されていれば tmux capture を
    # 行わず、その JSON をそのまま pane 状態として使う (fixture の idle streak 制御用)。
    if [ -n "${STALL_PANE_STATES_OVERRIDE:-}" ]; then
        pane_states="$STALL_PANE_STATES_OVERRIDE"
    else
        pane_states="$(compute_pane_states)"
    fi

    local now_override="${STALL_NOW:-}"

    # python が detection 本体。state/alerts file を更新し、
    # stdout に行指向で結果を返す:
    #   SUMMARY<TAB><scan 要約>
    #   NOTIFY<TAB><severity><TAB><karo へ送る要約>
    #   GUNSHI2<TAB><parent_cmd><TAB><severity><TAB><kind><TAB><agent><TAB><task_id><TAB><summary>
    #   WARN<TAB><parse warning 等>
    local scan_out
    set +e
    scan_out="$(
        STALL_ROOT="$ROOT" \
        STALL_PANE_STATES="$pane_states" \
        STALL_NOW="$now_override" \
        STALL_STATE_FILE="$STATE_FILE" \
        STALL_ALERTS_FILE="$ALERTS_FILE" \
        STALL_IS_REAL_ROOT="$IS_REAL_ROOT" \
        STALL_CAN_WRITE_GUNSHI2="$CAN_WRITE_GUNSHI2" \
        STALL_SCAN_INTERVAL_SEC="$SCAN_INTERVAL_SEC" \
        GUNSHI2_ROUNDTRIP_THRESHOLD="${GUNSHI2_ROUNDTRIP_THRESHOLD:-8}" \
        GUNSHI2_REDO_THRESHOLD="${GUNSHI2_REDO_THRESHOLD:-3}" \
        GUNSHI2_ESCALATION_COOLDOWN_MIN="${GUNSHI2_ESCALATION_COOLDOWN_MIN:-360}" \
        "$PYTHON" - <<'PYEOF'
import datetime
import json
import os
import re
import subprocess
import sys
import traceback

try:
    import yaml
except Exception as e:  # pragma: no cover
    print(f"WARN\tyaml import failed: {e}")
    print("SUMMARY\tscan aborted (no yaml module)")
    sys.exit(0)

ROOT = os.environ["STALL_ROOT"]
IS_REAL_ROOT = os.environ.get("STALL_IS_REAL_ROOT", "0") == "1"
CAN_WRITE_GUNSHI2 = os.environ.get("STALL_CAN_WRITE_GUNSHI2", "0") == "1"
STATE_FILE = os.environ["STALL_STATE_FILE"]
ALERTS_FILE = os.environ["STALL_ALERTS_FILE"]
SCAN_INTERVAL_SEC = int(os.environ.get("STALL_SCAN_INTERVAL_SEC", "60") or "60")
GUNSHI2_ROUNDTRIP_THRESHOLD = int(os.environ.get("GUNSHI2_ROUNDTRIP_THRESHOLD", "8") or "8")
GUNSHI2_REDO_THRESHOLD = int(os.environ.get("GUNSHI2_REDO_THRESHOLD", "3") or "3")
GUNSHI2_ESCALATION_COOLDOWN_MIN = int(os.environ.get("GUNSHI2_ESCALATION_COOLDOWN_MIN", "360") or "360")

try:
    PANE_STATES = json.loads(os.environ.get("STALL_PANE_STATES", "{}") or "{}")
except Exception:
    PANE_STATES = {}

LOCAL_TZ = datetime.datetime.now().astimezone().tzinfo
MIN_DT = datetime.datetime(1970, 1, 1, tzinfo=LOCAL_TZ)

_now_override = os.environ.get("STALL_NOW", "").strip()
if _now_override:
    NOW = datetime.datetime.fromtimestamp(int(_now_override), LOCAL_TZ)
else:
    NOW = datetime.datetime.now(LOCAL_TZ)

# ── thresholds (殿裁可 2026-05-14 = 軍師案そのまま) ──
BLOCKED_INITIAL_MIN = 15      # blocked_report: P1 after 15m
BLOCKED_P0_MIN = 60           # blocked_report: P0 after 60m
ASSIGNED_DEFAULT_MIN = 45     # assigned_no_progress: default
ASSIGNED_LONG_MIN = 90        # build/test/full_simulate/simulate/e2e
ASSIGNED_GUNSHI_MIN = 60      # gunshi L5/L6 analysis
ASSIGNED_P1_MIN = 120         # assigned_no_progress: P1 escalation
IDLE_ACTIVE_MIN = 30          # idle_with_active_task
UNREAD_IDLE_MIN = 15          # agent_unread_unprocessed: idle/unknown/absent
UNREAD_BUSY_MIN = 45          # agent_unread_unprocessed: busy pane は長めに見る
KARO_SECONDARY_MIN = 30       # karo_unresponsive_to_stall_alert
REPEAT_COOLDOWN_MIN = 30      # 再通知 cooldown (軍師: blocked 30m repeat cooldown)
BUSY_CEILING_MIN = 180        # pane busy でも 3h 超なら informational に downgrade

AGENTS = ["karo", "ashigaru1", "ashigaru2", "ashigaru3", "ashigaru4",
          "ashigaru5", "ashigaru6", "ashigaru7", "gunshi", "gunshi2"]
ASHIGARU = [a for a in AGENTS if a.startswith("ashigaru")]

# report status の正規化分類 (false_positive_controls #4: detector 内部分類のみ。
# task YAML に新 status 値は発明しない)。
TERMINAL_STATUSES = {
    "done", "complete", "completed", "cleared", "clear", "clear_for_qc",
    "conditional_clear", "cancelled", "canceled", "qc_pass", "qc_passed",
    "passed", "resolved",
}

# review/analysis task は read-only ゆえ task YAML status が assigned のまま report 側のみ
# 完了 verdict を書く慣例。verdict は freeform で "CLEAR" / "CMD_001_COMPLETE_PHASE_..." /
# "completed_pending_qc" 等 TERMINAL_STATUSES に literal 一致しないことが多く、結果
# idle_with_active_task / assigned_no_progress が false-positive で上がっていた (本 fix の
# 動機: 直近 review 系 task の alert 多発)。review/analysis task に限り、対応 task_id の
# report entry を canonical fingerprint として lookup し、より広い terminal 判定を適用する。
REVIEW_TASK_TYPES = {"review", "analysis"}
REVIEW_TERMINAL_PREFIXES = (
    "complete", "completed", "clear", "cleared", "conditional_clear",
    "done", "verdict", "pass", "passed", "qc_pass", "qc_passed", "resolved",
    "cmd_",
)
REVIEW_NON_TERMINAL_TOKENS = (
    "blocked", "in_progress", "redo", "fail", "not_clear", "needs_", "wip",
    "pending",
)

OUT = []
WARNINGS = []


def emit(kind, *parts):
    OUT.append(kind + "\t" + "\t".join(str(p) for p in parts))


def parse_ts(s):
    if s is None:
        return None
    s = str(s).strip().strip('"').strip("'")
    if not s:
        return None
    try:
        dt = datetime.datetime.fromisoformat(s)
    except ValueError:
        dt = None
        for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S",
                    "%Y-%m-%dT%H:%M", "%Y-%m-%d"):
            try:
                dt = datetime.datetime.strptime(s, fmt)
                break
            except ValueError:
                dt = None
        if dt is None:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=LOCAL_TZ)
    return dt


def iso(dt):
    return dt.astimezone(LOCAL_TZ).replace(microsecond=0).isoformat()


def minutes_since(dt):
    if dt is None:
        return None
    return (NOW - dt).total_seconds() / 60.0


def load_yaml_safe(path):
    """単一 doc の YAML を安全に読む。失敗時 None。"""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        return None
    except Exception as e:
        WARNINGS.append(f"parse failed {os.path.basename(path)}: {str(e).splitlines()[0]}")
        return None


def load_task(agent):
    """queue/tasks/<agent>.yaml の task mapping を返す。"""
    path = os.path.join(ROOT, "queue", "tasks", f"{agent}.yaml")
    data = load_yaml_safe(path)
    if not isinstance(data, dict):
        return None
    t = data.get("task", data)
    if not isinstance(t, dict):
        return None
    return t


def _report_entry_fields(entry, blocker_token=False):
    return {
        "status": str(entry.get("status") or "").strip().strip('"').strip("'"),
        "timestamp": entry.get("timestamp"),
        "task_id": entry.get("task_id"),
        "summary": str(entry.get("summary") or ""),
        "classification": str(entry.get("classification") or ""),
        "follow_up": entry.get("follow_up"),
        "_blocker_token": blocker_token,
    }


def load_report_latest(agent):
    """
    queue/reports/<agent>_report.yaml の「最新 entry」を robust に読む。
    report YAML は頻繁に malformed / multi-document ゆえ:
      1. yaml.safe_load_all で構造解析 (multi-doc 対応)。candidate を timestamp で最新化。
      2. 失敗時は indent<=2 の status/timestamp/task_id を regex で最後出現抽出 (fallback)。
    どちらも不能なら None (parse 失敗は WARN に出し、その entry は skip)。
    """
    path = os.path.join(ROOT, "queue", "reports", f"{agent}_report.yaml")
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return None
    except Exception as e:
        WARNINGS.append(f"read failed {agent}_report.yaml: {e}")
        return None

    # ── 1. 構造解析 ──
    try:
        docs = list(yaml.safe_load_all(text))
        candidates = []
        for d in docs:
            if isinstance(d, dict):
                r = d.get("report", d)
                if isinstance(r, list):
                    candidates.extend([x for x in r if isinstance(x, dict)])
                elif isinstance(r, dict):
                    candidates.append(r)
                # gunshi_report.yaml: top-level dict 自体も timestamp/status を持つ
                if r is not d and ("timestamp" in d or "status" in d):
                    candidates.append(d)
        if candidates:
            latest = max(candidates,
                         key=lambda c: parse_ts(c.get("timestamp")) or MIN_DT)
            return _report_entry_fields(latest)
    except Exception as e:
        WARNINGS.append(f"structured parse failed {agent}_report.yaml: "
                        f"{str(e).splitlines()[0]} — using regex fallback")

    # ── 2. regex fallback (indent 0-2 の report-level field のみ。
    #       nested の indent>=4 status: は拾わない) ──
    status = None
    ts = None
    task_id = None
    for line in text.splitlines():
        m = re.match(r"^ {0,2}status:\s*(.+?)\s*$", line)
        if m:
            status = m.group(1).strip().strip('"').strip("'")
        m = re.match(r"^ {0,2}timestamp:\s*(.+?)\s*$", line)
        if m:
            ts = m.group(1).strip().strip('"').strip("'")
        m = re.match(r"^ {0,2}task_id:\s*(.+?)\s*$", line)
        if m:
            task_id = m.group(1).strip().strip('"').strip("'")
    if status is None and ts is None:
        WARNINGS.append(f"unparseable report {agent}_report.yaml — skipped")
        return None
    has_blocker = "BLOCKER" in text
    has_follow_up = bool(re.search(r"^ {0,2}follow_up:\s*\S", text, re.M))
    return {
        "status": status or "",
        "timestamp": ts,
        "task_id": task_id,
        "summary": "",
        "classification": "",
        "follow_up": True if has_follow_up else None,
        "_blocker_token": has_blocker,
    }


def iter_report_entries_from_text(text):
    """report YAML text から timestamp/status/task_id を持つ entry 群を抽出する。"""
    entries = []
    try:
        docs = list(yaml.safe_load_all(text))
        for d in docs:
            if not isinstance(d, dict):
                continue
            r = d.get("report", d)
            if isinstance(r, list):
                entries.extend([x for x in r if isinstance(x, dict)])
            elif isinstance(r, dict):
                entries.append(r)
            if r is not d and ("timestamp" in d or "status" in d):
                entries.append(d)
    except Exception:
        status = None
        ts = None
        task_id = None
        for line in text.splitlines():
            m = re.match(r"^ {0,2}status:\s*(.+?)\s*$", line)
            if m:
                status = m.group(1).strip().strip('"').strip("'")
            m = re.match(r"^ {0,2}timestamp:\s*(.+?)\s*$", line)
            if m:
                ts = m.group(1).strip().strip('"').strip("'")
            m = re.match(r"^ {0,2}task_id:\s*(.+?)\s*$", line)
            if m:
                task_id = m.group(1).strip().strip('"').strip("'")
        if status is not None or ts is not None:
            entries.append({"status": status or "", "timestamp": ts, "task_id": task_id})
    return [e for e in entries if isinstance(e, dict)]


def latest_report_progress(agent):
    """agent prefix の report 群から最新 timestamp を返す。
    Karo/Gunshi は `<agent>_report.yaml` 以外の per-task report も使うため、
    queue/reports/<agent>_*.yaml まで見る。"""
    reports_dir = os.path.join(ROOT, "queue", "reports")
    try:
        names = os.listdir(reports_dir)
    except FileNotFoundError:
        return None
    latest = None
    latest_entry = None
    for name in names:
        if not name.endswith((".yaml", ".yml")):
            continue
        if name != f"{agent}_report.yaml" and not name.startswith(f"{agent}_"):
            continue
        path = os.path.join(reports_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except Exception:
            continue
        for entry in iter_report_entries_from_text(text):
            ts = parse_ts(entry.get("timestamp"))
            if ts is not None and (latest is None or ts > latest):
                latest = ts
                latest_entry = {
                    "file": name,
                    "status": str(entry.get("status") or ""),
                    "task_id": entry.get("task_id"),
                }
    if latest is None:
        return None
    latest_entry["timestamp"] = latest
    return latest_entry


def find_report_for_task(agent, task_id):
    """指定 task_id に対応する report entry (latest match) を全 entry から探す。
    review/analysis task は task YAML status が assigned のまま完了 report を出すゆえ、
    load_report_latest の「最新 entry」だけでは別 task の古い entry を見てしまう恐れがあり、
    task_id fingerprint で直接 lookup する必要がある (本 fix の (b) 方針)。
    見つからなければ None。"""
    if not task_id:
        return None
    path = os.path.join(ROOT, "queue", "reports", f"{agent}_report.yaml")
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return None
    except Exception as e:
        WARNINGS.append(f"read failed {agent}_report.yaml (find): {e}")
        return None
    try:
        docs = list(yaml.safe_load_all(text))
        matches = []
        for d in docs:
            if not isinstance(d, dict):
                continue
            r = d.get("report", d)
            if isinstance(r, list):
                matches.extend(
                    x for x in r
                    if isinstance(x, dict) and x.get("task_id") == task_id
                )
            elif isinstance(r, dict):
                if r.get("task_id") == task_id:
                    matches.append(r)
                if r is not d and d.get("task_id") == task_id:
                    matches.append(d)
        if matches:
            latest = max(
                matches,
                key=lambda c: parse_ts(c.get("timestamp")) or MIN_DT,
            )
            return _report_entry_fields(latest)
    except Exception as e:
        WARNINGS.append(
            f"find_report_for_task {agent}: {str(e).splitlines()[0]}"
        )
    return None


def inbox_unread_count(agent):
    path = os.path.join(ROOT, "queue", "inbox", f"{agent}.yaml")
    data = load_yaml_safe(path)
    if not isinstance(data, dict):
        return 0
    msgs = data.get("messages") or []
    if not isinstance(msgs, list):
        return 0
    return sum(1 for m in msgs if isinstance(m, dict) and not m.get("read", False))


def inbox_unread_messages(agent):
    path = os.path.join(ROOT, "queue", "inbox", f"{agent}.yaml")
    data = load_yaml_safe(path)
    if not isinstance(data, dict):
        return []
    msgs = data.get("messages") or []
    if not isinstance(msgs, list):
        return []
    return [m for m in msgs if isinstance(m, dict) and not m.get("read", False)]


def status_norm(s):
    return str(s or "").strip().strip('"').strip("'").lower()


def is_terminal_status(s):
    return status_norm(s) in TERMINAL_STATUSES


def is_review_terminal_status(s):
    """review/analysis task の verdict として『完了して次 dispatch 待ち』を意味する status か。
    TERMINAL_STATUSES より広い (freeform verdict 含む)。non-terminal token
    (blocked/in_progress/redo/pending/wip/fail/not_clear/needs_) を含めば必ず非 terminal。"""
    if not s:
        return False
    n = status_norm(s)
    if not n:
        return False
    if n in TERMINAL_STATUSES:
        return True
    if any(tok in n for tok in REVIEW_NON_TERMINAL_TOKENS):
        return False
    return any(n.startswith(p) for p in REVIEW_TERMINAL_PREFIXES)


def is_blocked_report(rep):
    """report が「未解決の blocked」状態を示すか (status 単独で判定しない)。"""
    if rep is None:
        return False
    s = status_norm(rep.get("status"))
    if s == "blocked":
        return True
    if s.startswith("in_progress_blocked") or s.startswith("blocked_"):
        return True
    if rep.get("follow_up"):
        return True
    if rep.get("_blocker_token"):
        return True
    blob = (rep.get("summary", "") + " " + rep.get("classification", ""))
    if "BLOCKER" in blob:
        return True
    return False


def task_type_threshold(agent, task):
    """assigned_no_progress の閾値 (分) を task type / bloom から決める。"""
    ttype = status_norm(task.get("type"))
    bloom = status_norm(task.get("bloom_level"))
    if agent.startswith("gunshi") and bloom in ("l5", "l6"):
        return ASSIGNED_GUNSHI_MIN
    if any(k in ttype for k in
           ("build", "test", "full_simulate", "simulate", "e2e")):
        return ASSIGNED_LONG_MIN
    return ASSIGNED_DEFAULT_MIN


# ─────────────────────────────────────────────────────────────
# worktree progress signature (false_positive_controls #3)
#   commit や file 編集はしているが report を出さない worker を stalled 扱いせぬよう、
#   task.worktree の進捗を「安価」に追跡する。
#   signature = git HEAD + bounded な最大 mtime。
#   - .git / build* / node_modules 等の重い・無関係 dir は prune
#   - worktree 直下の logs/ queue/ は detector 自身の書き込みで毎 scan 変化する
#     ため root レベルで prune (signature の自家中毒を防ぐ)
#   - file 走査は WT_WALK_FILE_CAP で上限を切り、巨大 repo でも軽量に保つ
#   - 同一 scan 内は worktree path で memoize (複数 agent が同 worktree を共有)
# ─────────────────────────────────────────────────────────────
WT_PRUNE_ANY = {
    ".git", ".hg", ".svn",
    "build", "build-linux", "build-debug", "build-release",
    "out", "bin", "obj", "dist", "target",
    "node_modules", ".venv", "venv",
    "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".cache",
    ".serena", ".idea", ".vscode",
}
WT_PRUNE_ROOT = {"logs", "queue"}
WT_WALK_FILE_CAP = 4000
_WT_SIG_CACHE = {}


def compute_worktree_signature(worktree):
    """task.worktree の安価な progress signature。git repo でなくても mtime で機能。
    取得不能 (path 無し / dir 不在) なら None。同一 scan 内は memoize。"""
    if worktree in (None, "", "null", "None"):
        return None
    wt = os.path.expanduser(str(worktree).strip().strip('"').strip("'"))
    if not wt or wt in ("null", "None"):
        return None
    try:
        wt = os.path.realpath(wt)
    except OSError:
        pass
    if wt in _WT_SIG_CACHE:
        return _WT_SIG_CACHE[wt]
    if not os.path.isdir(wt):
        _WT_SIG_CACHE[wt] = None
        return None
    # 1. HEAD (commit 進捗を捕捉。git repo でなければ空文字のまま)
    head = ""
    try:
        proc = subprocess.run(
            ["git", "-C", wt, "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        if proc.returncode == 0:
            head = proc.stdout.strip()
    except Exception:
        head = ""
    # 2. bounded 最大 mtime (file 編集進捗を捕捉)
    max_mtime = 0.0
    examined = 0
    try:
        for dirpath, dirnames, filenames in os.walk(wt, topdown=True):
            if dirpath == wt:
                dirnames[:] = [d for d in dirnames
                               if d not in WT_PRUNE_ANY and d not in WT_PRUNE_ROOT]
            else:
                dirnames[:] = [d for d in dirnames if d not in WT_PRUNE_ANY]
            try:
                m = os.stat(dirpath).st_mtime
                if m > max_mtime:
                    max_mtime = m
            except OSError:
                pass
            for fn in filenames:
                try:
                    m = os.lstat(os.path.join(dirpath, fn)).st_mtime
                    if m > max_mtime:
                        max_mtime = m
                except OSError:
                    pass
                examined += 1
                if examined >= WT_WALK_FILE_CAP:
                    break
            if examined >= WT_WALK_FILE_CAP:
                break
    except Exception:
        pass
    sig = "%s:%d" % (head, int(max_mtime))
    _WT_SIG_CACHE[wt] = sig
    return sig


# ─────────────────────────────────────────────────────────────
# state / alerts file の読み込み (冪等性 / 再起動耐性)
# ─────────────────────────────────────────────────────────────
state = load_yaml_safe(STATE_FILE)
if not isinstance(state, dict):
    state = {}
state.setdefault("pane_idle_streak", {})
state.setdefault("scan_count", 0)
state.setdefault("worktree_progress", {})
state.setdefault("gunshi2_escalations", {})
state.setdefault("gunshi2_capacity_notices", {})
state.setdefault("rca_parent_cooldowns", {})
state.setdefault("rca_elapsed", {})
if not isinstance(state.get("pane_idle_streak"), dict):
    state["pane_idle_streak"] = {}
if not isinstance(state.get("worktree_progress"), dict):
    state["worktree_progress"] = {}
if not isinstance(state.get("gunshi2_escalations"), dict):
    state["gunshi2_escalations"] = {}
if not isinstance(state.get("gunshi2_capacity_notices"), dict):
    state["gunshi2_capacity_notices"] = {}
if not isinstance(state.get("rca_parent_cooldowns"), dict):
    state["rca_parent_cooldowns"] = {}
if not isinstance(state.get("rca_elapsed"), dict):
    state["rca_elapsed"] = {}


def should_emit_gunshi2_capacity_notice(intent, severity):
    """Deduplicate capacity notices without discarding their pending intent.

    P0 is deliberately never delayed by a repeat cooldown.  P1/P2 notices are
    repeated only after the normal detector cooldown and leave an audit record
    in state so restarts do not re-notify every scan.
    """
    notices = state["gunshi2_capacity_notices"]
    notice = notices.get(intent)
    if not isinstance(notice, dict):
        notice = {}
    previous = parse_ts(notice.get("notified_at"))
    repeat_after = int(notice.get("repeat_after_min", REPEAT_COOLDOWN_MIN) or REPEAT_COOLDOWN_MIN)
    if severity != "P0" and previous is not None:
        age = (NOW - previous).total_seconds() / 60.0
        if age < repeat_after:
            return False
    notice.update({
        "notified_at": now_iso,
        "repeat_after_min": REPEAT_COOLDOWN_MIN,
        "severity": severity,
    })
    notices[intent] = notice
    return True

alerts_doc = load_yaml_safe(ALERTS_FILE)
if not isinstance(alerts_doc, dict):
    alerts_doc = {}
alerts = alerts_doc.get("alerts")
if not isinstance(alerts, list):
    alerts = []
# key -> alert dict (open/acked のみ実質追跡。resolved も履歴として残す)
alerts_by_key = {}
for a in alerts:
    if isinstance(a, dict) and a.get("key"):
        alerts_by_key[a["key"]] = a

# ── pane idle streak 更新 ──
for agent in AGENTS:
    pstate = PANE_STATES.get(agent, "unknown")
    streak = int(state["pane_idle_streak"].get(agent, 0) or 0)
    if pstate == "idle":
        streak += 1
    else:
        streak = 0
    state["pane_idle_streak"][agent] = streak


def pane_idle(agent):
    return PANE_STATES.get(agent, "unknown") == "idle"


def pane_busy(agent):
    return PANE_STATES.get(agent, "unknown") == "busy"


def idle_streak(agent):
    return int(state["pane_idle_streak"].get(agent, 0) or 0)


# ─────────────────────────────────────────────────────────────
# detection: 現時点で「stall している」alert candidate を全部算出する。
# 各 candidate は dedupe key を持つ。これと既存 alerts を突き合わせて
# new / update / auto-resolve を決める (recompute-from-scratch = 冪等)。
# ─────────────────────────────────────────────────────────────
now_iso = iso(NOW)
current = {}  # key -> candidate dict


def parent_cmd_from_blob(*values):
    for value in values:
        if value is None:
            continue
        m = re.search(r"\bcmd_[A-Za-z0-9_-]+\b", str(value))
        if m:
            return m.group(0)
    return None


def add_candidate(agent, task_id, kind, source_ts, severity, evidence, parent_cmd=None):
    key = f"{agent}:{task_id}:{kind}:{source_ts}"
    current[key] = {
        "key": key,
        "agent": agent,
        "task_id": task_id,
        "kind": kind,
        "severity": severity,
        "evidence": evidence,
        "parent_cmd": parent_cmd,
    }


RCA_TERMINAL_OUTCOMES = {"completed", "failed", "blocked", "cancelled"}


def iter_rca_events():
    """Read only explicit top-level rca_events records from report YAML files.

    The ordinary report parser deliberately remains unchanged: generic report status,
    blocked_by, and qc_updates must never stop an RCA family clock.
    """
    reports_dir = os.path.join(ROOT, "queue", "reports")
    try:
        names = os.listdir(reports_dir)
    except FileNotFoundError:
        return
    for name in names:
        if not name.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(reports_dir, name)
        doc = load_yaml_safe(path)
        if not isinstance(doc, dict):
            continue
        events = doc.get("rca_events")
        if not isinstance(events, list):
            continue
        for event in events:
            if isinstance(event, dict):
                yield event


def matching_rca_terminal(parent_cmd, family_id):
    for event in iter_rca_events():
        if (str(event.get("event") or "").strip().lower() != "outcome"
                or str(event.get("parent_cmd") or "") != parent_cmd
                or str(event.get("family_id") or "") != family_id):
            continue
        outcome = str(event.get("outcome") or "").strip().lower()
        if outcome in RCA_TERMINAL_OUTCOMES:
            return outcome, parse_ts(event.get("timestamp"))
    return None, None


def latest_task_progress(agent):
    task = load_task(agent)
    if not isinstance(task, dict):
        return None
    ts_candidates = []
    assigned_ts = parse_ts(task.get("timestamp"))
    if assigned_ts is not None:
        ts_candidates.append(("timestamp", assigned_ts))
    completed_ts = parse_ts(task.get("completed_at"))
    if completed_ts is not None:
        ts_candidates.append(("completed_at", completed_ts))
    if not ts_candidates:
        return None
    ts_field, ts = max(ts_candidates, key=lambda item: item[1])
    if ts is None:
        return None
    return {
        "timestamp": ts,
        "timestamp_field": ts_field,
        "task_id": task.get("task_id") or "unknown",
        "status": status_norm(task.get("status")),
    }


def latest_status_progress(agent):
    """軽量な status/progress file の mtime を progress signal として使う。"""
    candidates = [
        os.path.join(ROOT, "queue", "metrics", f"{agent}_selfwatch.yaml"),
        os.path.join(ROOT, "queue", "status", f"{agent}.yaml"),
    ]
    latest = None
    latest_path = None
    for path in candidates:
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        dt = datetime.datetime.fromtimestamp(mtime, LOCAL_TZ)
        if latest is None or dt > latest:
            latest = dt
            latest_path = os.path.relpath(path, ROOT)
    if latest is None:
        return None
    return {"timestamp": latest, "path": latest_path}


def progress_after_unread_message(agent, msg_ts):
    progress = []
    task_progress = latest_task_progress(agent)
    if task_progress is not None:
        progress.append(("task", task_progress))
    report_progress = latest_report_progress(agent)
    if report_progress is not None:
        progress.append(("report", report_progress))
    status_progress = latest_status_progress(agent)
    if status_progress is not None:
        progress.append(("status", status_progress))

    latest_kind = None
    latest_item = None
    for kind, item in progress:
        ts = item.get("timestamp")
        if ts is None:
            continue
        if latest_item is None or ts > latest_item.get("timestamp"):
            latest_kind = kind
            latest_item = item
    progressed = (
        msg_ts is not None
        and latest_item is not None
        and latest_item.get("timestamp") is not None
        and latest_item["timestamp"] > msg_ts
    )
    return progressed, latest_kind, latest_item


for agent in AGENTS:
    unread_msgs = inbox_unread_messages(agent)
    if not unread_msgs:
        continue
    oldest = min(unread_msgs, key=lambda m: parse_ts(m.get("timestamp")) or MIN_DT)
    msg_ts = parse_ts(oldest.get("timestamp"))
    if msg_ts is None:
        continue
    progressed, progress_kind, progress_item = progress_after_unread_message(agent, msg_ts)
    if progressed:
        continue
    age_min = minutes_since(msg_ts)
    if age_min is None:
        continue
    pstate = PANE_STATES.get(agent, "unknown")
    threshold = UNREAD_BUSY_MIN if pstate == "busy" else UNREAD_IDLE_MIN
    if age_min < threshold:
        continue
    severity = "P3" if pstate == "busy" else "P2"
    if agent == "karo" and pstate != "busy":
        severity = "P1"
    task_progress = latest_task_progress(agent)
    task_id = (task_progress or {}).get("task_id") or oldest.get("dedup_key") or oldest.get("id") or "unread"
    latest_desc = "none"
    if progress_item is not None:
        latest_desc = f"{progress_kind}@{iso(progress_item['timestamp'])}"
        if progress_kind == "report":
            latest_desc += f" file={progress_item.get('file')} status={progress_item.get('status')}"
        elif progress_kind == "task":
            latest_desc += (f" task={progress_item.get('task_id')} "
                            f"status={progress_item.get('status')} "
                            f"field={progress_item.get('timestamp_field')}")
        elif progress_kind == "status":
            latest_desc += f" path={progress_item.get('path')}"
    dedupe_meta = []
    for field in ("dedup_key", "retry_count", "first_notified_at", "last_notified_at"):
        if field in oldest:
            dedupe_meta.append(f"{field}={oldest.get(field)}")
    meta = ", ".join(dedupe_meta) if dedupe_meta else "none"
    ev = (f"inbox unread oldest message '{oldest.get('id', 'unknown')}' "
          f"type={oldest.get('type', 'unknown')} from={oldest.get('from', 'unknown')} "
          f"age={int(age_min)}m threshold={threshold}m unread_count={len(unread_msgs)}; "
          f"pane={pstate} idle_streak={idle_streak(agent)}; "
          f"no task/report/status progress after message timestamp {iso(msg_ts)} "
          f"(latest_progress={latest_desc}); dedupe_meta: {meta}。")
    add_candidate(agent, task_id, "agent_unread_unprocessed",
                  iso(msg_ts), severity, ev,
                  parent_cmd=parent_cmd_from_blob(
                      oldest.get("parent_cmd"), oldest.get("dedup_key"),
                      oldest.get("message"), oldest.get("id"), task_id, ev,
                  ))


for agent in ASHIGARU + [a for a in AGENTS if a.startswith("gunshi")]:
    task = load_task(agent)
    rep = load_report_latest(agent)
    task_status = status_norm(task.get("status")) if task else None
    task_id = (task.get("task_id") if task else None) or "unknown"
    task_ts = parse_ts(task.get("timestamp")) if task else None
    rep_status = status_norm(rep.get("status")) if rep else None
    rep_ts = parse_ts(rep.get("timestamp")) if rep else None

    # false_positive_controls #1: status idle + task_id null は絶対 alert しない
    if task and task_status == "idle" and (task.get("task_id") in (None, "null", "")):
        continue
    # false_positive_controls #2: blocked_by 持ち = 意図的 dependency hold
    if task and task.get("blocked_by") not in (None, "null", "", "None"):
        continue
    if task and task_status == "blocked":
        # task YAML status=blocked 自体は意図的 hold の可能性。blocked_by 無しでも
        # detector は task YAML status 単独で判定しない (#3)。report 側で見る。
        pass

    # ── kind: blocked_report_unresolved ──
    # ashigaru report の最新 entry が blocked-ish。対応 task が report より新しく
    # assigned/terminal に戻っていれば resolved (agent が次の task へ移った含む)。
    if agent in ASHIGARU and rep is not None and is_blocked_report(rep):
        resolved = False
        # 後続の done report (= 最新 report 自体が terminal) → resolved
        if is_terminal_status(rep_status):
            resolved = True
        # 対応 task YAML が report timestamp より新しい → 再 dispatch / 次 task 移行
        if task_ts is not None and rep_ts is not None and task_ts > rep_ts:
            if task_status in ("assigned", "done", "idle", "cancelled", "canceled"):
                resolved = True
        if not resolved:
            mins = minutes_since(rep_ts)
            if mins is not None and mins >= BLOCKED_INITIAL_MIN:
                sev = "P0" if mins >= BLOCKED_P0_MIN else "P1"
                src = iso(rep_ts) if rep_ts else "unknown"
                ev = (f"report status='{rep.get('status')}' が {int(mins)}m 未解決。"
                      f"task '{task_id}' status={task_status}。"
                      f"report 担当 task='{rep.get('task_id')}'。")
                add_candidate(agent, task_id, "blocked_report_unresolved",
                              src, sev, ev,
                              parent_cmd=parent_cmd_from_blob(
                                  task.get("parent_cmd") if task else None,
                                  rep.get("parent_cmd") if rep else None,
                                  task_id, rep.get("task_id") if rep else None, ev,
                              ))

    # assigned 系 (assigned_no_progress / idle_with_active_task) は
    # task status=assigned が前提。
    if not task or task_status != "assigned":
        continue

    # 「最新 report が done/CLEAR/conditional_clear」なら assigned 系は除外。
    latest_report_terminal = is_terminal_status(rep_status)
    # 「task timestamp 以後に report 更新あり」= progress 兆候。
    report_newer_than_task = (
        rep_ts is not None and task_ts is not None and rep_ts >= task_ts
    )

    # ── review/analysis task の completion blind spot 解消 ──
    # task YAML status が assigned のまま report 側だけ "CLEAR" / "CMD_xxx_COMPLETE_..." /
    # "completed_pending_qc" 等で完了報告されるケース。TERMINAL_STATUSES literal 一致しない
    # ため従来は assigned_no_progress / idle_with_active_task が false-positive で上がっていた。
    # task type が review/analysis なら canonical fingerprint = 該当 task_id の report entry の
    # status とし、is_review_terminal_status の広い判定で terminal を認識する。
    # sub-case 整理:
    #   1. review + report 完了 verdict   → terminal (suppress)
    #   2. review + report 不在            → 非 terminal (legitimate stall)
    #   3. impl/その他 type               → 不変 (regression なし)
    #   4. review + report in_progress    → 非 terminal (legitimate)
    #   5. review + report blocked        → blocked_report_unresolved path で escalation
    if (not latest_report_terminal
            and task is not None
            and status_norm(task.get("type")) in REVIEW_TASK_TYPES):
        review_rep = rep if (rep is not None
                             and rep.get("task_id") == task.get("task_id")) else None
        if review_rep is None:
            review_rep = find_report_for_task(agent, task.get("task_id"))
        if review_rep is not None and is_review_terminal_status(review_rep.get("status")):
            latest_report_terminal = True
            review_rep_ts = parse_ts(review_rep.get("timestamp"))
            if (review_rep_ts is not None and task_ts is not None
                    and review_rep_ts >= task_ts):
                report_newer_than_task = True
    unread = inbox_unread_count(agent)
    mins_assigned = minutes_since(task_ts)

    # ── worktree progress tracking (false_positive_controls #3) ──
    # commit や file 編集だけして report を出さない worker を stalled 扱いせぬよう、
    # task.worktree の HEAD+mtime signature を per-agent で persist し、signature が
    # 変化したら last_progress_at を現在時刻に更新する。assigned 系の経過時間判定は
    # task timestamp ではなく last_progress_at から測る。
    wt_progress = state["worktree_progress"]
    wt_path = task.get("worktree")
    wt_sig = compute_worktree_signature(wt_path)
    wp_entry = wt_progress.get(agent)
    if not isinstance(wp_entry, dict) or wp_entry.get("task_id") != task_id:
        # 新規 task → baseline は task timestamp (進捗履歴が無いので保守的)。
        baseline = iso(task_ts) if task_ts else now_iso
        wp_entry = {
            "task_id": task_id,
            "worktree": wt_path,
            "signature": wt_sig,
            "last_progress_at": baseline,
        }
        wt_progress[agent] = wp_entry
    else:
        if wt_sig is not None and wt_sig != wp_entry.get("signature"):
            wp_entry["signature"] = wt_sig
            wp_entry["last_progress_at"] = now_iso
        wp_entry["worktree"] = wt_path
    # report 更新も progress 信号: rep_ts が last_progress_at より新しければ採用。
    last_progress_at = parse_ts(wp_entry.get("last_progress_at")) or task_ts
    if rep_ts is not None and (last_progress_at is None or rep_ts > last_progress_at):
        last_progress_at = rep_ts
        wp_entry["last_progress_at"] = iso(rep_ts)
    mins_since_progress = minutes_since(last_progress_at)
    if mins_since_progress is None:
        mins_since_progress = mins_assigned

    # ── kind: assigned_no_progress ──
    # task assigned かつ task ts 以後 report 更新なし + worktree 進捗なし +
    # inbox unread 0 + pane idle 2 連続 → alert。最新 report terminal なら除外。
    # 経過時間は task timestamp ではなく last_progress_at (worktree/report 進捗) から測る。
    if (not latest_report_terminal
            and not report_newer_than_task
            and unread == 0
            and mins_since_progress is not None):
        threshold = task_type_threshold(agent, task)
        if pane_busy(agent):
            # false_positive_controls #6: pane busy = progress 扱い。
            # ただし 3h 超なら informational alert に downgrade。
            if mins_since_progress >= BUSY_CEILING_MIN:
                src = iso(task_ts) if task_ts else "unknown"
                ev = (f"task '{task_id}' assigned {int(mins_assigned or 0)}m。"
                      f"pane busy だが last_progress から {int(mins_since_progress)}m / "
                      f"{BUSY_CEILING_MIN}m ceiling 超過 — 進捗 (worktree/report) 不在ゆえ "
                      f"informational。")
                add_candidate(agent, task_id, "assigned_no_progress",
                              src, "P3", ev,
                              parent_cmd=parent_cmd_from_blob(
                                  task.get("parent_cmd"), task_id, ev,
                              ))
        elif idle_streak(agent) >= 2 and mins_since_progress >= threshold:
            sev = "P1" if mins_since_progress >= ASSIGNED_P1_MIN else "P2"
            src = iso(task_ts) if task_ts else "unknown"
            ev = (f"task '{task_id}' assigned {int(mins_assigned or 0)}m、"
                  f"last_progress から {int(mins_since_progress)}m 進捗なし "
                  f"(threshold {threshold}m、type={task.get('type')})。"
                  f"worktree HEAD/mtime 不変 / task ts 以後 report 更新なし / "
                  f"inbox unread 0 / pane idle {idle_streak(agent)} 連続。")
            add_candidate(agent, task_id, "assigned_no_progress",
                          src, sev, ev,
                          parent_cmd=parent_cmd_from_blob(
                              task.get("parent_cmd"), task_id, ev,
                          ))

    # ── kind: idle_with_active_task ──
    # pane idle + task assigned + latest report が terminal でない + worktree/report
    # 進捗なし + inbox unread 0 が連続 2 scan 以上 → alert。
    # assigned_no_progress (45m) より短い 30m で拾う補助信号。
    if (agent in ASHIGARU
            and not latest_report_terminal
            and not report_newer_than_task
            and unread == 0
            and idle_streak(agent) >= 2
            and mins_since_progress is not None
            and mins_since_progress >= IDLE_ACTIVE_MIN):
        src = iso(task_ts) if task_ts else "unknown"
        ev = (f"pane idle {idle_streak(agent)} 連続だが task '{task_id}' を抱えたまま "
              f"(assigned {int(mins_assigned or 0)}m、last_progress から "
              f"{int(mins_since_progress)}m)。worktree HEAD/mtime 不変、"
              f"task ts 以後 report 更新なし、latest report "
              f"status='{rep.get('status') if rep else 'none'}' (非 terminal)、"
              f"inbox unread 0。")
        add_candidate(agent, task_id, "idle_with_active_task", src, "P2", ev,
                      parent_cmd=parent_cmd_from_blob(
                          task.get("parent_cmd"), task_id, ev,
                      ))


# ── Explicit RCA elapsed clock ────────────────────────────────
# This pass intentionally does not look at pane state, worktree signatures, or
# ordinary report progress.  Those are useful for generic stalls but would let
# a busy investigation postpone its promised RCA escalation forever.
for agent in ASHIGARU + [a for a in AGENTS if a.startswith("gunshi")]:
    task = load_task(agent)
    if not isinstance(task, dict) or status_norm(task.get("status")) != "assigned":
        continue
    tracking = task.get("rca_tracking")
    if not isinstance(tracking, dict) or tracking.get("enabled") is not True:
        continue
    parent = task.get("parent_cmd")
    family = tracking.get("family_id")
    started = parse_ts(tracking.get("started_at"))
    # Schema is deliberately fail-closed.  A malformed opt-in never becomes a
    # surprise escalation, and legacy tasks with no marker remain untouched.
    if (not isinstance(parent, str) or not parent.strip()
            or not isinstance(family, str) or not family.strip()
            or started is None):
        WARNINGS.append(f"RCA marker invalid for {agent}:{task.get('task_id')}")
        continue
    parent = parent.strip()
    family = family.strip()
    key = f"{parent}|{family}"
    entry = state["rca_elapsed"].get(key)
    if not isinstance(entry, dict):
        entry = {}
    prior_started = parse_ts(entry.get("started_at"))
    # started_at is immutable across redos: preserve the earliest observed
    # timestamp even if a later task accidentally tries to reset it.
    effective_started = min([d for d in (started, prior_started) if d is not None])
    entry.update({
        "parent_cmd": parent,
        "family_id": family,
        "started_at": iso(effective_started),
        "source_agent": agent,
        "source_task_id": task.get("task_id"),
    })
    entry.setdefault("checkpoint", {"state": "pending", "notified_at": None})
    entry.setdefault("escalation", {"state": "pending", "due_at": None,
                                      "dispatched_at": None, "gunshi2_task_id": None})
    if not isinstance(entry["checkpoint"], dict): entry["checkpoint"] = {"state": "pending", "notified_at": None}
    if not isinstance(entry["escalation"], dict): entry["escalation"] = {"state": "pending", "due_at": None, "dispatched_at": None, "gunshi2_task_id": None}
    state["rca_elapsed"][key] = entry

    terminal, terminal_ts = matching_rca_terminal(parent, family)
    if terminal:
        entry["terminal"] = {"outcome": terminal, "timestamp": iso(terminal_ts) if terminal_ts else None}
        entry["escalation"]["state"] = "suppressed_terminal"
        continue
    elapsed = minutes_since(effective_started)
    if elapsed is None or elapsed < 0:
        continue
    # Explicitly reject floats, negative values, and reversed clocks.  Do not
    # coerce with int(): int(60.5) silently changes the promised deadline.
    checkpoint_after = tracking.get("checkpoint_after_min", 60)
    escalate_after = tracking.get("escalate_after_min", 120)
    valid_thresholds = (
        type(checkpoint_after) is int and type(escalate_after) is int
        and checkpoint_after >= 0 and escalate_after >= 0
        and checkpoint_after <= escalate_after
    )
    if not valid_thresholds:
        entry["threshold_validation"] = {
            "state": "invalid_fail_closed",
            "checkpoint_after_min": checkpoint_after,
            "escalate_after_min": escalate_after,
            "detected_at": now_iso,
        }
        entry["checkpoint"]["state"] = "suppressed_invalid_threshold"
        entry["escalation"]["state"] = "suppressed_invalid_threshold"
        WARNINGS.append(
            f"RCA threshold invalid for {agent}:{task.get('task_id')} "
            f"family={family}: checkpoint_after_min={checkpoint_after!r}, "
            f"escalate_after_min={escalate_after!r} (fail-closed)"
        )
        continue
    if elapsed >= checkpoint_after and entry["checkpoint"].get("state") == "pending":
        entry["checkpoint"] = {"state": "notified", "notified_at": now_iso}
        emit("NOTIFY", "P3", (f"[P3] rca_checkpoint_due — {agent}:{task.get('task_id')} "
                                f"family={family} parent_cmd={parent}; elapsed={int(elapsed)}m。"))
    if elapsed < escalate_after:
        continue
    esc = entry["escalation"]
    if esc.get("state") in ("dispatched", "intent_emitted", "suppressed_terminal"):
        continue
    esc["due_at"] = esc.get("due_at") or now_iso
    # Both generic and RCA dispatches impose a parent-level cooldown.  Keep a
    # different RCA family pending until it expires; a terminal result above
    # always wins, and P0 deliberately bypasses this suppression.
    rca_severity = tracking.get("escalation_severity", "P1")
    if rca_severity not in ("P0", "P1"):
        rca_severity = "P1"
    cooldowns = []
    generic_notice = state["gunshi2_escalations"].get(parent)
    generic_last = parse_ts(generic_notice.get("last_notified")) if isinstance(generic_notice, dict) else None
    if generic_last is not None:
        cooldowns.append((generic_last + datetime.timedelta(minutes=GUNSHI2_ESCALATION_COOLDOWN_MIN),
                          generic_last, "generic_parent_cooldown", generic_notice))
    rca_notice = state["rca_parent_cooldowns"].get(parent)
    if isinstance(rca_notice, dict):
        rca_expires = parse_ts(rca_notice.get("expires_at"))
        rca_dispatched = parse_ts(rca_notice.get("dispatched_at"))
        if rca_expires is not None and rca_expires > NOW:
            cooldowns.append((rca_expires, rca_dispatched, "rca_parent_cooldown", rca_notice))
    active_cooldowns = [item for item in cooldowns if item[0] > NOW]
    if rca_severity != "P0" and active_cooldowns:
        expires_at, dispatched_at, reason, record = max(active_cooldowns, key=lambda item: item[0])
        esc["state"] = "pending_parent_cooldown"
        esc["parent_cooldown"] = {
            "dispatched_at": iso(dispatched_at) if dispatched_at else None,
            "expires_at": iso(expires_at),
            "reason": reason,
            "family_id": record.get("family_id") if isinstance(record, dict) else None,
        }
        continue
    # A different assigned Gunshi2 task is capacity, not permission to replace
    # it.  Keep the intent in detector state for a later scan.
    g2_task = load_task("gunshi2")
    if (isinstance(g2_task, dict) and status_norm(g2_task.get("status")) == "assigned"
            and (str(g2_task.get("parent_cmd") or "") != parent
                 or str((g2_task.get("rca_context") or {}).get("family_id") or "") != family)):
        esc["state"] = "pending_gunshi2_slot"
        if should_emit_gunshi2_capacity_notice(f"rca:{parent}:{family}", rca_severity):
            esc["notified_at"] = now_iso
            esc["repeat_after_min"] = REPEAT_COOLDOWN_MIN
            emit("NOTIFY", rca_severity, (f"[{rca_severity}] rca_gunshi2_capacity — family={family} parent_cmd={parent} "
                                    f"is due after {int(elapsed)}m; Gunshi2 slot is assigned to another case。"))
        continue
    # Test roots record emitted intent for deterministic no-duplicate tests.
    # A real root remains due until the outer writer has atomically installed
    # the Gunshi2 task and then marks this entry dispatched.
    esc["state"] = "due" if CAN_WRITE_GUNSHI2 else "intent_emitted"
    summary = (f"RCA elapsed {int(elapsed)}m; family={family}; started_at={iso(effective_started)}; "
               f"source={agent}:{task.get('task_id')}. Separate facts from hypotheses and propose up to three safe probes.")
    emit("GUNSHI2", parent, rca_severity, "rca_elapsed_120m", agent,
         task.get("task_id") or "unknown", summary)


# false_positive_controls #5: Karo には agent ごとに 1 actionable alert を出す。
# 同一 agent に複数 kind が立った場合 (例: blocked report を抱えたまま unread)、
# severity を最優先し、同 severity なら kind priority で 1 件に絞る。
CANDIDATE_SEV_RANK = {"P3": 0, "P2": 1, "P1": 2, "P0": 3}
PRIMARY_KINDS = ("agent_unread_unprocessed", "blocked_report_unresolved",
                 "assigned_no_progress", "idle_with_active_task")
KIND_PRIORITY = {
    "blocked_report_unresolved": 4,
    "agent_unread_unprocessed": 3,
    "assigned_no_progress": 2,
    "idle_with_active_task": 1,
}
_best_by_agent = {}
for _key, _cand in current.items():
    _agent = _cand["agent"]
    _prio = (
        CANDIDATE_SEV_RANK.get(_cand["severity"], 0),
        KIND_PRIORITY.get(_cand["kind"], 0),
    )
    if _agent not in _best_by_agent or _prio > _best_by_agent[_agent][0]:
        _best_by_agent[_agent] = (_prio, _key)
_keep_keys = {k for _, k in _best_by_agent.values()}
current = {k: v for k, v in current.items() if k in _keep_keys}


def iter_yaml_files(*parts):
    base = os.path.join(ROOT, *parts)
    try:
        names = os.listdir(base)
    except FileNotFoundError:
        return
    for name in names:
        if name.endswith((".yaml", ".yml")):
            yield os.path.join(base, name)


def extract_cmds(value):
    if value is None:
        return []
    return re.findall(r"\bcmd_[A-Za-z0-9_-]+\b", str(value))


def collect_recent_parent_cmd_metrics():
    """24h内のinbox/report/task痕跡から parent_cmd のやり取り量を概算する。"""
    cutoff = NOW - datetime.timedelta(hours=24)
    metrics = {}

    def ensure(cmd):
        metrics.setdefault(cmd, {"interactions": 0, "redos": 0, "sources": []})
        return metrics[cmd]

    def count_blob(blob, ts=None, source="unknown"):
        if ts is not None and ts < cutoff:
            return
        cmds = extract_cmds(blob)
        if not cmds:
            return
        blob_s = str(blob)
        redo_hit = bool(re.search(r"\b(redo|reprobe|retry|rerun|再実行|手戻り)\b", blob_s, re.I))
        for cmd in set(cmds):
            item = ensure(cmd)
            item["interactions"] += 1
            if redo_hit:
                item["redos"] += 1
            if len(item["sources"]) < 6:
                item["sources"].append(source)

    for path in iter_yaml_files("queue", "inbox") or []:
        data = load_yaml_safe(path)
        msgs = data.get("messages") if isinstance(data, dict) else []
        if not isinstance(msgs, list):
            continue
        agent = os.path.basename(path).rsplit(".", 1)[0]
        for msg in msgs:
            if not isinstance(msg, dict):
                continue
            ts = parse_ts(msg.get("timestamp"))
            blob = " ".join(str(msg.get(k, "")) for k in (
                "id", "type", "from", "message", "dedup_key", "parent_cmd",
            ))
            count_blob(blob, ts=ts, source=f"inbox/{agent}")

    for path in iter_yaml_files("queue", "tasks") or []:
        data = load_yaml_safe(path)
        task = data.get("task", data) if isinstance(data, dict) else {}
        if not isinstance(task, dict):
            continue
        ts = parse_ts(task.get("timestamp"))
        blob = " ".join(str(task.get(k, "")) for k in (
            "task_id", "parent_cmd", "description", "redo_of", "reprobe_of",
        ))
        count_blob(blob, ts=ts, source=f"task/{os.path.basename(path)}")

    for path in iter_yaml_files("queue", "reports") or []:
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except Exception:
            continue
        for entry in iter_report_entries_from_text(text):
            ts = parse_ts(entry.get("timestamp"))
            blob = " ".join(str(entry.get(k, "")) for k in (
                "task_id", "parent_cmd", "status", "summary", "result", "redo_of",
            ))
            count_blob(blob, ts=ts, source=f"report/{os.path.basename(path)}")
        # malformed report fallback: count file once if it mentions a cmd and is recent by mtime.
        try:
            mtime_dt = datetime.datetime.fromtimestamp(os.path.getmtime(path), LOCAL_TZ)
        except OSError:
            mtime_dt = None
        count_blob(text, ts=mtime_dt, source=f"report_text/{os.path.basename(path)}")

    return metrics


def gunshi2_should_escalate(parent_cmd, severity, kind):
    if not parent_cmd:
        return False
    escalations = state["gunshi2_escalations"]
    existing = escalations.get(parent_cmd)
    if isinstance(existing, dict):
        last = parse_ts(existing.get("last_notified"))
        if last is not None:
            age = (NOW - last).total_seconds() / 60.0
            if age < GUNSHI2_ESCALATION_COOLDOWN_MIN:
                return False
    task = load_task("gunshi2")
    if isinstance(task, dict):
        if status_norm(task.get("status")) == "assigned" and task.get("parent_cmd") == parent_cmd:
            return False
        if status_norm(task.get("status")) == "assigned":
            if should_emit_gunshi2_capacity_notice(f"generic:{parent_cmd}:{kind}", "P1"):
                emit("NOTIFY", "P1", (f"[P1] gunshi2_capacity — parent_cmd={parent_cmd} の "
                                        f"{kind} escalation は保留。Gunshi2 は "
                                        f"{task.get('parent_cmd')} を実行中で上書きしない。"))
            return False
    if severity in ("P0", "P1") and kind in PRIMARY_KINDS:
        return True
    return False


parent_metrics = collect_recent_parent_cmd_metrics()
gunshi2_requests = {}
for _key, _cand in current.items():
    parent = _cand.get("parent_cmd") or parent_cmd_from_blob(
        _cand.get("task_id"), _cand.get("evidence"),
    )
    if not parent:
        continue
    if gunshi2_should_escalate(parent, _cand.get("severity"), _cand.get("kind")):
        gunshi2_requests[parent] = {
            "severity": _cand.get("severity", "P2"),
            "kind": _cand.get("kind", "stall"),
            "agent": _cand.get("agent", "unknown"),
            "task_id": _cand.get("task_id", "unknown"),
            "summary": _cand.get("evidence", ""),
        }

for parent, metric in parent_metrics.items():
    interactions = int(metric.get("interactions", 0) or 0)
    redos = int(metric.get("redos", 0) or 0)
    if interactions < GUNSHI2_ROUNDTRIP_THRESHOLD and redos < GUNSHI2_REDO_THRESHOLD:
        continue
    if not gunshi2_should_escalate(parent, "P1", "long_interaction_count"):
        continue
    sources = ", ".join(metric.get("sources", [])[:6])
    gunshi2_requests.setdefault(parent, {
        "severity": "P1",
        "kind": "long_interaction_count",
        "agent": "multi-agent-shogun",
        "task_id": parent,
        "summary": (
            f"parent_cmd={parent} の24h内やり取りが多すぎる可能性。"
            f"interactions={interactions} threshold={GUNSHI2_ROUNDTRIP_THRESHOLD}, "
            f"redos={redos} threshold={GUNSHI2_REDO_THRESHOLD}, sources={sources}。"
        ),
    })

for parent, req in gunshi2_requests.items():
    state["gunshi2_escalations"][parent] = {
        "last_notified": now_iso,
        "severity": req["severity"],
        "kind": req["kind"],
        "agent": req["agent"],
        "task_id": req["task_id"],
    }
    summary = str(req["summary"]).replace("\t", " ").replace("\n", " ")
    emit("GUNSHI2", parent, req["severity"], req["kind"], req["agent"], req["task_id"], summary)


# ─────────────────────────────────────────────────────────────
# 既存 alerts と current candidate の reconcile
#  - current にあり alerts に無い → new alert (notify)
#  - 両方にある → update (severity 昇格 or cooldown 経過で再 notify)
#  - alerts に open であり current に無い → auto-resolve
#    (v1 は家老 ack 機構未実装ゆえ target 更新時 auto-resolve でよい — 軍師 state_model)
# ─────────────────────────────────────────────────────────────
SEV_RANK = {"P3": 0, "P2": 1, "P1": 2, "P0": 3}


def should_notify(alert, new_severity):
    """新規 / severity 昇格 / cooldown 経過 のいずれかで再通知する。"""
    last_notified = parse_ts(alert.get("last_notified"))
    if last_notified is None:
        return True
    if SEV_RANK.get(new_severity, 1) > SEV_RANK.get(alert.get("severity", "P2"), 1):
        return True
    if (NOW - last_notified).total_seconds() / 60.0 >= REPEAT_COOLDOWN_MIN:
        return True
    return False


for key, cand in current.items():
    existing = alerts_by_key.get(key)
    if existing is None:
        alert = {
            "key": key,
            "agent": cand["agent"],
            "task_id": cand["task_id"],
            "kind": cand["kind"],
            "severity": cand["severity"],
            "first_seen": now_iso,
            "last_seen": now_iso,
            "last_notified": now_iso,
            "count": 1,
            "status": "open",
            "evidence": cand["evidence"],
        }
        alerts.append(alert)
        alerts_by_key[key] = alert
        emit("NOTIFY", cand["severity"],
             f"[{cand['severity']}] {cand['kind']} — {cand['agent']}: {cand['evidence']}")
    else:
        existing["last_seen"] = now_iso
        existing["evidence"] = cand["evidence"]
        existing["status"] = "open"
        notify = should_notify(existing, cand["severity"])
        # severity は昇格方向のみ更新 (P1→P0 はするが P0→P1 はしない)
        if SEV_RANK.get(cand["severity"], 1) > SEV_RANK.get(existing.get("severity", "P2"), 1):
            existing["severity"] = cand["severity"]
        if notify:
            existing["last_notified"] = now_iso
            existing["count"] = int(existing.get("count", 1) or 1) + 1
            emit("NOTIFY", existing["severity"],
                 f"[{existing['severity']}] {existing['kind']} — "
                 f"{existing['agent']} (再通知#{existing['count']}): {cand['evidence']}")

# auto-resolve: open な primary alert で current に無いもの
for alert in alerts:
    if not isinstance(alert, dict):
        continue
    if alert.get("kind") not in PRIMARY_KINDS:
        continue
    if alert.get("status") == "open" and alert.get("key") not in current:
        alert["status"] = "resolved"
        alert["last_seen"] = now_iso
        emit("WARN", f"auto-resolved: {alert.get('key')} "
                     f"(target updated / no longer stalling)")

# ─────────────────────────────────────────────────────────────
# kind: karo_unresponsive_to_stall_alert (P0 secondary)
#   primary alert が open のまま、Karo へ通知済なのに KARO_SECONDARY_MIN 以上
#   ack/resolution が無い → 家老自身が止まっている可能性。家老 inbox に再 alert + log。
#   (v1 は ntfy なし。escalate_secondary() の hook point は bash 側に構造化済。)
# ─────────────────────────────────────────────────────────────
for alert in list(alerts):
    if not isinstance(alert, dict):
        continue
    if alert.get("kind") not in PRIMARY_KINDS:
        continue
    if alert.get("status") != "open":
        continue
    notified = parse_ts(alert.get("last_notified"))
    first = parse_ts(alert.get("first_seen"))
    if notified is None or first is None:
        continue
    age_min = (NOW - first).total_seconds() / 60.0
    if age_min < KARO_SECONDARY_MIN:
        continue
    src = alert.get("first_seen", "unknown")
    ku_key = (f"karo:{alert.get('agent')}_{alert.get('kind')}:"
              f"karo_unresponsive_to_stall_alert:{src}")
    ku_existing = alerts_by_key.get(ku_key)
    ev = (f"primary alert '{alert.get('key')}' が {int(age_min)}m open のまま "
          f"Karo の ack/解決なし。家老自身の stall を疑う。")
    if ku_existing is None:
        ku = {
            "key": ku_key,
            "agent": "karo",
            "task_id": alert.get("key"),
            "kind": "karo_unresponsive_to_stall_alert",
            "severity": "P0",
            "first_seen": now_iso,
            "last_seen": now_iso,
            "last_notified": now_iso,
            "count": 1,
            "status": "open",
            "evidence": ev,
        }
        alerts.append(ku)
        alerts_by_key[ku_key] = ku
        emit("NOTIFY", "P0",
             f"[P0] karo_unresponsive_to_stall_alert — karo: {ev}")
    else:
        ku_existing["last_seen"] = now_iso
        ku_existing["evidence"] = ev
        ku_existing["status"] = "open"
        if should_notify(ku_existing, "P0"):
            ku_existing["last_notified"] = now_iso
            ku_existing["count"] = int(ku_existing.get("count", 1) or 1) + 1
            emit("NOTIFY", "P0",
                 f"[P0] karo_unresponsive_to_stall_alert — "
                 f"karo (再通知#{ku_existing['count']}): {ev}")

# karo_unresponsive の auto-resolve: 元 primary alert が resolved なら解決扱い
for alert in alerts:
    if not isinstance(alert, dict):
        continue
    if alert.get("kind") != "karo_unresponsive_to_stall_alert":
        continue
    if alert.get("status") != "open":
        continue
    primary = alerts_by_key.get(alert.get("task_id"))
    if primary is None or primary.get("status") != "open":
        alert["status"] = "resolved"
        alert["last_seen"] = now_iso
        emit("WARN", f"auto-resolved: {alert.get('key')} (primary resolved)")

# ─────────────────────────────────────────────────────────────
# state / alerts file の atomic write
# ─────────────────────────────────────────────────────────────
# overflow 抑制: alert 履歴は最新 200 件まで
if len(alerts) > 200:
    alerts = alerts[-200:]

state["last_scan"] = now_iso
state["last_error"] = None
state["scan_count"] = int(state.get("scan_count", 0) or 0) + 1


def atomic_write(path, data):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, default_flow_style=False,
                       allow_unicode=True, sort_keys=False)
    os.replace(tmp, path)


try:
    atomic_write(ALERTS_FILE, {"alerts": alerts})
    atomic_write(STATE_FILE, state)
except Exception as e:
    WARNINGS.append(f"state write failed: {e}")
    traceback.print_exc(file=sys.stderr)

open_primary = sum(1 for a in alerts if isinstance(a, dict)
                   and a.get("status") == "open"
                   and a.get("kind") in PRIMARY_KINDS)
notify_count = sum(1 for line in OUT if line.startswith("NOTIFY"))
emit("SUMMARY",
     f"scan#{state['scan_count']} candidates={len(current)} "
     f"open_primary={open_primary} notify={notify_count} "
     f"warnings={len(WARNINGS)}")

for w in WARNINGS:
    emit("WARN", w)

print("\n".join(OUT))
PYEOF
    )"
    local py_rc=$?
    set -e

    if [ "$py_rc" -ne 0 ]; then
        log "ERROR: scan python exited rc=$py_rc"
        return 0
    fi

    # ── python の出力を処理 ──
    local notify_count=0
    while IFS=$'\t' read -r tag rest; do
        [ -n "${tag:-}" ] || continue
        case "$tag" in
            SUMMARY)
                log "SUMMARY: $rest"
                ;;
            WARN)
                log "WARN: $rest"
                ;;
            GUNSHI2)
                local parent_cmd g2_severity g2_kind g2_agent g2_task g2_summary
                IFS=$'\t' read -r parent_cmd g2_severity g2_kind g2_agent g2_task g2_summary <<< "$rest"
                if [ "$CAN_WRITE_GUNSHI2" -eq 1 ]; then
                    local g2_write_rc=0
                    "$PYTHON" - "$ROOT" "$parent_cmd" "$g2_severity" "$g2_kind" "$g2_agent" "$g2_task" "$g2_summary" <<'PYEOF' || g2_write_rc=$?
import datetime
import fcntl
import os
import re
import sys

import yaml

root, parent_cmd, severity, kind, agent, task_id, summary = sys.argv[1:8]
path = os.path.join(root, "queue", "tasks", "gunshi2.yaml")
state_path = os.path.join(root, "queue", "stall_detector_state.yaml")
test_now = os.environ.get("STALL_NOW")
if test_now:
    dispatched_now = datetime.datetime.fromtimestamp(int(test_now), datetime.datetime.now().astimezone().tzinfo).replace(microsecond=0)
else:
    dispatched_now = datetime.datetime.now().astimezone().replace(microsecond=0)
now = dispatched_now.isoformat()

os.makedirs(os.path.dirname(path), exist_ok=True)
# Serialize read/check/write with every detector dispatch. Atomic rename alone
# cannot prevent two scans from both deciding an empty slot is available.
lock = open(path + ".lock", "a+", encoding="utf-8")
fcntl.flock(lock.fileno(), fcntl.LOCK_EX)

existing = {}
try:
    with open(path, "r", encoding="utf-8") as f:
        existing = yaml.safe_load(f) or {}
except FileNotFoundError:
    existing = {}

task = existing.get("task") if isinstance(existing, dict) else {}
# Never replace an assigned Gunshi2 task.  The caller treats rc=2 as capacity
# and leaves its intent pending rather than claiming a successful dispatch.
if isinstance(task, dict) and task.get("status") == "assigned":
    sys.exit(2)

rca_context = None
if kind == "rca_elapsed_120m":
    m = re.search(r"family=([^; ]+); started_at=([^; ]+)", summary)
    if m:
        rca_context = {"family_id": m.group(1), "started_at": m.group(2)}

doc = {
    "task": {
        "task_id": f"gunshi2_escalation_{parent_cmd}_{dispatched_now.strftime('%Y%m%d%H%M%S')}",
        "parent_cmd": parent_cmd,
        "status": "assigned",
        "agent": "gunshi2",
        "type": "strategic_escalation",
        "bloom_level": "L6",
        # P0 RCA bypass must remain P0 in the task handed to Gunshi2.
        "priority": severity if kind == "rca_elapsed_120m" and severity == "P0" else "P1",
        "timestamp": now,
        "description": (
            "長期化またはやり取り過多の作業について、現状整理・根本原因仮説・"
            "打開策・委譲/中止/縮小判断を一度だけ上奏せよ。"
        ),
        "trigger": {
            "severity": severity,
            "kind": kind,
            "agent": agent,
            "task_id": task_id,
            "summary": summary,
        },
        "acceptance_criteria": [
            "詰まりの原因を事実・推測に分けて整理している",
            "次の一手を3案以内に絞り、推奨案と理由を明記している",
            "Karoがそのまま再配分できる粒度の実行手順を提示している",
        ],
    }
}
if rca_context is not None:
    doc["task"]["rca_context"] = rca_context

tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as f:
    yaml.safe_dump(doc, f, allow_unicode=True, sort_keys=False)
os.replace(tmp, path)
# The task is now durable.  Record the RCA-specific raw-parent cooldown before
# releasing the dispatch lock, so another family cannot race a fresh dispatch.
if rca_context is not None:
    state_lock = open(state_path + ".lock", "a+", encoding="utf-8")
    fcntl.flock(state_lock.fileno(), fcntl.LOCK_EX)
    try:
        try:
            with open(state_path, encoding="utf-8") as f:
                state = yaml.safe_load(f) or {}
        except FileNotFoundError:
            state = {}
        cooldowns = state.setdefault("rca_parent_cooldowns", {})
        dispatched = dispatched_now
        expires = dispatched + datetime.timedelta(
            minutes=int(os.environ.get("GUNSHI2_ESCALATION_COOLDOWN_MIN", "360") or "360"))
        cooldowns[parent_cmd] = {
            "family_id": rca_context["family_id"],
            "severity": severity,
            "dispatched_at": dispatched.isoformat(),
            "expires_at": expires.isoformat(),
        }
        state_tmp = f"{state_path}.tmp.rca-parent.{os.getpid()}"
        with open(state_tmp, "w", encoding="utf-8") as f:
            yaml.safe_dump(state, f, allow_unicode=True, sort_keys=False)
        os.replace(state_tmp, state_path)
    finally:
        fcntl.flock(state_lock.fileno(), fcntl.LOCK_UN)
        state_lock.close()
fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
lock.close()
PYEOF
                    if [ "$g2_write_rc" -eq 0 ]; then
                        if [ "$g2_kind" = "rca_elapsed_120m" ]; then
                            "$PYTHON" - "$STATE_FILE" "$ROOT" "$parent_cmd" "$g2_summary" <<'PYEOF' || true
import os, re, sys, yaml
path, root, parent, summary = sys.argv[1:5]
m = re.search(r"family=([^; ]+)", summary)
if not m:
    raise SystemExit(0)
family = m.group(1)
try:
    with open(path, encoding="utf-8") as f:
        state = yaml.safe_load(f) or {}
except FileNotFoundError:
    state = {}
entry = (state.get("rca_elapsed") or {}).get(f"{parent}|{family}")
if isinstance(entry, dict):
    esc = entry.setdefault("escalation", {})
    try:
        with open(os.path.join(root, "queue", "tasks", "gunshi2.yaml"), encoding="utf-8") as f:
            task_id = ((yaml.safe_load(f) or {}).get("task") or {}).get("task_id")
    except Exception:
        task_id = None
    esc["state"] = "dispatched"
    esc["dispatched_at"] = __import__("datetime").datetime.now().astimezone().replace(microsecond=0).isoformat()
    esc["gunshi2_task_id"] = task_id
    tmp = f"{path}.tmp.rca.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.safe_dump(state, f, allow_unicode=True, sort_keys=False)
    os.replace(tmp, path)
PYEOF
                        fi
                        local g2_msg
                        g2_msg="[stall_detector gunshi2 escalation] ${parent_cmd}: ${g2_kind}/${g2_severity} を検知。queue/tasks/gunshi2.yaml を読み、打開策を一度上奏せよ。trigger=${g2_agent}:${g2_task}"
                        # Fixture writers may exercise task/state persistence,
                        # but no test root may ever notify a real agent inbox.
                        if [ "$IS_REAL_ROOT" -eq 1 ]; then
                            if bash "${SCRIPT_DIR}/scripts/inbox_write.sh" \
                                gunshi2 "$g2_msg" task_assigned stall_detector >/dev/null 2>&1; then
                                log "GUNSHI2 escalation assigned ($parent_cmd $g2_kind $g2_severity)"
                            else
                                log "ERROR: inbox_write.sh gunshi2 failed for $parent_cmd"
                            fi
                        else
                            log "GUNSHI2 fixture writer assigned (inbox suppressed: $parent_cmd $g2_kind $g2_severity)"
                        fi
                    elif [ "$g2_write_rc" -eq 2 ]; then
                        local capacity_msg
                        capacity_msg="[P1] gunshi2_capacity — ${parent_cmd} ${g2_kind} は保留。既存 queue/tasks/gunshi2.yaml が assigned のため上書きせず。"
                        if [ "$IS_REAL_ROOT" -eq 1 ]; then
                            bash "${SCRIPT_DIR}/scripts/inbox_write.sh" \
                                karo "$capacity_msg" stall_alert stall_detector >/dev/null 2>&1 || true
                        fi
                        log "GUNSHI2 capacity occupied; preserved existing task ($parent_cmd)"
                    else
                        log "ERROR: failed to write gunshi2 task for $parent_cmd (rc=$g2_write_rc)"
                    fi
                else
                    log "GUNSHI2 (test-mode, task write suppressed): $rest"
                fi
                ;;
            NOTIFY)
                # rest = "<severity>\t<summary>"
                local severity summary
                severity="${rest%%$'\t'*}"
                summary="${rest#*$'\t'}"
                notify_count=$((notify_count + 1))
                if [ "$IS_REAL_ROOT" -eq 1 ]; then
                    if bash "${SCRIPT_DIR}/scripts/inbox_write.sh" \
                        karo "$summary" stall_alert stall_detector >/dev/null 2>&1; then
                        log "NOTIFY karo ($severity): $summary"
                    else
                        log "ERROR: inbox_write.sh karo failed for: $summary"
                    fi

                    # ─────────────────────────────────────────────────────
                    # 2026-05-18 殿 mandate Option A: stall_detector が
                    # `idle_with_active_task` / `assigned_no_progress` 検知時、
                    # karo alert に加えて target agent inbox にも auto-recovery
                    # message を送信し、家老の手動 wake-up なしで agent 復帰可能に。
                    # Watchdog 30s timer 終了後の long-idle stall (W14 Wave 2
                    # で 4 件同時発生) を完全自動で救う設計。
                    # summary format: `[P2] <kind> — <agent>: ...`
                    # ─────────────────────────────────────────────────────
                    local stall_kind stall_agent
                    stall_kind=$(echo "$summary" | grep -oE '\] [a-z_]+ —' | sed 's/^\] //; s/ —$//' | head -1)
                    stall_agent=$(echo "$summary" | grep -oE '— ashigaru[0-9]+:' | sed 's/^— //; s/:$//' | head -1)
                    if [ -n "$stall_kind" ] && [ -n "$stall_agent" ]; then
                        case "$stall_kind" in
                            idle_with_active_task|assigned_no_progress)
                                local wake_msg
                                wake_msg="[stall_detector auto-wake] ${stall_kind} 検知 — queue/tasks/${stall_agent}.yaml を読んで assigned/in-progress task を再開せよ。worktree に未 commit work あれば build/test verify + commit + 報告 (karo+gunshi 並行) で完了せよ。詳細 stall summary: ${summary}"
                                if bash "${SCRIPT_DIR}/scripts/inbox_write.sh" \
                                    "$stall_agent" "$wake_msg" task_assigned stall_detector >/dev/null 2>&1; then
                                    log "AUTO-WAKE $stall_agent ($stall_kind, severity=$severity)"
                                else
                                    log "ERROR: auto-wake inbox_write.sh failed for $stall_agent"
                                fi
                                ;;
                        esac
                    fi
                else
                    log "NOTIFY (test-mode, inbox suppressed) ($severity): $summary"
                fi
                # secondary escalation hook point (v1 = no-op stub)
                escalate_secondary "$severity" "$summary"
                ;;
            *)
                log "WARN: unrecognized scan output: $tag $rest"
                ;;
        esac
    done <<< "$scan_out"

    return 0
}

# ─── ensure state / alerts file が存在する (初期化) ───
ensure_state_files() {
    if [ ! -f "$ALERTS_FILE" ]; then
        printf 'alerts: []\n' > "$ALERTS_FILE"
        log "initialized $ALERTS_FILE"
    fi
    if [ ! -f "$STATE_FILE" ]; then
        cat > "$STATE_FILE" <<EOF
last_scan: null
last_error: null
scan_count: 0
pane_idle_streak: {}
worktree_progress: {}
gunshi2_escalations: {}
EOF
        log "initialized $STATE_FILE"
    fi
}

# ─── main ───
main() {
    local once=0
    if [ "${1:-}" = "--once" ]; then
        once=1
    elif [ -n "${1:-}" ]; then
        echo "Usage: stall_detector.sh [--once]" >&2
        exit 1
    fi

    ensure_state_files

    if [ "$once" -eq 1 ]; then
        log "stall_detector --once (root=$ROOT real=$IS_REAL_ROOT)"
        run_scan
        log "stall_detector --once complete"
        exit 0
    fi

    log "stall_detector daemon start (interval=${SCAN_INTERVAL_SEC}s root=$ROOT real=$IS_REAL_ROOT)"
    while [ "$RUNNING" -eq 1 ]; do
        run_scan
        # graceful shutdown 応答性のため sleep を細切れにする
        local slept=0
        while [ "$slept" -lt "$SCAN_INTERVAL_SEC" ] && [ "$RUNNING" -eq 1 ]; do
            sleep 1
            slept=$((slept + 1))
        done
    done
    log "stall_detector daemon stopped"
}

main "$@"
