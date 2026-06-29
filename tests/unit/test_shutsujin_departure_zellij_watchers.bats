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
