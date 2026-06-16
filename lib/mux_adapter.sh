#!/usr/bin/env bash
# lib/mux_adapter.sh — multiplexer backend adapter
#
# Default backend is zellij. Set MUX_BACKEND=tmux for the legacy backend.

MUX_ADAPTER_PROJECT_ROOT="${MUX_ADAPTER_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -z "${MUX_BACKEND:-}" ]; then
    if [ -f "${MUX_ADAPTER_PROJECT_ROOT}/config/settings.yaml" ]; then
        MUX_BACKEND=$(awk '
            /^mux:[[:space:]]*$/ { in_mux=1; next }
            in_mux && /^[^[:space:]]/ { in_mux=0 }
            in_mux && /^[[:space:]]{2}backend:[[:space:]]*/ {
                v=$2; gsub(/["'\'']/, "", v); print v; exit
            }
        ' "${MUX_ADAPTER_PROJECT_ROOT}/config/settings.yaml")
    fi
    MUX_BACKEND="${MUX_BACKEND:-zellij}"
fi
MUX_STATE_FILE="${MUX_STATE_FILE:-${MUX_ADAPTER_PROJECT_ROOT}/queue/mux_state.yaml}"

mux_backend_name() {
    printf '%s\n' "$MUX_BACKEND"
}

mux__load_backend() {
    local backend_file="${MUX_ADAPTER_PROJECT_ROOT}/lib/mux/${MUX_BACKEND}.sh"
    if [ ! -f "$backend_file" ]; then
        echo "[mux_adapter] unsupported backend: ${MUX_BACKEND}" >&2
        return 10
    fi
    # shellcheck source=/dev/null
    source "$backend_file"
}

mux__lock_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

mux__with_send_lock() {
    local target="$1"
    shift
    local lock="/tmp/shogun_mux_send_$(mux__lock_name "$target").lock"
    (
        flock -x 9
        "$@"
    ) 9>"$lock"
}

mux_preflight() {
    mux_backend_preflight
}

mux_has_session() {
    mux_backend_has_session "$@"
}

mux_create_session() {
    mux_backend_create_session "$@"
}

mux_delete_session() {
    local session="${1:-}"
    case "$session" in
        shogun|multiagent) ;;
        *)
            if [ "${MUX_ALLOW_UNSAFE_SESSION_DELETE:-0}" != "1" ]; then
                echo "[mux_adapter] refusing to delete non-shogun session: ${session}" >&2
                return 13
            fi
            ;;
    esac
    mux_backend_delete_session "$@"
}

mux_list_sessions() {
    mux_backend_list_sessions "$@"
}

mux_attach() {
    mux_backend_attach "$@"
}

mux_create_pane() {
    mux_backend_create_pane "$@"
}

mux_first_pane() {
    mux_backend_first_pane "$@"
}

mux_adopt_pane() {
    mux_backend_adopt_pane "$@"
}

mux_focus_pane() {
    mux_backend_focus_pane "$@"
}

mux_pane_exists() {
    mux_backend_pane_exists "$@"
}

mux_capture() {
    mux_backend_capture "$@"
}

mux_get_meta() {
    mux_backend_get_meta "$@"
}

mux_set_meta() {
    mux_backend_set_meta "$@"
}

mux_display_message() {
    mux_backend_display_message "$@"
}

mux_pane_is_active() {
    mux_backend_pane_is_active "$@"
}

mux_session_has_client() {
    mux_backend_session_has_client "$@"
}

mux_list_panes() {
    mux_backend_list_panes "$@"
}

mux_send_keys() {
    local target="$1"
    shift
    mux__with_send_lock "$target" mux_backend_send_keys "$target" "$@"
}

mux_send_literal() {
    local target="$1"
    shift
    mux__with_send_lock "$target" mux_backend_send_literal "$target" "$@"
}

mux_send_line() {
    local target="$1"
    local text="$2"
    mux__with_send_lock "$target" mux_backend_send_line "$target" "$text"
}

mux_find_pane_by_agent() {
    mux_backend_find_pane_by_agent "$@"
}

mux_show_global_option() {
    mux_backend_show_global_option "$@"
}

mux__load_backend
