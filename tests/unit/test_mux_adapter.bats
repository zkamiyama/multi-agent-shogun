#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/mux_adapter.XXXXXX")"
    export MUX_STUB_LOG="$TEST_TMPDIR/stub.log"
    export MUX_STUB_META="$TEST_TMPDIR/meta.tsv"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "mux adapter defaults to zellij backend" {
    run bash -c "source '$PROJECT_ROOT/lib/mux_adapter.sh'; mux_backend_name"
    [ "$status" -eq 0 ]
    [ "$output" = "zellij" ]
}

@test "tmux backend remains explicitly selectable" {
    run bash -c "export MUX_BACKEND=tmux; source '$PROJECT_ROOT/lib/mux_adapter.sh'; mux_backend_name"
    [ "$status" -eq 0 ]
    [ "$output" = "tmux" ]
}

@test "stub backend records send_line as literal plus enter" {
    run bash -c "export MUX_BACKEND=stub; source '$PROJECT_ROOT/lib/mux_adapter.sh'; mux_send_line paneA inbox1"
    [ "$status" -eq 0 ]
    grep -q "send_literal paneA inbox1" "$MUX_STUB_LOG"
    grep -q "send_keys paneA Enter" "$MUX_STUB_LOG"
}

@test "tmux_compat send-keys sends ordinary text as literal for non-tmux backends" {
    run bash -c "export MUX_BACKEND=stub; source '$PROJECT_ROOT/lib/tmux_compat.sh'; tmux send-keys -t paneA inbox1 Enter"
    [ "$status" -eq 0 ]
    grep -q "send_literal paneA inbox1" "$MUX_STUB_LOG"
    grep -q "send_keys paneA Enter" "$MUX_STUB_LOG"
}

@test "stub backend persists metadata" {
    run bash -c "export MUX_BACKEND=stub; source '$PROJECT_ROOT/lib/mux_adapter.sh'; mux_set_meta paneA agent_id karo; mux_get_meta paneA agent_id"
    [ "$status" -eq 0 ]
    [ "$output" = "karo" ]
}

@test "stub backend records adopted initial pane and directed splits" {
    run bash -c "
        export MUX_BACKEND=stub
        source '$PROJECT_ROOT/lib/mux_adapter.sh'
        p0=\$(mux_first_pane multiagent)
        p0=\$(mux_adopt_pane \"\$p0\" karo '$PROJECT_ROOT' 'echo karo')
        p1=\$(mux_create_pane multiagent ashigaru1 '$PROJECT_ROOT' 'echo a1' right \"\$p0\")
        mux_create_pane multiagent ashigaru3 '$PROJECT_ROOT' 'echo a3' down \"\$p0\" >/dev/null
    "
    [ "$status" -eq 0 ]
    grep -q "first_pane multiagent" "$MUX_STUB_LOG"
    grep -q "adopt_pane stub:multiagent:first karo" "$MUX_STUB_LOG"
    grep -q "create_pane multiagent ashigaru1 .* right stub:multiagent:first" "$MUX_STUB_LOG"
    grep -q "create_pane multiagent ashigaru3 .* down stub:multiagent:first" "$MUX_STUB_LOG"
}

@test "zellij create pane falls back when requested source pane cannot be focused" {
    if ! command -v zellij >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/zellij" ]; then
        skip "zellij not installed"
    fi
    local session="shogun-bats-zellij-fallback-$$"
    zellij attach --create-background "$session" >/dev/null
    run bash -c "
        export MUX_BACKEND=zellij
        export MUX_STATE_FILE='$TEST_TMPDIR/mux_state.yaml'
        source '$PROJECT_ROOT/lib/mux_adapter.sh'
        mux_create_pane '$session' ashigaru1 '$PROJECT_ROOT' 'printf ready; sleep 1' right 'zellij:$session:terminal_999999'
    "
    zellij delete-session --force "$session" >/dev/null 2>&1 || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"zellij:${session}:terminal_"* ]]
}

@test "zellij backend fails preflight when zellij is missing or succeeds when installed" {
    run bash -c "export MUX_BACKEND=zellij; source '$PROJECT_ROOT/lib/mux_adapter.sh'; mux_preflight"
    if command -v zellij >/dev/null 2>&1 || [ -x "$HOME/.local/bin/zellij" ]; then
        [ "$status" -eq 0 ]
    else
        [ "$status" -eq 11 ]
        [[ "$output" == *"zellij not found"* ]]
    fi
}

@test "delete_session refuses sessions outside shogun allowlist" {
    run bash -c "export MUX_BACKEND=stub; source '$PROJECT_ROOT/lib/mux_adapter.sh'; mux_delete_session unrelated"
    [ "$status" -eq 13 ]
    [[ "$output" == *"refusing to delete non-shogun session"* ]]
    [ ! -s "$MUX_STUB_LOG" ]
}

@test "delete_session allows shogun sessions" {
    run bash -c "export MUX_BACKEND=stub; source '$PROJECT_ROOT/lib/mux_adapter.sh'; mux_delete_session shogun"
    [ "$status" -eq 0 ]
    grep -q "delete_session shogun" "$MUX_STUB_LOG"
}

@test "zellij metadata writes are serialized and do not lose concurrent keys" {
    state_file="$TEST_TMPDIR/mux_state.yaml"
    run bash -c "
        export MUX_BACKEND=zellij
        export MUX_STATE_FILE='$state_file'
        source '$PROJECT_ROOT/lib/mux_adapter.sh'
        for i in \$(seq 1 40); do
            mux_set_meta zellij:multiagent:terminal_1 key_\$i value_\$i &
        done
        wait
        python3 - <<'PY'
import yaml
with open('$state_file', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
pane = data.get('panes', {}).get('zellij:multiagent:terminal_1', {})
missing = [f'key_{i}' for i in range(1, 41) if pane.get(f'key_{i}') != f'value_{i}']
if missing:
    raise SystemExit('missing ' + ','.join(missing))
print(len([k for k in pane if k.startswith('key_')]))
PY
    "
    [ "$status" -eq 0 ]
    [ "$output" = "40" ]
}

@test "agent_identity prefers SHOGUN_AGENT_ID" {
    run env SHOGUN_AGENT_ID=gunshi bash "$PROJECT_ROOT/scripts/agent_identity.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "gunshi" ]
}

@test "generated instructions use backend-neutral agent identity" {
    run rg -n 'tmux display-message -t \"\\$TMUX_PANE\"|Canonical tmux check' "$PROJECT_ROOT/AGENTS.md" "$PROJECT_ROOT/instructions/generated" "$PROJECT_ROOT/instructions/common" "$PROJECT_ROOT/scripts/build_instructions.sh"
    [ "$status" -eq 1 ]

    run rg -n 'bash scripts/agent_identity.sh' "$PROJECT_ROOT/AGENTS.md" "$PROJECT_ROOT/instructions/generated/codex-karo.md" "$PROJECT_ROOT/instructions/generated/codex-gunshi.md" "$PROJECT_ROOT/instructions/generated/codex-ashigaru.md" "$PROJECT_ROOT/scripts/session_start_hook.sh" "$PROJECT_ROOT/scripts/build_instructions.sh"
    [ "$status" -eq 0 ]
}

@test "status scripts resolve non-tmux panes through mux adapter" {
    run rg -n 'mux_find_pane_by_agent|resolve_agent_pane' "$PROJECT_ROOT/scripts/stall_detector.sh" "$PROJECT_ROOT/scripts/agent_status.sh" "$PROJECT_ROOT/scripts/ratelimit_check.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scripts/stall_detector.sh"* ]]
    [[ "$output" == *"scripts/agent_status.sh"* ]]
    [[ "$output" == *"scripts/ratelimit_check.sh"* ]]
}
