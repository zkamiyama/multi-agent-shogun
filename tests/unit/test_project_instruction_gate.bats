#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GATE="$PROJECT_ROOT/scripts/project_instruction_gate.sh"
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/project_instruction_gate.XXXXXX")"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
}

write_task() {
    local task_file="$1"
    local project="$2"
    local target_path="$3"
    cat > "$task_file" <<YAML
task:
  task_id: test_task
  project: "$project"
  target_path: "$target_path"
YAML
}

@test "reads root AGENTS.md from target repo" {
    local repo="$TEST_TMPDIR/repo"
    init_repo "$repo"
    echo "ROOT_POLICY_TOKEN" > "$repo/AGENTS.md"
    mkdir -p "$repo/src"
    : > "$repo/src/app.sh"

    run bash "$GATE" --project demo --target-path "$repo/src/app.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *'status: "read"'* ]]
    [[ "$output" != *'status: "success"'* ]]
    [[ "$output" == *'path: "AGENTS.md"'* ]]
    [[ "$output" == *"ROOT_POLICY_TOKEN"* ]]
    [[ "$output" == *"nearest_git"* ]]
}

@test "AGENTS.override.md takes precedence over AGENTS.md" {
    local repo="$TEST_TMPDIR/repo"
    init_repo "$repo"
    echo "BASE_POLICY_SHOULD_NOT_APPEAR" > "$repo/AGENTS.md"
    echo "OVERRIDE_POLICY_TOKEN" > "$repo/AGENTS.override.md"
    : > "$repo/file.txt"

    run bash "$GATE" --project demo --target-path "$repo/file.txt"

    [ "$status" -eq 0 ]
    [[ "$output" == *'path: "AGENTS.override.md"'* ]]
    [[ "$output" == *'files_suppressed:'* ]]
    [[ "$output" == *'AGENTS.md:AGENTS.override.md'* ]]
    [[ "$output" == *"OVERRIDE_POLICY_TOKEN"* ]]
    [[ "$output" != *"BASE_POLICY_SHOULD_NOT_APPEAR"* ]]
}

@test "reads CLAUDE.md when it is the only instruction file" {
    local repo="$TEST_TMPDIR/repo"
    init_repo "$repo"
    echo "CLAUDE_ONLY_TOKEN" > "$repo/CLAUDE.md"
    : > "$repo/file.txt"

    run bash "$GATE" --project demo --target-path "$repo/file.txt"

    [ "$status" -eq 0 ]
    [[ "$output" == *'path: "CLAUDE.md"'* ]]
    [[ "$output" == *"CLAUDE_ONLY_TOKEN"* ]]
}

@test "reads .github/copilot-instructions.md" {
    local repo="$TEST_TMPDIR/repo"
    init_repo "$repo"
    mkdir -p "$repo/.github"
    echo "COPILOT_POLICY_TOKEN" > "$repo/.github/copilot-instructions.md"
    : > "$repo/file.txt"

    run bash "$GATE" --project demo --target-path "$repo/file.txt"

    [ "$status" -eq 0 ]
    [[ "$output" == *'path: ".github/copilot-instructions.md"'* ]]
    [[ "$output" == *"COPILOT_POLICY_TOKEN"* ]]
}

@test "no instruction files succeeds with none_found" {
    local repo="$TEST_TMPDIR/repo"
    init_repo "$repo"
    : > "$repo/file.txt"

    run bash "$GATE" --project demo --target-path "$repo/file.txt"

    [ "$status" -eq 0 ]
    [[ "$output" == *'status: "none_found"'* ]]
    [[ "$output" == *'files_read:'* ]]
    [[ "$output" == *'[]'* ]]
}

@test "unreadable instruction blocks before success" {
    local repo="$TEST_TMPDIR/repo"
    init_repo "$repo"
    : > "$repo/AGENTS.md"
    chmod 000 "$repo/AGENTS.md"
    : > "$repo/file.txt"

    run bash "$GATE" --project demo --target-path "$repo/file.txt"

    chmod 644 "$repo/AGENTS.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *'status: "blocked"'* ]]
    [[ "$output" == *'blocked_reason: "unreadable:AGENTS.md"'* ]]
}

@test "large instruction file is bounded and marked truncated" {
    local repo="$TEST_TMPDIR/repo"
    init_repo "$repo"
    yes "LARGE_POLICY_TOKEN" | head -c 200 > "$repo/AGENTS.md"
    : > "$repo/file.txt"

    run env PROJECT_INSTRUCTION_GATE_PER_FILE_LIMIT=64 PROJECT_INSTRUCTION_GATE_TOTAL_LIMIT=96 \
        bash "$GATE" --project demo --target-path "$repo/file.txt"

    [ "$status" -eq 0 ]
    [[ "$output" == *'truncated: true'* ]]
    [[ "$output" == *'bytes_read: 64'* ]]
}

@test "nested target resolves to nearest git root and does not read parent instructions" {
    local outer="$TEST_TMPDIR/outer"
    local inner="$outer/vendor/inner"
    init_repo "$outer"
    echo "OUTER_POLICY_SHOULD_NOT_APPEAR" > "$outer/AGENTS.md"
    init_repo "$inner"
    echo "INNER_POLICY_TOKEN" > "$inner/AGENTS.md"
    mkdir -p "$inner/src/deep"
    : > "$inner/src/deep/file.txt"

    run bash "$GATE" --project demo --target-path "$inner/src/deep/file.txt"

    [ "$status" -eq 0 ]
    [[ "$output" == *"INNER_POLICY_TOKEN"* ]]
    [[ "$output" != *"OUTER_POLICY_SHOULD_NOT_APPEAR"* ]]
    [[ "$output" == *"resolved_root: \"$inner\""* ]]
}

@test "relative external target path blocks without registered project root" {
    run bash "$GATE" --project external_demo --target-path "src/file.txt"

    [ "$status" -ne 0 ]
    [[ "$output" == *'status: "blocked"'* ]]
    [[ "$output" == *'relative_external_target_path_without_project_root'* ]]
}

@test "manifest directories are listed without loading their files" {
    local repo="$TEST_TMPDIR/repo"
    init_repo "$repo"
    mkdir -p "$repo/.cursor/rules" "$repo/.opencode/agents"
    echo "CURSOR_RULE_SHOULD_NOT_BE_CONTENT" > "$repo/.cursor/rules/policy.mdc"
    echo "OPENCODE_AGENT_SHOULD_NOT_BE_CONTENT" > "$repo/.opencode/agents/build.md"
    : > "$repo/file.txt"

    run bash "$GATE" --project demo --target-path "$repo/file.txt"

    [ "$status" -eq 0 ]
    [[ "$output" == *'.cursor/rules/policy.mdc'* ]]
    [[ "$output" == *'.opencode/agents/build.md'* ]]
    [[ "$output" != *"CURSOR_RULE_SHOULD_NOT_BE_CONTENT"* ]]
    [[ "$output" != *"OPENCODE_AGENT_SHOULD_NOT_BE_CONTENT"* ]]
}

@test "json format parses when instruction content contains quotes" {
    local repo="$TEST_TMPDIR/repo"
    init_repo "$repo"
    printf 'version: "3.0"\nmessage: "quoted policy"\n' > "$repo/AGENTS.md"
    : > "$repo/file.txt"

    run bash -c '"$1" --project demo --target-path "$2" --format json | python3 -m json.tool' _ "$GATE" "$repo/file.txt"

    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "read"'* ]]
    [[ "$output" == *'version: \"3.0\"'* ]]
}
