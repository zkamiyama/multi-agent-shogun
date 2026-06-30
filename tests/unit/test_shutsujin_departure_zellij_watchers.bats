#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export DEPARTURE_SCRIPT="$PROJECT_ROOT/shutsujin_departure.sh"
}

@test "zellij watcher launch carries deployment id in process argv" {
    run bash -n "$DEPARTURE_SCRIPT"
    [ "$status" -eq 0 ]

    run rg -n 'nohup env SHOGUN_DEPLOYMENT_ID="\$deployment_id"' "$DEPARTURE_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "zellij watcher current check requires deployment id, target, and cli" {
    run rg -n 'SHOGUN_DEPLOYMENT_ID=\$\{deployment_id\}' "$DEPARTURE_SCRIPT"
    [ "$status" -eq 0 ]

    run rg -n 'scripts/inbox_watcher\.sh \$\{agent\} \$\{target\} \$\{cli\}' "$DEPARTURE_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "zellij watcher startup stops stale watcher for same agent before launch" {
    run rg -n 'zellij_stop_stale_watchers "\$agent" "\$target" "\$cli" "\$deployment_id"' "$DEPARTURE_SCRIPT"
    [ "$status" -eq 0 ]

    run rg -n 'pgrep -af "scripts/inbox_watcher\.sh \$\{agent\} "' "$DEPARTURE_SCRIPT"
    [ "$status" -eq 0 ]

    run rg -n 'kill "\$pid"' "$DEPARTURE_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "tmux legacy watcher launch path remains present" {
    run rg -n 'tmux show-options -p -t "shogun:main" -v @agent_cli' "$DEPARTURE_SCRIPT"
    [ "$status" -eq 0 ]

    run rg -n 'bash "\$SCRIPT_DIR/scripts/inbox_watcher\.sh" shogun "shogun:main"' "$DEPARTURE_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "zellij deployment shows Browser Access after layout completion" {
    run python3 - "$DEPARTURE_SCRIPT" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
layout = source.index('log_success "  └─ Zellij 布陣、構築完了"')
browser = source.index('log_info "🖥️ Zellij Browser Access 起動確認..."')
start = source.index('start_webui_if_missing', browser)
next_steps = source.index('echo "  次のステップ:"')
web_url = source.index('web_base_url=$(zellij_web_access_base_url)')

assert layout < browser < start < web_url < next_steps
PY
    [ "$status" -eq 0 ]
}
