#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# safe_cleanup.bash — project-bounded cleanup helper for the
# stall_detector bats suites (unit + e2e).
#
# CLAUDE.md D002 forbids `rm -rf` on any path outside the project working
# tree. Both bats suites keep their scratch roots under the project-local,
# git-ignored tmp/stall_detector_tests/ tree; this helper guarantees that a
# cleanup `rm -rf` can ONLY ever touch a path inside that tree — never
# $BATS_TMPDIR, /tmp, or anywhere else.
# ═══════════════════════════════════════════════════════════════

# safe_rm_test_root <project_root> <target>
#   rm -rf <target> only when realpath(<target>) is strictly inside
#   realpath(<project_root>/tmp/stall_detector_tests). Anything else is a
#   no-op plus a stderr warning — the suite never silently deletes outside
#   its sandbox.
safe_rm_test_root() {
    local project_root="$1"
    local target="${2:-}"
    [ -n "$target" ] || return 0
    [ -e "$target" ] || return 0

    local allowed real
    allowed="$(realpath -m "$project_root/tmp/stall_detector_tests" 2>/dev/null)" || return 0
    real="$(realpath -m "$target" 2>/dev/null)" || return 0

    case "$real" in
        "$allowed"/*)
            rm -rf "$real"
            ;;
        *)
            echo "safe_rm_test_root: REFUSING rm -rf outside project tmp/ sandbox: $real" >&2
            return 1
            ;;
    esac
}
