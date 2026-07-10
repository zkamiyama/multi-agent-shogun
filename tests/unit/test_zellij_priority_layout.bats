#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LAYOUT="$PROJECT_ROOT/layouts/multiagent-priority.kdl"
}

@test "priority layout is not ignored by the whitelist" {
    run git -C "$PROJECT_ROOT" check-ignore -q layouts/multiagent-priority.kdl
    [ "$status" -ne 0 ]
}

@test "priority layout has the canonical ten unique agent panes" {
    run python3 - "$LAYOUT" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
names = re.findall(r'pane name="([^"]+)"', source)
expected = {"karo", "gunshi", "gunshi2", *(f"ashigaru{i}" for i in range(1, 8))}
assert len(names) == 10, names
assert set(names) == expected, names
assert len(set(names)) == len(names), names
PY
    [ "$status" -eq 0 ]
}

@test "priority layout preserves 55/45 bands with equal Ashigaru areas" {
    run python3 - "$LAYOUT" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
assert 'pane size="55%" split_direction="vertical"' in source
assert 'pane size="45%" split_direction="vertical"' in source
assert '43%' not in source
assert '57%' not in source

sizes = re.findall(r'pane size="([^\"]+)"', source)
assert all(re.fullmatch(r'[1-9][0-9]?%', size) for size in sizes), sizes
PY
    [ "$status" -eq 0 ]
}

@test "priority layout places each agent in its required parent container" {
    run python3 - "$LAYOUT" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
root = {"line": "root", "children": []}
stack = [root]
for raw in source.splitlines():
    line = raw.strip()
    if not line or line.startswith("//"):
        continue
    if line.endswith("{"):
        node = {"line": line[:-1].strip(), "children": []}
        stack[-1]["children"].append(node)
        stack.append(node)
    elif line == "}":
        stack.pop()
    elif line.startswith("pane name="):
        stack[-1]["children"].append({"line": line, "children": []})

layout = root["children"][0]
tab = layout["children"][0]
top = tab["children"][0]
assert 'split_direction="horizontal"' in top["line"]
large, small = top["children"]
assert 'size="55%"' in large["line"]
assert 'size="45%"' in small["line"]
assert 'split_direction="vertical"' in small["line"]
assert [n["line"] for n in large["children"]] == [
    'pane name="karo"', 'pane name="gunshi"', 'pane name="gunshi2"'
]
assert [n["line"] for n in small["children"]] == [
    *(f'pane name="ashigaru{i}"' for i in range(1, 8))
]
PY
    [ "$status" -eq 0 ]
}
