#!/usr/bin/env bash
# SessionStart hook — 起動/resume//clear/compact 全経路で Session Start 手順を確定的に注入
#
# 公式仕様 (hooks-guide.md):
#   - matcher: startup / resume / clear / compact (全 matcher で発火させる)
#   - stdout の plain text は additionalContext として Claude の context に注入される
#   - exit 0 で正常終了。失敗しても black hole にならぬよう set -e は使わず graceful degrade
#
# 本 hook の目的:
#   shutsujin_departure.sh の STEP 6.7 (起動時 inbox broadcast) 廃止 (commit 485ab9f, 2026-02-08)
#   以降、起動時に Session Start が発火せず、persona 未確立で「自己紹介して」に対し
#   全エージェントが「我は将軍」と誤認する事故が発生 (2026-04-19)。
#   SessionStart hook で確定的に Session Start 手順を注入し、/clear・compaction も同時カバーする。
#
# Note: ashigaru5(Codex CLI), ashigaru6(Codex CLI) は Claude Code hook 対象外。
# この hook は Claude Code セッションのみで発火する。
# Codex CLI 環境では TMUX_PANE が設定されても @agent_id が未設定のため
# silent exit となり、ログも残らない（正常動作）。

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

AGENT_ID=""
if [ -x "$REPO_DIR/scripts/agent_identity.sh" ]; then
    AGENT_ID=$(bash "$REPO_DIR/scripts/agent_identity.sh" 2>/dev/null || true)
fi
if [ -z "$AGENT_ID" ] && [ -n "${TMUX_PANE:-}" ]; then
    AGENT_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
fi

# @agent_id 未設定 (= multi-agent 環境外の個人 Claude Code) → silent exit で干渉せぬ
if [ -z "$AGENT_ID" ]; then
    exit 0
fi

LOG_DIR="$REPO_DIR/logs"
mkdir -p "$LOG_DIR" || true
echo "[$(date -Iseconds)] $AGENT_ID session_start_hook fired" \
    >> "$LOG_DIR/session_start_hook.log" || true

# ─── watcher_supervisor liveness check (zombie revival) ─────────────────────
# 2026-03-04 に supervisor が静かに死亡 → karo/ashigaru4 watcher 復活せず inbox
# 通知 2.5h 不達 (2026-05-13) の再発防止。heartbeat ファイルが 60 秒以上古い、
# または process 不在なら setsid で完全 detach して再起動する。
# 出力は全て log に流し stdout (Claude additionalContext) を汚さない。
ensure_watcher_supervisor() {
    local heartbeat="${REPO_DIR}/queue/supervisor.heartbeat"
    local lockfile="${REPO_DIR}/queue/supervisor.lock"
    local sup_log="${LOG_DIR}/watcher_supervisor.log"
    local now hb_age=999999 alive=0

    now=$(date +%s 2>/dev/null || echo 0)
    if [ -f "$heartbeat" ]; then
        local hb_ts
        hb_ts=$(stat -c %Y "$heartbeat" 2>/dev/null || echo 0)
        hb_age=$((now - hb_ts))
    fi
    # argv-based liveness: only match processes whose argv[0] ends with "bash"
    # AND argv[1] ends with "/watcher_supervisor.sh". This avoids false matches
    # against shells whose -c argument happens to contain the script path (e.g.
    # Bash tool wrappers in test environments).
    local pid argv0 argv1
    for pid in $(pgrep -f "watcher_supervisor.sh" 2>/dev/null); do
        [ -r "/proc/$pid/cmdline" ] || continue
        argv0=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n '1p')
        argv1=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n '2p')
        if [[ "$argv0" == *bash ]] && [[ "$argv1" == */watcher_supervisor.sh ]]; then
            alive=1
            break
        fi
    done

    # Healthy: process alive AND heartbeat fresh (or no heartbeat but process running
    # for <30s, accounting for startup before first heartbeat write)
    if [ "$alive" -eq 1 ] && [ "$hb_age" -lt 60 ]; then
        return 0
    fi

    # Unhealthy: need to (re)spawn. Serialize with flock so concurrent hooks don't race.
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true
    (
        if command -v flock >/dev/null 2>&1; then
            flock -n 9 || exit 0
        fi
        # Re-check after acquiring lock (another hook may have already revived).
        # Use argv-based filter (same rationale as outer check).
        local rcheck_pid rcheck_argv0 rcheck_argv1 rcheck_alive=0
        for rcheck_pid in $(pgrep -f "watcher_supervisor.sh" 2>/dev/null); do
            [ -r "/proc/$rcheck_pid/cmdline" ] || continue
            rcheck_argv0=$(tr '\0' '\n' < "/proc/$rcheck_pid/cmdline" 2>/dev/null | sed -n '1p')
            rcheck_argv1=$(tr '\0' '\n' < "/proc/$rcheck_pid/cmdline" 2>/dev/null | sed -n '2p')
            if [[ "$rcheck_argv0" == *bash ]] && [[ "$rcheck_argv1" == */watcher_supervisor.sh ]]; then
                rcheck_alive=1
                break
            fi
        done
        if [ "$rcheck_alive" -eq 1 ]; then
            local recheck_age=999999
            if [ -f "$heartbeat" ]; then
                recheck_age=$(( $(date +%s) - $(stat -c %Y "$heartbeat" 2>/dev/null || echo 0) ))
            fi
            [ "$recheck_age" -lt 60 ] && exit 0
            # Zombie: process exists but heartbeat stale → kill before respawn (by exact PID)
            for rcheck_pid in $(pgrep -f "watcher_supervisor.sh" 2>/dev/null); do
                [ -r "/proc/$rcheck_pid/cmdline" ] || continue
                rcheck_argv0=$(tr '\0' '\n' < "/proc/$rcheck_pid/cmdline" 2>/dev/null | sed -n '1p')
                rcheck_argv1=$(tr '\0' '\n' < "/proc/$rcheck_pid/cmdline" 2>/dev/null | sed -n '2p')
                if [[ "$rcheck_argv0" == *bash ]] && [[ "$rcheck_argv1" == */watcher_supervisor.sh ]]; then
                    kill "$rcheck_pid" 2>/dev/null || true
                fi
            done
            sleep 1
        fi
        echo "[$(date -Iseconds)] $AGENT_ID session_start_hook: spawning watcher_supervisor (alive=$alive, hb_age=${hb_age}s)" \
            >> "$sup_log" 2>&1 || true
        # setsid + nohup + </dev/null = full detach. Process survives parent shell death.
        setsid nohup bash "${REPO_DIR}/scripts/watcher_supervisor.sh" \
            >> "$sup_log" 2>&1 < /dev/null &
        disown 2>/dev/null || true
    ) 9>"$lockfile" >/dev/null 2>&1
}

ensure_watcher_supervisor

case "$AGENT_ID" in
    shogun|karo|gunshi)
        # command-layer agents: full Session Start (Step 1-5)
        cat <<EOF
**CRITICAL: Session Start 手順を最優先で実行せよ**

貴殿は **${AGENT_ID}** である。mux identity から確定的に読み出した事実であり、推測不要。

以下を順番に実行せよ (省略禁止、ユーザ応答/inbox 処理はこの後):

1. \`bash scripts/agent_identity.sh\` で自己識別を再確認
2. \`mcp__memory__read_graph\` でルール・嗜好・教訓を復元
3. (shogun のみ) \`memory/MEMORY.md\` を Read
4. \`instructions/${AGENT_ID}.md\` を最後まで必読 — persona・戦国口調・forbidden_actions 再確立 **(絶対省略禁止)**
5. \`queue/\` 配下 (tasks/, inbox/, reports/) から state 再構築

**Step 1-4 完了まで inbox 処理・ユーザ応答は禁止**。inbox{N} nudge が先に届いても無視し、persona 確立を優先せよ。

Rationale: 2026-04-18 に家老が「我は将軍」と役職誤認する persona 崩壊事例あり。
command-layer agent は persona + 戦国口調 + forbidden_actions の再確立が必須。

なお、本メッセージは SessionStart hook (scripts/session_start_hook.sh) が
mux identity を読み出して生成したものであり、推測や混同の余地はない。
EOF
        ;;
    ashigaru*)
        # worker agents: /clear Recovery (ashigaru only) 準拠の軽量手順
        cat <<EOF
**CRITICAL: Session Start 手順を最優先で実行せよ**

貴殿は **${AGENT_ID}** である。mux identity から確定的に読み出した事実。

足軽用軽量手順 (CLAUDE.md「/clear Recovery (ashigaru only)」準拠):

1. \`queue/tasks/${AGENT_ID}.yaml\` を Read
   - status=assigned かつ work → タスク実行
   - idle → 待機
   - done → 待機 (再報告禁止)
2. タスクに \`project:\` があれば \`context/{project}.md\` を Read
3. タスクに \`target_path:\` があれば対象ファイルを Read
4. Step 1-3 完了後にタスク着手

**Step 1-2 完了まで inbox 処理・ユーザ応答は禁止**。
初回起動時は CLAUDE.md 自動ロード済み、instructions/ashigaru.md の再読は不要 (コスト節約)。

本メッセージは SessionStart hook (scripts/session_start_hook.sh) が
mux identity を読み出して生成したものであり、推測や混同の余地はない。
EOF
        ;;
    *)
        cat <<EOF
**Session Start**: agent_id=${AGENT_ID}。CLAUDE.md の Session Start 手順に従い自己の instructions/*.md を読み込め。
EOF
        ;;
esac

exit 0
