#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOGUN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PER_FILE_LIMIT="${PROJECT_INSTRUCTION_GATE_PER_FILE_LIMIT:-32768}"
TOTAL_LIMIT="${PROJECT_INSTRUCTION_GATE_TOTAL_LIMIT:-65536}"

TASK_FILE=""
PROJECT_ID=""
TARGET_PATH=""
FORMAT="yaml"

usage() {
    cat <<'EOF'
Usage:
  project_instruction_gate.sh --task queue/tasks/ashigaruN.yaml [--format yaml|json]
  project_instruction_gate.sh --project PROJECT --target-path PATH [--format yaml|json]

Read-only target project root instruction discovery helper.
EOF
}

die() {
    echo "error: $*" >&2
    exit 64
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --task)
            [ "$#" -ge 2 ] || die "--task requires a path"
            TASK_FILE="$2"
            shift 2
            ;;
        --project)
            [ "$#" -ge 2 ] || die "--project requires an id"
            PROJECT_ID="$2"
            shift 2
            ;;
        --target-path)
            [ "$#" -ge 2 ] || die "--target-path requires a path"
            TARGET_PATH="$2"
            shift 2
            ;;
        --format)
            [ "$#" -ge 2 ] || die "--format requires yaml or json"
            FORMAT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[ "$FORMAT" = "yaml" ] || [ "$FORMAT" = "json" ] || die "--format must be yaml or json"

yaml_scalar() {
    local file="$1"
    local key="$2"
    awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
            sub("^[[:space:]]*" key ":[[:space:]]*", "", $0)
            sub(/[[:space:]]+#.*$/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if (($0 ~ /^".*"$/) || ($0 ~ /^'\''.*'\''$/)) {
                $0 = substr($0, 2, length($0) - 2)
            }
            print
            exit
        }
    ' "$file"
}

config_project_path() {
    local id="$1"
    local file="$SHOGUN_ROOT/config/projects.yaml"
    [ -f "$file" ] || return 0
    awk -v target="$id" '
        /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
            in_project = 0
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", line)
            gsub(/^"|"$/, "", line)
            if (line == target) in_project = 1
        }
        in_project && /^[[:space:]]*(path|root|working_directory):[[:space:]]*/ {
            sub(/^[[:space:]]*(path|root|working_directory):[[:space:]]*/, "", $0)
            gsub(/^"|"$/, "", $0)
            print
            exit
        }
    ' "$file"
}

json_string() {
    python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

yaml_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

is_relative_path() {
    case "$1" in
        /*) return 1 ;;
        *) return 0 ;;
    esac
}

nearest_git_root() {
    local start="$1"
    local dir="$start"
    while [ "$dir" != "/" ]; do
        if [ -e "$dir/.git" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

realpath_m() {
    realpath -m "$1"
}

if [ -n "$TASK_FILE" ]; then
    [ -f "$TASK_FILE" ] || die "task file not found: $TASK_FILE"
    PROJECT_ID="${PROJECT_ID:-$(yaml_scalar "$TASK_FILE" project)}"
    TARGET_PATH="${TARGET_PATH:-$(yaml_scalar "$TASK_FILE" target_path)}"
fi

project_root_candidate=""
resolution_source=""

if [ -n "$PROJECT_ID" ] && [ -f "$SHOGUN_ROOT/projects/$PROJECT_ID.yaml" ]; then
    project_root_candidate="$(yaml_scalar "$SHOGUN_ROOT/projects/$PROJECT_ID.yaml" path)"
    [ -n "$project_root_candidate" ] || project_root_candidate="$(yaml_scalar "$SHOGUN_ROOT/projects/$PROJECT_ID.yaml" working_directory)"
    [ -n "$project_root_candidate" ] || project_root_candidate="$(yaml_scalar "$SHOGUN_ROOT/projects/$PROJECT_ID.yaml" root)"
    [ -n "$project_root_candidate" ] && resolution_source="projects/$PROJECT_ID.yaml"
fi

if [ -z "$project_root_candidate" ] && [ -n "$PROJECT_ID" ]; then
    project_root_candidate="$(config_project_path "$PROJECT_ID")"
    [ -n "$project_root_candidate" ] && resolution_source="config/projects.yaml"
fi

blocked_reason=""
resolved_root=""

if [ -n "$project_root_candidate" ]; then
    if is_relative_path "$project_root_candidate"; then
        resolved_root="$(realpath_m "$SHOGUN_ROOT/$project_root_candidate")"
    else
        resolved_root="$(realpath_m "$project_root_candidate")"
    fi
else
    if [ -z "$TARGET_PATH" ]; then
        blocked_reason="missing_target_path_and_project_root"
    elif is_relative_path "$TARGET_PATH" && [ "$PROJECT_ID" != "$(basename "$SHOGUN_ROOT")" ]; then
        blocked_reason="relative_external_target_path_without_project_root"
    else
        if is_relative_path "$TARGET_PATH"; then
            target_abs="$(realpath_m "$SHOGUN_ROOT/$TARGET_PATH")"
            resolution_source="target_path_relative_to_shogun_root"
        else
            target_abs="$(realpath_m "$TARGET_PATH")"
            resolution_source="target_path_absolute"
        fi

        if [ -d "$target_abs" ]; then
            target_dir="$target_abs"
        else
            target_dir="$(dirname "$target_abs")"
        fi

        if git_root="$(nearest_git_root "$target_dir")"; then
            resolved_root="$git_root"
            resolution_source="${resolution_source}:nearest_git"
        else
            resolved_root="$target_dir"
        fi
    fi
fi

files_read=()
files_missing=()
files_suppressed=()
manifests=()
file_paths=()
file_bytes=()
file_truncated=()
file_contents=()
external_imports=()
total_bytes=0
truncated_any=false
status="read"

block() {
    status="blocked"
    blocked_reason="$1"
}

read_instruction_file() {
    local rel="$1"
    local path="$resolved_root/$rel"
    local bytes available take truncated content

    if [ ! -e "$path" ]; then
        files_missing+=("$rel")
        return 0
    fi
    if [ ! -f "$path" ]; then
        block "not_a_regular_file:$rel"
        return 1
    fi
    if [ ! -r "$path" ]; then
        block "unreadable:$rel"
        return 1
    fi
    if ! LC_ALL=C grep -Iq . "$path"; then
        block "binary_file:$rel"
        return 1
    fi

    bytes="$(wc -c < "$path" | tr -d ' ')"
    available=$((TOTAL_LIMIT - total_bytes))
    if [ "$available" -le 0 ]; then
        take=0
    elif [ "$bytes" -gt "$PER_FILE_LIMIT" ]; then
        take="$PER_FILE_LIMIT"
    else
        take="$bytes"
    fi
    if [ "$take" -gt "$available" ]; then
        take="$available"
    fi

    truncated=false
    if [ "$take" -lt "$bytes" ]; then
        truncated=true
        truncated_any=true
    fi

    content="$(head -c "$take" "$path")"
    while IFS= read -r import_line; do
        external_imports+=("$rel:$import_line")
    done < <(printf '%s\n' "$content" | grep -E '(^|[[:space:]])@[./~]' || true)

    files_read+=("$rel")
    file_paths+=("$path")
    file_bytes+=("$take")
    file_truncated+=("$truncated")
    file_contents+=("$content")
    total_bytes=$((total_bytes + take))
}

list_manifest_dir() {
    local rel="$1"
    local dir="$resolved_root/$rel"
    local item name
    [ -d "$dir" ] || return 0
    while IFS= read -r item; do
        name="${item#"$resolved_root/"}"
        manifests+=("$name")
    done < <(find "$dir" -maxdepth 1 -type f | sort)
}

if [ -n "$blocked_reason" ]; then
    status="blocked"
elif [ ! -d "$resolved_root" ]; then
    status="blocked"
    blocked_reason="resolved_root_not_directory:$resolved_root"
else
    resolved_root="$(realpath_m "$resolved_root")"

    if [ -f "$resolved_root/AGENTS.override.md" ]; then
        read_instruction_file "AGENTS.override.md" || true
        if [ -f "$resolved_root/AGENTS.md" ]; then
            files_suppressed+=("AGENTS.md:AGENTS.override.md")
        else
            files_missing+=("AGENTS.md")
        fi
    else
        files_missing+=("AGENTS.override.md")
        read_instruction_file "AGENTS.md" || true
    fi

    if [ "$status" != "blocked" ]; then
        read_instruction_file "CLAUDE.md" || true
    fi
    if [ "$status" != "blocked" ]; then
        read_instruction_file ".claude/CLAUDE.md" || true
    fi
    if [ "$status" != "blocked" ]; then
        read_instruction_file ".github/copilot-instructions.md" || true
    fi
    if [ "$status" != "blocked" ]; then
        list_manifest_dir ".cursor/rules"
        list_manifest_dir ".opencode/agents"
    fi
fi

if [ "$status" != "blocked" ] && [ "${#files_read[@]}" -eq 0 ]; then
    status="none_found"
fi

emit_yaml_list() {
    local name="$1"
    local indent
    shift
    if [ "$#" -eq 0 ]; then
        echo "$name: []"
        return 0
    fi
    indent="$(printf '%s' "$name" | sed 's/[^ ].*$//')"
    echo "$name:"
    local item
    for item in "$@"; do
        printf '%s  - %s\n' "$indent" "$(yaml_quote "$item")"
    done
}

emit_yaml() {
    echo "root_instruction_gate:"
    printf '  status: %s\n' "$(yaml_quote "$status")"
    printf '  project: %s\n' "$(yaml_quote "$PROJECT_ID")"
    printf '  target_path: %s\n' "$(yaml_quote "$TARGET_PATH")"
    printf '  resolved_root: %s\n' "$(yaml_quote "$resolved_root")"
    printf '  resolution_source: %s\n' "$(yaml_quote "$resolution_source")"
    printf '  per_file_limit: %s\n' "$PER_FILE_LIMIT"
    printf '  total_limit: %s\n' "$TOTAL_LIMIT"
    printf '  total_bytes_read: %s\n' "$total_bytes"
    printf '  truncated: %s\n' "$truncated_any"
    [ -n "$blocked_reason" ] && printf '  blocked_reason: %s\n' "$(yaml_quote "$blocked_reason")"
    emit_yaml_list "  files_missing" "${files_missing[@]}"
    emit_yaml_list "  files_suppressed" "${files_suppressed[@]}"
    emit_yaml_list "  manifests" "${manifests[@]}"
    emit_yaml_list "  external_imports_detected" "${external_imports[@]}"
    echo "  files_read:"
    if [ "${#files_read[@]}" -eq 0 ]; then
        echo "    []"
    else
        local i line
        for i in "${!files_read[@]}"; do
            printf '    - path: %s\n' "$(yaml_quote "${files_read[$i]}")"
            printf '      absolute_path: %s\n' "$(yaml_quote "${file_paths[$i]}")"
            printf '      bytes_read: %s\n' "${file_bytes[$i]}"
            printf '      truncated: %s\n' "${file_truncated[$i]}"
            echo "      content: |"
            while IFS= read -r line || [ -n "$line" ]; do
                printf '        %s\n' "$line"
            done <<< "${file_contents[$i]}"
        done
    fi
}

emit_json() {
    printf '{'
    printf '"status":%s,' "$(printf '%s' "$status" | json_string)"
    printf '"project":%s,' "$(printf '%s' "$PROJECT_ID" | json_string)"
    printf '"target_path":%s,' "$(printf '%s' "$TARGET_PATH" | json_string)"
    printf '"resolved_root":%s,' "$(printf '%s' "$resolved_root" | json_string)"
    printf '"resolution_source":%s,' "$(printf '%s' "$resolution_source" | json_string)"
    printf '"per_file_limit":%s,' "$PER_FILE_LIMIT"
    printf '"total_limit":%s,' "$TOTAL_LIMIT"
    printf '"total_bytes_read":%s,' "$total_bytes"
    printf '"truncated":%s,' "$truncated_any"
    printf '"blocked_reason":%s,' "$(printf '%s' "$blocked_reason" | json_string)"
    printf '"files_read":['
    local i
    for i in "${!files_read[@]}"; do
        [ "$i" -gt 0 ] && printf ','
        printf '{"path":%s,"absolute_path":%s,"bytes_read":%s,"truncated":%s,"content":%s}' \
            "$(printf '%s' "${files_read[$i]}" | json_string)" \
            "$(printf '%s' "${file_paths[$i]}" | json_string)" \
            "${file_bytes[$i]}" \
            "${file_truncated[$i]}" \
            "$(printf '%s' "${file_contents[$i]}" | json_string)"
    done
    printf ']}'
    printf '\n'
}

if [ "$FORMAT" = "json" ]; then
    emit_json
else
    emit_yaml
fi

[ "$status" != "blocked" ]
