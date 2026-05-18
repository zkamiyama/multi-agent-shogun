# cmd_334 — PR #118 (OpenCode 対応) VPS 実機検証 + 軍師 QC

| 項目 | 値 |
|---|---|
| **作成** | 2026-05-19 05:10 JST |
| **報告者** | gunshi |
| **対象** | yohey-w/multi-agent-shogun PR #118 |
| **PR HEAD** | `738187d1ddc9bfc2769f09c0554f2bebbb1c347e` |
| **PR title** | feat: OpenCode 対応 |
| **PR 状態** | OPEN, MERGEABLE (GitHub 上), base=main |
| **規模** | +12,742 / -203 (auto-generated agent md ~8,000 行除外で実コード ~2,000 行) |
| **VPS** | Contabo 144.91.125.163 |
| **QC 判定** | **🔴 差し戻し (NEEDS_FIX)** |

---

## 0. 結論サマリー

PR #118 を VPS 上に `pull/118/head` を fresh checkout (`738187d1`) し、unit/e2e bats を実行。前回 QC 懸念 3 点は全て修正確認できたが、**新たに 2 系統 7 件の regression を検出**。merge ブロック判定。

主要 regression:

1. **`lib/cli_adapter.sh` `build_cli_command()` の二重 `echo`** (claude case のみ) — 5 件失敗
2. **`scripts/inbox_watcher.sh:589` `send_startup_prompt` が定義のないまま呼び出されている** — 2 件失敗

両方とも単純な実装ミスで修正は数行で済むが、main へ取り込めば運用中の Claude セッションの `/clear` 後挙動が壊れるため merge 前必須対応。

---

## 1. 環境

```
VPS:  Contabo 144.91.125.163, root@vps
repo: /root/multi-agent-shogun
checkout: pull/118/head → ローカル branch pr118-fresh (検証後削除)
bats: /usr/local/bin/bats
osato-lms: :3000 HTTP 200 (検証前後とも生存、無影響)
```

---

## 2. 前回 QC 懸念 3 点の修正確認

ZenkakuHiragana が rebase 完了 (HEAD: 738187d1) と申告した自主修正を全て確認した。

| # | 懸念点 | 修正状況 | 確認方法 |
|---|---|---|---|
| 1 | `.opencode/tools/mark-as-read.ts` のファイル名 (ハイフン許容) | ✅ 確認 | `ls -la .opencode/tools/mark-as-read.ts` 存在 (5892 bytes) |
| 2 | `scripts/agent_status.sh` の Python 非存在環境向け fallback | ✅ 確認 | `PYTHON_AVAILABLE=false` 経路追加、`PYTHON_AVAILABLE=true` で gate |
| 3 | `scripts/build_instructions.sh` の終了コード検証 | ✅ 確認 | `set -euo pipefail` + `opencode_build_python` で `return 1` 経路 + `python_bin=$(opencode_build_python) \|\| {...}` の失敗 trap |

→ **3 点とも問題なし**。前回指摘事項は全て解消されている。

---

## 3. PR 全体レビュー (実コード ~2,000 行)

### 3.1 構成 (60+ ファイル)

- `.opencode/agents/*.md` × 11 (auto-generated, 各 ~750-940 行) — 約 8,000 行
- `instructions/generated/opencode-*.md` × 4 — 約 3,100 行
- `.opencode/tools/mark-as-read.ts` (+184) — OpenCode 用 tool 実装
- `lib/cli_adapter.sh` (+137 -14) — CLI 抽象化への opencode 追加
- `lib/agent_status.sh` (+56 -6) — busy 検知の python fallback + OpenCode 用検知
- `scripts/build_instructions.sh` (+259) — 新規 build 系
- `scripts/inbox_watcher.sh` (+66 -27) — `send_cli_command`, `send_codex_startup_prompt` 等
- `scripts/switch_cli.sh` (+15 -3) — CLI 切替
- `scripts/ratelimit_check.sh` (+14 -1)
- `instructions/cli_specific/opencode_tools.md` (+192) — 新規 doc
- `config/opencode-permissions.yaml` (+138), `config/opencode-tui.json` (+8)
- `tests/unit/test_*.bats` × 3 — ユニット追加 (~500 行)
- `tests/e2e/e2e_opencode_startup.bats` (+107) — e2e 追加
- `tests/e2e/mock_behaviors/*` — mock 拡張

設計方針自体は妥当 (`opencode` を既存 CLI 抽象化レイヤーに追加、permission/tui 設定を file ベース化、agent md は build_instructions.sh で生成)。実装の細部に regression があるのが残念な点。

### 3.2 良かった点

- `--agent <name>` でビルド済み agent ファイルを参照する設計は副作用が少なく、Claude/Codex CLI とぶつからない
- `OPENCODE_TUI_CONFIG=$tui_config_path` をコマンドに前置することで dotfile 競合を回避する選択は堅実
- `lib/agent_status.sh` の OpenCode busy 検知パターン (sidebar/animation row) は実機ログから抽出されており precision が高そう
- `normalize_opencode_model()` で provider-qualified モデル名 (`anthropic/claude-opus-4-6` 等) に変換する処理は OpenCode の慣行に沿っており妥当
- 新規テスト 506 行はカバレッジが厚い (T-BUSY-009-015, T-COPILOT-001-002, T-CRESET-001-004 等)

---

## 4. テスト実行結果

### 4.1 unit bats (主要 4 ファイル)

```
bats tests/unit/test_build_system.bats \
     tests/unit/test_cli_adapter.bats \
     tests/unit/test_switch_cli.bats \
     tests/unit/test_send_wakeup.bats
```

- **PASS: 229**
- **FAIL: 7**

### 4.2 e2e bats (opencode 新規)

```
bats tests/e2e/e2e_opencode_startup.bats
```

- **PASS: 1 / 1** (E2E-009-A)

### 4.3 main ブランチでのベースライン比較

PR と同じ `tests/unit/test_cli_adapter.bats + test_send_wakeup.bats` を `main` (commit `6f07cb5`) で実行 → **0 失敗**。

→ 7 失敗は **PR #118 で導入された regression** で確定。

---

## 5. 検出した regression 詳細

### 5.1 [R1] `build_cli_command()` の二重 `echo` (5 件)

**ファイル**: `lib/cli_adapter.sh` line 180-

**失敗テスト**:

```
not ok 91  build_cli_command: claude + model → claude --model opus --dangerously-skip-permissions
not ok 92  build_cli_command: PERMISSION_FLAG override → claude --permission-mode auto-approved
not ok 153 build_cli_command: thinking:true → MAX_THINKING_TOKENS=0 なし
not ok 154 build_cli_command: thinking:false → MAX_THINKING_TOKENS=0 prefix
not ok 155 build_cli_command: thinking未設定 → MAX_THINKING_TOKENS=0 なし (デフォルトThinking ON)
```

**原因コード** (該当 case の echo + 関数末尾の echo の二重出力):

```bash
build_cli_command() {
    ...
    case "$cli_type" in
        claude)
            cmd="claude"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            cmd="$cmd $permission_flag"
            echo "${prefix}${cmd}"   # ← FIRST echo (claude case のみ存在)
            ;;
        codex|opencode|copilot|kimi|*)
            cmd="..."
            # echo なし
            ;;
    esac
    ...
    echo "${prefix}${cmd}"   # ← SECOND echo (関数末尾、全 case 共通)
}
```

**実際の出力 (実機証拠)**:

```
ACTUAL=[claude --model opus --dangerously-skip-permissions
claude --model opus --dangerously-skip-permissions]
```

期待は 1 行だが 2 行出力されている。`$(build_cli_command ...)` の戻り値も改行を含む文字列となり、後続の `tmux send-keys` 等で意図しない 2 重実行を引き起こす可能性あり (運用上の実害が想定される)。

**修正案 (~1 行)**: `claude)` case 内の `echo "${prefix}${cmd}"` を削除して関数末尾の echo に一本化する。あるいは `claude)` case 末尾を他 case と同様に `;;` 直前 echo なしに揃え、関数末尾の `echo "${prefix}${cmd}"` の前に `if [[ "$cli_type" == "opencode" ]]; then echo "$cmd"; else echo "${prefix}${cmd}"; fi` 等の prefix 制御を残す。

### 5.2 [R2] `send_startup_prompt` 未定義のまま呼び出し (2 件)

**ファイル**: `scripts/inbox_watcher.sh` line 589

**失敗テスト**:

```
not ok 182 T-SW-008: send_cli_command /clear uses tmux send-keys
not ok 201 T-CODEX-005: send_cli_command sends /clear as-is for claude
```

**原因コード**:

```bash
# inbox_watcher.sh 580-595
    if [[ "$actual_cmd" == "/clear" ]]; then
        LAST_CLEAR_TS=$(date +%s)
        sleep 3
        # Claude: send startup prompt so agent re-runs Session Start after /clear
        if [[ "$effective_cli" == "claude" ]]; then
            send_startup_prompt    # ← undefined function
        fi
    fi
```

**実機ログ**:

```
/root/multi-agent-shogun/scripts/inbox_watcher.sh: line 589: send_startup_prompt: command not found
```

`grep -rn "send_startup_prompt" scripts/ lib/ tests/` の結果、定義は存在せず**呼び出し 1 箇所のみ**。`send_codex_startup_prompt()` は同一ファイル line 599- に定義されているため、命名類似で関数名を誤った可能性あり。

**実害シナリオ**: 運用中 Claude セッションに `/clear` が送られた直後、`set -e` 系なら inbox_watcher 自体が落ちる。`set -e` なしでも startup prompt が送られず Claude 側で Session Start 手順が再実行されない可能性。**Codex 系 (E2E では PASS) は無影響だが、main 用途の Claude 経路で挙動が壊れる**。

**修正案 (~10-20 行)**: 2 通り。
- (A) `send_startup_prompt()` 関数を新規定義 (`send_codex_startup_prompt` の Claude 版)
- (B) 呼び出し側を既存の `send_codex_startup_prompt` に修正 (or 統合)

→ どちらが妥当かは PR 投稿者 (ZenkakuHiragana) に確認すべき。設計意図不明。

---

## 6. 安全性 / 副作用確認

- VPS `osato-lms :3000` は検証前後とも HTTP 200 (壊していない、制約遵守)
- VPS 上で `git checkout pr118-fresh` → 検証 → `git checkout main` → `git branch -D pr118-fresh` で原状復帰 (HEAD: `6f07cb5`)
- `git stash list` で `pr118-fresh-state-1779134283` が残存 (中身は pr118 ローカル変更だが repo オーナー判断で残置)
- main ブランチには一切影響なし

---

## 7. QC 判定: 差し戻し

merge ブロックの根拠:

1. `build_cli_command` の二重出力は CLI 起動時のコマンド文字列に直接影響 → 運用中の全 Claude 系エージェントが起動コマンド誤生成のリスク
2. `send_startup_prompt` 未定義は Claude `/clear` 経路で実行時エラー → Karo/Gunshi (Claude 運用) の Session Recovery が壊れる可能性

→ いずれも本番運用への直接影響。修正規模はそれぞれ ~数行で軽微、ZenkakuHiragana への差し戻しコメントで対応可能。

### 7.1 差し戻しコメント案 (家老が PR 上で投稿する想定)

```markdown
ご対応ありがとうございます。前回 QC 懸念 3 点 (mark-as-read.ts のハイフン、agent_status.sh の python fallback、build_instructions.sh の終了コード検証) は全て確認できました。

しかし、VPS で fresh checkout (738187d1) して `tests/unit/test_*.bats` を実行したところ、新たに 7 件の regression を検出しました (main では 0 失敗)。主要 2 系統:

1. `lib/cli_adapter.sh` の `build_cli_command()` `claude)` case で `echo` が二重に呼ばれており、戻り値が 2 行に分裂しています (build_cli_command 関連の 5 テスト失敗)。
2. `scripts/inbox_watcher.sh:589` で `send_startup_prompt` という未定義関数が呼ばれており、Claude の `/clear` 後経路で実行時エラーになります (T-SW-008 / T-CODEX-005 失敗)。

詳細・実機ログは別途共有する検証レポートをご確認ください。両件とも修正規模は数行で済む見込みです。修正後に再度 fresh checkout で `bats tests/unit/test_build_system.bats tests/unit/test_cli_adapter.bats tests/unit/test_switch_cli.bats tests/unit/test_send_wakeup.bats` を 0 失敗で通すことを merge 条件とさせていただきたく。
```

---

## 8. 残作業 / 次手

- 家老が PR にコメント投稿 → ZenkakuHiragana が修正 push
- 修正後再 push されたら軍師がもう一度 VPS で fresh checkout + bats 実行 → 0 失敗確認 → APPROVE
- (任意) 修正案 [R1] / [R2] についてはこの報告書 §5 に修正案を記載済み、PR 投稿者が直接採用可

---

## 9. north_star_alignment

```yaml
north_star_alignment:
  status: aligned
  reason: |
    cmd_334 は shogun OSS リポジショニング (project_shogun_repositioning) の一環として
    「Multi-CLI Orchestrator」として OpenCode を取り込むコントリビューションの取込判断。
    QC で 2 系統 7 件の regression を検出して差し戻し判定にできたことで、main の運用
    安定性 (CoDD 自律実験で家臣自律稼働中) を守れた。

  risks_to_north_star:
    - "PR 投稿者 (外部) を待つ間 OpenCode 取込が遅れる。codex/claude 並走運用の差別化
       (multi-CLI 抽象化) のロードマップ進捗に影響しうるが、main 破壊回避が優先。"
    - "main で 0 failure を確認した検証範囲は unit/test_cli_adapter + test_send_wakeup
       のみ。他 unit/e2e の baseline 比較は省略しているため、より広範な regression が
       PR に潜む可能性は残る (今回検出した 2 系統が氷山の一角の可能性)。"
```
