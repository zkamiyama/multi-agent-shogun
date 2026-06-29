#!/usr/bin/env bash
# inbox_write.sh — メールボックスへのメッセージ書き込み（排他ロック付き）
# Usage: bash scripts/inbox_write.sh <target_agent> <content> <type> <from>
# Example: bash scripts/inbox_write.sh karo "足軽5号、任務完了" report_received ashigaru5

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$1"
CONTENT="$2"
TYPE="$3"
FROM="$4"
EXPLICIT_DEDUP_KEY="${DEDUP_KEY:-}"

INBOX="$SCRIPT_DIR/queue/inbox/${TARGET}.yaml"
LOCKFILE="${INBOX}.lock"

# Validate arguments
if [ -z "$TARGET" ] || [ -z "$CONTENT" ] || [ -z "$TYPE" ] || [ -z "$FROM" ]; then
    echo "Usage: inbox_write.sh <target_agent> <content> <type> <from>" >&2
    exit 1
fi

# Self-send guard: reject messages where sender == target
if [ "$FROM" = "$TARGET" ]; then
    echo "[inbox_write] REJECTED: self-send detected (from=$FROM, target=$TARGET)" >&2
    exit 1
fi

# Initialize inbox if not exists
# dangling symlink recovery: queue/inbox が壊れたシンボリックリンクならリンク先を再生成
_inbox_parent="$(dirname "$INBOX")"
if [ -L "$_inbox_parent" ] && [ ! -d "$_inbox_parent" ]; then
    mkdir -p "$(readlink "$_inbox_parent")"
fi
if [ ! -f "$INBOX" ]; then
    mkdir -p "$_inbox_parent"
    echo "messages: []" > "$INBOX"
fi

# Generate unique message ID (timestamp + 4 random bytes).
# Use `od` instead of `xxd` because `od` is available on both GNU/Linux and macOS runners by default.
MSG_ID="msg_$(date +%Y%m%d_%H%M%S)_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")

# Cross-process lock: mkdir coordinates with OpenCode tools; flock is added when available.
LOCK_DIR="${LOCKFILE}.d"
SUPERVISOR_HEARTBEAT="${SCRIPT_DIR}/queue/supervisor.heartbeat"
SUPERVISOR_LOCKFILE="${SCRIPT_DIR}/queue/supervisor.lock"
SUPERVISOR_LOG="${SCRIPT_DIR}/logs/watcher_supervisor.log"
SUPERVISOR_STALE_SECONDS="${INBOX_WRITE_SUPERVISOR_STALE_SECONDS:-60}"

_acquire_lock() {
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ $i -ge 50 ] && return 1  # 5s timeout
    done

    if command -v flock &>/dev/null; then
        exec 200>"$LOCKFILE"
        flock -w 5 200 || {
            rmdir "$LOCK_DIR" 2>/dev/null
            return 1
        }
    fi
    return 0
}

_release_lock() {
    if command -v flock &>/dev/null; then
        exec 200>&-
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

_watcher_supervisor_alive() {
    local pid argv0 argv1
    for pid in $(pgrep -f "watcher_supervisor.sh" 2>/dev/null || true); do
        [ -r "/proc/$pid/cmdline" ] || continue
        argv0=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n '1p')
        argv1=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n '2p')
        if [[ "$argv0" == *bash ]] && [[ "$argv1" == */watcher_supervisor.sh ]]; then
            return 0
        fi
    done
    return 1
}

_supervisor_heartbeat_age() {
    local now hb_ts
    if [ ! -f "$SUPERVISOR_HEARTBEAT" ]; then
        echo 999999
        return 0
    fi
    now=$(date +%s 2>/dev/null || echo 0)
    hb_ts=$(stat -c %Y "$SUPERVISOR_HEARTBEAT" 2>/dev/null || echo 0)
    echo $((now - hb_ts))
}

_start_watcher_supervisor_detached() {
    [ -f "${SCRIPT_DIR}/scripts/watcher_supervisor.sh" ] || return 0
    mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/queue" 2>/dev/null || true
    echo "[$(date -Iseconds)] inbox_write: spawning watcher_supervisor after $1 heartbeat (age=${2}s)" \
        >> "$SUPERVISOR_LOG" 2>&1 || true
    setsid nohup bash "${SCRIPT_DIR}/scripts/watcher_supervisor.sh" \
        >> "$SUPERVISOR_LOG" 2>&1 < /dev/null &
    disown 2>/dev/null || true
}

_ensure_watcher_supervisor_best_effort() {
    [ "${INBOX_WRITE_SUPERVISOR_SELF_HEAL:-1}" = "1" ] || return 0

    local age state alive=0
    age=$(_supervisor_heartbeat_age)
    if [ "$age" -lt "$SUPERVISOR_STALE_SECONDS" ]; then
        return 0
    fi

    state="stale"
    [ -f "$SUPERVISOR_HEARTBEAT" ] || state="missing"
    _watcher_supervisor_alive && alive=1

    mkdir -p "$(dirname "$SUPERVISOR_LOCKFILE")" 2>/dev/null || true
    (
        if command -v flock >/dev/null 2>&1; then
            flock -n 9 || exit 0
        fi

        local recheck_age recheck_state
        recheck_age=$(_supervisor_heartbeat_age)
        if [ "$recheck_age" -lt "$SUPERVISOR_STALE_SECONDS" ]; then
            exit 0
        fi

        recheck_state="stale"
        [ -f "$SUPERVISOR_HEARTBEAT" ] || recheck_state="missing"
        # Heartbeat freshness is authoritative here. A live supervisor process with
        # a stale heartbeat may be wedged, so we still make one best-effort start
        # attempt; watcher-level lifetime locks bound duplicate side effects.
        echo "[$(date -Iseconds)] inbox_write: supervisor heartbeat ${recheck_state}; liveness=${alive}" \
            >> "$SUPERVISOR_LOG" 2>&1 || true
        _start_watcher_supervisor_detached "$recheck_state" "$recheck_age"
    ) 9>"$SUPERVISOR_LOCKFILE" >/dev/null 2>&1 || true
}

# Atomic write with lock (3 retries)
attempt=0
max_attempts=3

while [ $attempt -lt $max_attempts ]; do
    if _acquire_lock; then
        trap _release_lock EXIT
        if TARGET="$TARGET" CONTENT="$CONTENT" TYPE="$TYPE" FROM="$FROM" MSG_ID="$MSG_ID" TIMESTAMP="$TIMESTAMP" EXPLICIT_DEDUP_KEY="$EXPLICIT_DEDUP_KEY" INBOX="$INBOX" "$SCRIPT_DIR/.venv/bin/python3" <<'PY'
import os
import re
import sys

import yaml

TASK_NOTIFICATION_TYPES = {
    "cmd_new",
    "task_assigned",
    "clear_command",
    "model_switch",
    "status_update",
    "coordination",
}

target = os.environ["TARGET"]
content = os.environ["CONTENT"]
msg_type = os.environ["TYPE"]
sender = os.environ["FROM"]
msg_id = os.environ["MSG_ID"]
timestamp = os.environ["TIMESTAMP"]
explicit_dedup_key = os.environ.get("EXPLICIT_DEDUP_KEY", "")
inbox = os.environ["INBOX"]

def extract_task_ref(text):
    patterns = [
        r"\btask_id\s*[:=]\s*([A-Za-z0-9_.:-]+)",
        r"\bparent_cmd\s*[:=]\s*(cmd_[A-Za-z0-9_.:-]+)",
        r"\b(cmd_[0-9A-Za-z_.:-]+)\b",
        r"\b(subtask_[A-Za-z0-9_.:-]+)\b",
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return match.group(1).rstrip("。、,;)")
    return None

def dedup_key_for(message_type, message_from, message_content):
    if explicit_dedup_key:
        return f"explicit:{target}:{message_type}:{message_from}:{explicit_dedup_key}"
    if message_type not in TASK_NOTIFICATION_TYPES:
        return None
    task_ref = extract_task_ref(message_content)
    if not task_ref:
        return None
    return f"task:{target}:{message_type}:{message_from}:{task_ref}"

try:
    # Load existing inbox
    with open(inbox) as f:
        data = yaml.safe_load(f)

    # Initialize if needed
    if not data:
        data = {}
    if not data.get('messages'):
        data['messages'] = []

    # Add new message
    new_msg = {
        "id": msg_id,
        "from": sender,
        "timestamp": timestamp,
        "type": msg_type,
        "content": content,
        "read": False
    }
    dedup_key = dedup_key_for(msg_type, sender, content)
    deduped = False
    if dedup_key:
        for msg in reversed(data["messages"]):
            if msg.get("read", False):
                continue
            existing_key = msg.get("dedup_key")
            if not existing_key and not explicit_dedup_key:
                existing_key = dedup_key_for(
                    msg.get("type", ""),
                    msg.get("from", ""),
                    msg.get("content", ""),
                )
            if existing_key == dedup_key:
                msg["dedup_key"] = dedup_key
                msg["content"] = content
                msg["retry_count"] = int(msg.get("retry_count", 0) or 0) + 1
                msg["last_notified_at"] = timestamp
                msg.setdefault("first_notified_at", msg.get("timestamp"))
                duplicate_ids = msg.setdefault("duplicate_message_ids", [])
                duplicate_ids.append(msg_id)
                deduped = True
                break

    if not deduped:
        if dedup_key:
            new_msg["dedup_key"] = dedup_key
            new_msg["retry_count"] = 0
            new_msg["first_notified_at"] = timestamp
            new_msg["last_notified_at"] = timestamp
        data["messages"].append(new_msg)

    # Overflow protection: keep max 50 messages
    if len(data["messages"]) > 50:
        msgs = data["messages"]
        unread = [m for m in msgs if not m.get("read", False)]
        read = [m for m in msgs if m.get("read", False)]
        # Keep all unread + newest 30 read messages
        data["messages"] = unread + read[-30:]

    # Atomic write: tmp file + rename (prevents partial reads)
    import tempfile
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(inbox), suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w") as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, inbox)
    except:
        os.unlink(tmp_path)
        raise

except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PY
        then
            STATUS=0
        else
            STATUS=$?
        fi
        _release_lock
        trap - EXIT
        if [ $STATUS -eq 0 ]; then
            _ensure_watcher_supervisor_best_effort
            exit 0
        fi
        attempt=$((attempt + 1))
        [ $attempt -lt $max_attempts ] && sleep 1
    else
        # Lock timeout
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_write] Lock timeout for $INBOX (attempt $attempt/$max_attempts), retrying..." >&2
            sleep 1
        else
            echo "[inbox_write] Failed to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done
