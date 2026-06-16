#!/usr/bin/env bash
# tmux backend for lib/mux_adapter.sh

mux_backend_preflight() {
    if ! command -v tmux >/dev/null 2>&1; then
        echo "[mux/tmux] tmux not found" >&2
        return 11
    fi
}

mux_backend_has_session() {
    tmux has-session -t "$1" 2>/dev/null
}

mux_backend_create_session() {
    local session="$1"
    local window="${2:-main}"
    tmux new-session -d -s "$session" -n "$window"
}

mux_backend_delete_session() {
    local session="$1"
    tmux kill-session -t "$session"
}

mux_backend_list_sessions() {
    tmux list-sessions 2>/dev/null
}

mux_backend_attach() {
    tmux attach-session -t "$1"
}

mux_backend_create_pane() {
    echo "[mux/tmux] create_pane is not used by the legacy tmux layout path" >&2
    return 10
}

mux_backend_first_pane() {
    echo "[mux/tmux] first_pane is not used by the legacy tmux layout path" >&2
    return 10
}

mux_backend_adopt_pane() {
    echo "[mux/tmux] adopt_pane is not used by the legacy tmux layout path" >&2
    return 10
}

mux_backend_focus_pane() {
    echo "[mux/tmux] focus_pane is not used by the legacy tmux layout path" >&2
    return 10
}

mux_backend_pane_exists() {
    local target="$1"
    tmux display-message -t "$target" -p '#{pane_id}' >/dev/null 2>&1
}

mux_backend_capture() {
    local target="$1"
    shift || true
    local args=(-p)
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ansi) args=(-p -e) ;;
            --join) args+=(-J) ;;
            --start)
                shift
                args+=(-S "$1")
                ;;
            --full)
                ;;
            --tail)
                shift
                local n="$1"
                tmux capture-pane -t "$target" "${args[@]}" 2>/dev/null | tail -n "$n"
                return $?
                ;;
        esac
        shift || true
    done
    tmux capture-pane -t "$target" "${args[@]}" 2>/dev/null
}

mux_backend_get_meta() {
    local target="$1"
    local key="$2"
    key="${key#@}"
    tmux show-options -p -t "$target" -v "@${key}" 2>/dev/null || true
}

mux_backend_set_meta() {
    local target="$1"
    local key="$2"
    local value="$3"
    key="${key#@}"
    tmux set-option -p -t "$target" "@${key}" "$value"
}

mux_backend_display_message() {
    local target="$1"
    local format="$2"
    tmux display-message -t "$target" -p "$format" 2>/dev/null || true
}

mux_backend_pane_is_active() {
    local target="$1"
    [ "$(tmux display-message -p -t "$target" '#{pane_active}' 2>/dev/null || true)" = "1" ]
}

mux_backend_session_has_client() {
    local target_or_session="$1"
    local session_name
    if [[ "$target_or_session" == *:* ]]; then
        session_name=$(tmux display-message -p -t "$target_or_session" '#{session_name}' 2>/dev/null || true)
    else
        session_name="$target_or_session"
    fi
    [ -n "$session_name" ] && [ "$(tmux list-clients -t "$session_name" 2>/dev/null | wc -l)" -gt 0 ]
}

mux_backend_list_panes() {
    local target="${1:-}"
    if [ -n "$target" ]; then
        tmux list-panes -t "$target" -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null
    else
        tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null
    fi
}

mux_backend_send_keys() {
    local target="$1"
    shift
    tmux send-keys -t "$target" "$@"
}

mux_backend_send_literal() {
    local target="$1"
    local text="$2"
    tmux send-keys -l -t "$target" "$text"
}

mux_backend_send_line() {
    local target="$1"
    local text="$2"
    tmux send-keys -t "$target" "$text"
    sleep "${MUX_SEND_ENTER_DELAY:-0.3}"
    tmux send-keys -t "$target" Enter
}

mux_backend_find_pane_by_agent() {
    local agent="$1"
    tmux list-panes -a -F '#{session_name}:#{window_name}.#{pane_index} #{@agent_id}' 2>/dev/null \
        | awk -v agent="$agent" '$2 == agent { print $1; exit }'
}

mux_backend_show_global_option() {
    local key="$1"
    tmux show-options -gv "$key" 2>/dev/null || true
}
