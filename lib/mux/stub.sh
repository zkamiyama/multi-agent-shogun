#!/usr/bin/env bash
# Test backend for lib/mux_adapter.sh. Records operations to MUX_STUB_LOG.

MUX_STUB_LOG="${MUX_STUB_LOG:-/tmp/shogun_mux_stub.log}"
MUX_STUB_META="${MUX_STUB_META:-/tmp/shogun_mux_stub_meta.tsv}"

mux_stub_log() {
    printf '%s\n' "$*" >> "$MUX_STUB_LOG"
}

mux_backend_preflight() {
    mux_stub_log "preflight"
}

mux_backend_has_session() {
    mux_stub_log "has_session $1"
    [ "${MUX_STUB_HAS_SESSION:-1}" = "1" ]
}

mux_backend_create_session() {
    mux_stub_log "create_session $*"
}

mux_backend_delete_session() {
    mux_stub_log "delete_session $*"
}

mux_backend_list_sessions() {
    mux_stub_log "list_sessions"
    printf '%s\n' "${MUX_STUB_LIST_SESSIONS:-stub-session}"
}

mux_backend_attach() {
    mux_stub_log "attach $*"
}

mux_backend_create_pane() {
    local session="$1"
    local agent="$2"
    mux_stub_log "create_pane $*"
    printf 'stub:%s:%s\n' "$session" "$agent"
}

mux_backend_first_pane() {
    mux_stub_log "first_pane $1"
    printf 'stub:%s:first\n' "$1"
}

mux_backend_adopt_pane() {
    mux_stub_log "adopt_pane $*"
    printf '%s\n' "$1"
}

mux_backend_focus_pane() {
    mux_stub_log "focus_pane $1"
    [ "${MUX_STUB_FOCUS_OK:-1}" = "1" ]
}

mux_backend_pane_exists() {
    mux_stub_log "pane_exists $1"
    [ "${MUX_STUB_PANE_EXISTS:-1}" = "1" ]
}

mux_backend_capture() {
    local target="$1"
    shift || true
    mux_stub_log "capture $target $*"
    printf '%s\n' "${MUX_STUB_CAPTURE:-}"
}

mux_backend_get_meta() {
    local target="$1"
    local key="${2#@}"
    mux_stub_log "get_meta $target $key"
    awk -F '\t' -v t="$target" -v k="$key" '$1 == t && $2 == k { v=$3 } END { if (v != "") print v }' "$MUX_STUB_META" 2>/dev/null || true
}

mux_backend_set_meta() {
    local target="$1"
    local key="${2#@}"
    local value="$3"
    mux_stub_log "set_meta $target $key $value"
    mkdir -p "$(dirname "$MUX_STUB_META")"
    touch "$MUX_STUB_META"
    awk -F '\t' -v t="$target" -v k="$key" '!($1 == t && $2 == k)' "$MUX_STUB_META" > "${MUX_STUB_META}.tmp"
    printf '%s\t%s\t%s\n' "$target" "$key" "$value" >> "${MUX_STUB_META}.tmp"
    mv "${MUX_STUB_META}.tmp" "$MUX_STUB_META"
}

mux_backend_display_message() {
    mux_stub_log "display_message $1 $2"
    case "$2" in
        '#{@agent_id}') mux_backend_get_meta "$1" agent_id ;;
        '#{pane_id}') printf 'stub-pane\n' ;;
        '#{pane_active}') printf '%s\n' "${MUX_STUB_PANE_ACTIVE:-0}" ;;
        '#{session_name}') printf '%s\n' "${MUX_STUB_SESSION_NAME:-stub}" ;;
    esac
}

mux_backend_pane_is_active() {
    mux_stub_log "pane_is_active $1"
    [ "${MUX_STUB_PANE_ACTIVE:-0}" = "1" ]
}

mux_backend_session_has_client() {
    mux_stub_log "session_has_client $1"
    [ "${MUX_STUB_HAS_CLIENT:-0}" = "1" ]
}

mux_backend_list_panes() {
    mux_stub_log "list_panes ${1:-}"
    printf '%s\n' "${MUX_STUB_LIST_PANES:-stub:main.0}"
}

mux_backend_send_keys() {
    local target="$1"
    shift
    mux_stub_log "send_keys $target $*"
}

mux_backend_send_literal() {
    mux_stub_log "send_literal $1 $2"
}

mux_backend_send_line() {
    mux_stub_log "send_literal $1 $2"
    mux_stub_log "send_keys $1 Enter"
}

mux_backend_find_pane_by_agent() {
    local agent="$1"
    mux_stub_log "find_pane_by_agent $agent"
    printf '%s\n' "${MUX_STUB_FIND_PANE:-stub:main.0}"
}

mux_backend_show_global_option() {
    mux_stub_log "show_global_option $1"
    printf '%s\n' "${MUX_STUB_GLOBAL_OPTION:-0}"
}
