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
AGENTS=(karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 gunshi)
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

# compute_pane_states — 全 agent の pane 状態を JSON で stdout に出す。
# {"karo":"idle","ashigaru1":"busy",...}  state ∈ idle|busy|absent|unknown
compute_pane_states() {
    local json="{"
    local first=1
    local agent pane state rc
    for agent in "${AGENTS[@]}"; do
        pane="${AGENT_PANE[$agent]}"
        state="unknown"
        if type agent_is_busy_check &>/dev/null; then
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
    #   WARN<TAB><parse warning 等>
    local scan_out
    set +e
    scan_out="$(
        STALL_ROOT="$ROOT" \
        STALL_PANE_STATES="$pane_states" \
        STALL_NOW="$now_override" \
        STALL_STATE_FILE="$STATE_FILE" \
        STALL_ALERTS_FILE="$ALERTS_FILE" \
        STALL_SCAN_INTERVAL_SEC="$SCAN_INTERVAL_SEC" \
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
STATE_FILE = os.environ["STALL_STATE_FILE"]
ALERTS_FILE = os.environ["STALL_ALERTS_FILE"]
SCAN_INTERVAL_SEC = int(os.environ.get("STALL_SCAN_INTERVAL_SEC", "60") or "60")

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
KARO_SECONDARY_MIN = 30       # karo_unresponsive_to_stall_alert
REPEAT_COOLDOWN_MIN = 30      # 再通知 cooldown (軍師: blocked 30m repeat cooldown)
BUSY_CEILING_MIN = 180        # pane busy でも 3h 超なら informational に downgrade

AGENTS = ["karo", "ashigaru1", "ashigaru2", "ashigaru3", "ashigaru4",
          "ashigaru5", "ashigaru6", "ashigaru7", "gunshi"]
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
    if agent == "gunshi" and bloom in ("l5", "l6"):
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
if not isinstance(state.get("pane_idle_streak"), dict):
    state["pane_idle_streak"] = {}
if not isinstance(state.get("worktree_progress"), dict):
    state["worktree_progress"] = {}

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


def add_candidate(agent, task_id, kind, source_ts, severity, evidence):
    key = f"{agent}:{task_id}:{kind}:{source_ts}"
    current[key] = {
        "key": key,
        "agent": agent,
        "task_id": task_id,
        "kind": kind,
        "severity": severity,
        "evidence": evidence,
    }


for agent in ASHIGARU + ["gunshi"]:
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
                              src, sev, ev)

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
                              src, "P3", ev)
        elif idle_streak(agent) >= 2 and mins_since_progress >= threshold:
            sev = "P1" if mins_since_progress >= ASSIGNED_P1_MIN else "P2"
            src = iso(task_ts) if task_ts else "unknown"
            ev = (f"task '{task_id}' assigned {int(mins_assigned or 0)}m、"
                  f"last_progress から {int(mins_since_progress)}m 進捗なし "
                  f"(threshold {threshold}m、type={task.get('type')})。"
                  f"worktree HEAD/mtime 不変 / task ts 以後 report 更新なし / "
                  f"inbox unread 0 / pane idle {idle_streak(agent)} 連続。")
            add_candidate(agent, task_id, "assigned_no_progress",
                          src, sev, ev)

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
        add_candidate(agent, task_id, "idle_with_active_task", src, "P2", ev)


# false_positive_controls #5: Karo には agent ごとに 1 actionable alert を出す。
# 同一 agent に複数 kind が立った場合 (例: blocked report を抱えたまま idle)、
# 優先度 blocked > assigned_no_progress > idle_with_active_task で 1 件に絞る。
KIND_PRIORITY = {
    "blocked_report_unresolved": 3,
    "assigned_no_progress": 2,
    "idle_with_active_task": 1,
}
_best_by_agent = {}
for _key, _cand in current.items():
    _agent = _cand["agent"]
    _prio = KIND_PRIORITY.get(_cand["kind"], 0)
    if _agent not in _best_by_agent or _prio > _best_by_agent[_agent][0]:
        _best_by_agent[_agent] = (_prio, _key)
_keep_keys = {k for _, k in _best_by_agent.values()}
current = {k: v for k, v in current.items() if k in _keep_keys}


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


PRIMARY_KINDS = ("blocked_report_unresolved", "assigned_no_progress",
                 "idle_with_active_task")

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
