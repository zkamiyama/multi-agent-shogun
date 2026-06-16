#!/usr/bin/env bash
# Zellij backend for lib/mux_adapter.sh.

ZELLIJ_BIN="${ZELLIJ_BIN:-$(command -v zellij 2>/dev/null || true)}"
if [ -z "$ZELLIJ_BIN" ] && [ -x "$HOME/.local/bin/zellij" ]; then
    ZELLIJ_BIN="$HOME/.local/bin/zellij"
fi

mux_zellij_cmd() {
    "$ZELLIJ_BIN" "$@"
}

mux_backend_preflight() {
    if [ -z "$ZELLIJ_BIN" ] || [ ! -x "$ZELLIJ_BIN" ]; then
        echo "[mux/zellij] zellij not found. Install zellij or set MUX_BACKEND=tmux." >&2
        return 11
    fi
}

mux_zellij_session_from_target() {
    local target="$1"
    if [[ "$target" == zellij:*:* ]]; then
        local rest="${target#zellij:}"
        printf '%s\n' "${rest%%:*}"
    else
        printf '%s\n' "${ZELLIJ_SESSION_NAME:-multiagent}"
    fi
}

mux_zellij_pane_from_target() {
    local target="$1"
    if [[ "$target" == zellij:*:* ]]; then
        printf '%s\n' "${target##*:}"
    else
        printf '%s\n' "$target"
    fi
}

mux_zellij_target() {
    local session="$1"
    local pane_id="$2"
    printf 'zellij:%s:%s\n' "$session" "$pane_id"
}

mux_zellij_first_terminal_pane_id() {
    local session="$1"
    mux_zellij_cmd --session "$session" action list-panes --json 2>/dev/null \
        | python3 -c 'import json,sys
try:
    panes=json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for p in panes:
    if p.get("is_plugin"):
        continue
    pid=p.get("id", "")
    if pid is None or str(pid) == "":
        continue
    pid=str(pid)
    print(pid if pid.startswith(("terminal_", "plugin_")) else f"terminal_{pid}")
    raise SystemExit(0)
raise SystemExit(1)'
}

mux_zellij_wait_for_pane() {
    local session="$1"
    local pane_id="$2"
    local attempts="${3:-50}"
    local pane_num="${pane_id#terminal_}"
    local i
    for i in $(seq 1 "$attempts"); do
        if mux_zellij_cmd --session "$session" action list-panes --json 2>/dev/null \
            | python3 -c 'import json,sys
wanted=sys.argv[1]
try:
    panes=json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if any((not p.get("is_plugin")) and str(p.get("id"))==wanted for p in panes) else 1)' "$pane_num"
        then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

mux_zellij_state_py() {
    local code="$1"
    shift || true
    mkdir -p "$(dirname "$MUX_STATE_FILE")"
    local lock="${MUX_STATE_FILE}.lock"
    (
        flock -x 8
        MUX_STATE_FILE="$MUX_STATE_FILE" MUX_BACKEND="$MUX_BACKEND" python3 - "$@" <<PY
import os, sys, yaml, datetime
path = os.environ["MUX_STATE_FILE"]
try:
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
except FileNotFoundError:
    data = {}
data.setdefault("backend", os.environ.get("MUX_BACKEND", "zellij"))
data.setdefault("panes", {})
def save():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data["backend"] = os.environ.get("MUX_BACKEND", "zellij")
    data["updated_at"] = datetime.datetime.now(datetime.timezone.utc).astimezone().replace(microsecond=0).isoformat()
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
    os.replace(tmp, path)
$code
PY
    ) 8>"$lock"
}

mux_zellij_state_set_meta() {
    local target="$1" key="$2" value="$3"
    mux_zellij_state_py '
target, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
pane = data.setdefault("panes", {}).setdefault(target, {})
pane[key] = value
if target.startswith("zellij:"):
    _, session, pane_id = target.split(":", 2)
    pane.setdefault("session", session)
    pane.setdefault("pane_id", pane_id)
save()
' "$target" "$key" "$value"
}

mux_backend_has_session() {
    mux_backend_preflight || return $?
    mux_zellij_cmd list-sessions --short --no-formatting 2>/dev/null | grep -qx "$1"
}

mux_backend_create_session() {
    local session="$1"
    mux_backend_preflight || return $?
    mux_zellij_cmd attach --create-background "$session" >/dev/null
}

mux_backend_delete_session() {
    local session="$1"
    mux_backend_preflight || return $?
    mux_zellij_cmd delete-session --force "$session"
}

mux_backend_list_sessions() {
    mux_backend_preflight || return $?
    mux_zellij_cmd list-sessions --short --no-formatting
}

mux_backend_attach() {
    mux_backend_preflight || return $?
    mux_zellij_cmd attach "$1"
}

mux_backend_create_pane() {
    local session="$1"
    local agent_id="$2"
    local cwd="$3"
    local command="$4"
    local direction="${5:-}"
    local source_target="${6:-}"
    mux_backend_preflight || return $?
    local focus_ok=0
    local allow_directed="${MUX_ZELLIJ_DIRECTED_SPLITS:-0}"
    if [ "$allow_directed" = "1" ] && [ -n "$source_target" ]; then
        if mux_backend_pane_exists "$source_target" 2>/dev/null && mux_backend_focus_pane "$source_target" 2>/dev/null; then
            focus_ok=1
        else
            echo "[mux/zellij] source pane unavailable for ${agent_id}: ${source_target}; creating near current pane" >&2
            source_target=""
        fi
    else
        direction=""
        source_target=""
    fi
    local args=(--session "$session" action new-pane --name "$agent_id" --cwd "$cwd")
    if [ -n "$direction" ] && [ "$focus_ok" = "1" ]; then
        args+=(--near-current-pane --direction "$direction")
    fi
    args+=(-- bash -lc "$command")
    local pane_id
    pane_id=$(mux_zellij_cmd "${args[@]}")
    if [ -z "$pane_id" ]; then
        echo "[mux/zellij] failed to create pane for ${agent_id}" >&2
        return 12
    fi
    local target
    target=$(mux_zellij_target "$session" "$pane_id")
    local directed_wait_attempts=50
    if [ "$focus_ok" = "1" ] && [ -n "$direction" ]; then
        directed_wait_attempts=5
    fi
    if ! mux_zellij_wait_for_pane "$session" "$pane_id" "$directed_wait_attempts"; then
        if [ "$focus_ok" = "1" ] && [ -n "$direction" ]; then
            echo "[mux/zellij] directed split did not materialize for ${agent_id}: ${target}; retrying without direction" >&2
            args=(--session "$session" action new-pane --name "$agent_id" --cwd "$cwd" -- bash -lc "$command")
            pane_id=$(mux_zellij_cmd "${args[@]}")
            if [ -z "$pane_id" ]; then
                echo "[mux/zellij] failed to create fallback pane for ${agent_id}" >&2
                return 12
            fi
            target=$(mux_zellij_target "$session" "$pane_id")
            if ! mux_zellij_wait_for_pane "$session" "$pane_id" 50; then
                echo "[mux/zellij] fallback pane not visible for ${agent_id}: ${target}" >&2
                return 12
            fi
            direction=""
            source_target=""
        else
            echo "[mux/zellij] created pane not visible for ${agent_id}: ${target}" >&2
            return 12
        fi
    fi
    mux_zellij_state_py '
target, session, pane_id, agent_id, cwd, command, direction, source_target = sys.argv[1:]
pane = data.setdefault("panes", {}).setdefault(target, {})
pane.update({
    "target": target,
    "session": session,
    "pane_id": pane_id,
    "agent_id": agent_id,
    "cwd": cwd,
    "launch_command": command,
    "split_direction": direction,
    "split_source": source_target,
})
save()
' "$target" "$session" "$pane_id" "$agent_id" "$cwd" "$command" "$direction" "$source_target"
    printf '%s\n' "$target"
}

mux_backend_first_pane() {
    local session="$1"
    mux_backend_preflight || return $?
    local pane_id
    local i
    for i in $(seq 1 50); do
        pane_id=$(mux_zellij_first_terminal_pane_id "$session" || true)
        if [ -n "$pane_id" ]; then
            mux_zellij_target "$session" "$pane_id"
            return 0
        fi
        sleep 0.1
    done
    echo "[mux/zellij] no terminal pane found in session: ${session}" >&2
    return 12
}

mux_backend_adopt_pane() {
    local target="$1"
    local agent_id="$2"
    local cwd="$3"
    local command="$4"
    mux_backend_preflight || return $?
    local session pane_id
    session=$(mux_zellij_session_from_target "$target")
    pane_id=$(mux_zellij_pane_from_target "$target")
    if [ -z "$pane_id" ] || ! mux_zellij_wait_for_pane "$session" "$pane_id" 50; then
        echo "[mux/zellij] cannot adopt missing pane for ${agent_id}: ${target}" >&2
        return 12
    fi
    mux_zellij_cmd --session "$session" action rename-pane --pane-id "$pane_id" "$agent_id" >/dev/null
    mux_zellij_state_py '
target, session, pane_id, agent_id, cwd, command = sys.argv[1:]
pane = data.setdefault("panes", {}).setdefault(target, {})
pane.update({
    "target": target,
    "session": session,
    "pane_id": pane_id,
    "agent_id": agent_id,
    "cwd": cwd,
    "launch_command": command,
    "adopted_initial_pane": True,
})
save()
' "$target" "$session" "$pane_id" "$agent_id" "$cwd" "$command"
    mux_backend_focus_pane "$target"
    mux_backend_send_line "$target" "$command"
    printf '%s\n' "$target"
}

mux_backend_focus_pane() {
    local target="$1"
    mux_backend_preflight || return $?
    local session pane_id
    session=$(mux_zellij_session_from_target "$target")
    pane_id=$(mux_zellij_pane_from_target "$target")
    mux_zellij_cmd --session "$session" action focus-pane-id "$pane_id" >/dev/null
}

mux_backend_pane_exists() {
    local target="$1"
    mux_backend_preflight || return $?
    local session pane_id pane_num
    session=$(mux_zellij_session_from_target "$target")
    pane_id=$(mux_zellij_pane_from_target "$target")
    pane_num="${pane_id#terminal_}"
    mux_zellij_cmd --session "$session" action list-panes --json 2>/dev/null \
        | python3 -c 'import json,sys; wanted=sys.argv[1]; panes=json.load(sys.stdin); sys.exit(0 if any((not p.get("is_plugin")) and str(p.get("id"))==wanted for p in panes) else 1)' "$pane_num"
}

mux_backend_capture() {
    local target="$1"
    shift || true
    mux_backend_preflight || return $?
    local session pane_id ansi=0 full=0 tail_n=""
    session=$(mux_zellij_session_from_target "$target")
    pane_id=$(mux_zellij_pane_from_target "$target")
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ansi) ansi=1 ;;
            --full) full=1 ;;
            --tail)
                shift
                tail_n="$1"
                ;;
            --start|--join)
                [ "$1" = "--start" ] && shift
                ;;
        esac
        shift || true
    done
    local args=(--session "$session" action dump-screen --pane-id "$pane_id")
    [ "$ansi" = "1" ] && args+=(--ansi)
    [ "$full" = "1" ] && args+=(--full)
    if [ -n "$tail_n" ]; then
        mux_zellij_cmd "${args[@]}" 2>/dev/null | tail -n "$tail_n"
    else
        mux_zellij_cmd "${args[@]}" 2>/dev/null
    fi
}

mux_backend_get_meta() {
    local target="$1"
    local key="${2#@}"
    mux_zellij_state_py '
target, key = sys.argv[1], sys.argv[2]
value = (data.get("panes", {}).get(target, {}) or {}).get(key, "")
if value is not None:
    print(value)
' "$target" "$key"
}

mux_backend_set_meta() {
    local target="$1"
    local key="${2#@}"
    local value="$3"
    mux_zellij_state_set_meta "$target" "$key" "$value"
}

mux_backend_display_message() {
    local target="$1"
    local format="$2"
    case "$format" in
        '#{@agent_id}') mux_backend_get_meta "$target" agent_id ;;
        '#{@agent_cli}') mux_backend_get_meta "$target" agent_cli ;;
        '#{@model_name}') mux_backend_get_meta "$target" model_name ;;
        '#{pane_id}') mux_zellij_pane_from_target "$target" ;;
        '#{session_name}') mux_zellij_session_from_target "$target" ;;
        '#{pane_active}')
            mux_backend_pane_is_active "$target" && echo 1 || echo 0
            ;;
        *) echo "" ;;
    esac
}

mux_backend_pane_is_active() {
    local target="$1"
    mux_backend_preflight || return $?
    local session pane_id pane_num
    session=$(mux_zellij_session_from_target "$target")
    pane_id=$(mux_zellij_pane_from_target "$target")
    pane_num="${pane_id#terminal_}"
    mux_zellij_cmd --session "$session" action list-panes --json --state 2>/dev/null \
        | python3 -c 'import json,sys; wanted=sys.argv[1]; panes=json.load(sys.stdin); sys.exit(0 if any((not p.get("is_plugin")) and str(p.get("id"))==wanted and p.get("is_focused") for p in panes) else 1)' "$pane_num"
}

mux_backend_session_has_client() {
    local target_or_session="$1"
    mux_backend_preflight || return $?
    local session
    session=$(mux_zellij_session_from_target "$target_or_session")
    [ -n "$(mux_zellij_cmd --session "$session" action list-clients 2>/dev/null | tr -d '[:space:]')" ]
}

mux_backend_list_panes() {
    mux_zellij_state_py '
for target in sorted((data.get("panes", {}) or {}).keys()):
    print(target)
'
}

mux_zellij_key() {
    case "$1" in
        C-u) echo "Ctrl u" ;;
        C-c) echo "Ctrl c" ;;
        Enter) echo "Enter" ;;
        Escape) echo "Esc" ;;
        *) echo "$1" ;;
    esac
}

mux_backend_send_keys() {
    local target="$1"
    shift
    mux_backend_preflight || return $?
    local session pane_id key
    session=$(mux_zellij_session_from_target "$target")
    pane_id=$(mux_zellij_pane_from_target "$target")
    for key in "$@"; do
        mux_zellij_cmd --session "$session" action send-keys --pane-id "$pane_id" "$(mux_zellij_key "$key")"
    done
}

mux_backend_send_literal() {
    local target="$1"
    local text="$2"
    mux_backend_preflight || return $?
    local session pane_id
    session=$(mux_zellij_session_from_target "$target")
    pane_id=$(mux_zellij_pane_from_target "$target")
    mux_zellij_cmd --session "$session" action paste --pane-id "$pane_id" "$text"
}

mux_backend_send_line() {
    local target="$1"
    local text="$2"
    mux_backend_send_literal "$target" "$text"
    sleep "${MUX_SEND_ENTER_DELAY:-0.3}"
    mux_backend_send_keys "$target" Enter
}

mux_backend_find_pane_by_agent() {
    local agent="$1"
    mux_zellij_state_py '
agent = sys.argv[1]
for target, pane in (data.get("panes", {}) or {}).items():
    if (pane or {}).get("agent_id") == agent:
        print(target)
        raise SystemExit
' "$agent"
}

mux_backend_show_global_option() {
    case "$1" in
        pane-base-index) echo 0 ;;
        *) echo "" ;;
    esac
}
