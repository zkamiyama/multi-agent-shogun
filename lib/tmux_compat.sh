#!/usr/bin/env bash
# Compatibility shim for legacy scripts that still call a small tmux subset.
# Active only when MUX_BACKEND is not tmux; routes calls through mux_adapter.

TMUX_COMPAT_PROJECT_ROOT="${TMUX_COMPAT_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if ! type mux_backend_name >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$TMUX_COMPAT_PROJECT_ROOT/lib/mux_adapter.sh"
fi

if [ "$(mux_backend_name)" != "tmux" ]; then
tmux() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        show-options)
            local pane="" key="" global=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -p) ;;
                    -t) shift; pane="$1" ;;
                    -v) ;;
                    -g|-gv|-vg) global=1 ;;
                    @*) key="${1#@}" ;;
                    *) [ -z "$key" ] && key="$1" ;;
                esac
                shift || true
            done
            if [ "$global" = "1" ]; then
                mux_show_global_option "$key"
            else
                mux_get_meta "$pane" "$key"
            fi
            ;;
        set-option)
            local pane="" key="" value=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -p|-w) ;;
                    -t) shift; pane="$1" ;;
                    @*) key="${1#@}"; shift; value="${1:-}" ;;
                esac
                shift || true
            done
            [ -n "$pane" ] && [ -n "$key" ] && mux_set_meta "$pane" "$key" "$value"
            ;;
        display-message)
            local pane="" fmt=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -p) ;;
                    -t) shift; pane="$1" ;;
                    *) fmt="$1" ;;
                esac
                shift || true
            done
            mux_display_message "$pane" "$fmt"
            ;;
        capture-pane)
            local pane="" ansi=0 start="" join=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -t) shift; pane="$1" ;;
                    -e) ansi=1 ;;
                    -J) join=1 ;;
                    -S) shift; start="$1" ;;
                    -p) ;;
                esac
                shift || true
            done
            local args=()
            [ "$ansi" = "1" ] && args+=(--ansi)
            [ "$join" = "1" ] && args+=(--join)
            [ -n "$start" ] && args+=(--start "$start")
            mux_capture "$pane" "${args[@]}"
            ;;
        send-keys)
            local pane="" literal=0 args=()
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -t) shift; pane="$1" ;;
                    -l) literal=1 ;;
                    *) args+=("$1") ;;
                esac
                shift || true
            done
            if [ "$literal" = "1" ]; then
                mux_send_literal "$pane" "${args[*]}"
            else
                local arg
                for arg in "${args[@]}"; do
                    case "$arg" in
                        Enter|Escape|C-c|C-u|Up|Down|Left|Right|Tab|Backspace|Delete)
                            mux_send_keys "$pane" "$arg"
                            ;;
                        "")
                            ;;
                        *)
                            mux_send_literal "$pane" "$arg"
                            ;;
                    esac
                done
            fi
            ;;
        list-clients)
            local session=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -t) shift; session="$1" ;;
                esac
                shift || true
            done
            mux_session_has_client "$session" && echo "client"
            ;;
        list-panes)
            mux_list_panes
            ;;
        select-pane)
            return 0
            ;;
        has-session)
            local session=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -t) shift; session="$1" ;;
                esac
                shift || true
            done
            mux_has_session "$session"
            ;;
        *)
            echo "[tmux_compat] unsupported tmux command for $(mux_backend_name): $cmd" >&2
            return 10
            ;;
    esac
}
fi
