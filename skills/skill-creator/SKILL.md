---
name: skill-creator
description: |
  Claude Codeスキル（SKILL.md）の設計・作成・バリデーション。
  新しいスキルの作成、既存スキルの改善、スキル設計レビューに使用。
  「スキル作って」「スキル設計」「SKILL.md作成」で起動。
argument-hint: "[skill-name or description]"
---

# Skill Creator — Claude Code Skills Design & Generation

## Overview

Claude Code公式仕様（2026-02最新）に準拠したスキルを設計・作成する。
作成するスキルは Agent Skills Open Standard (agentskills.io) にも準拠し、
Claude Code以外のAIツール（Cursor, Codex CLI等）でも動作する。

## Frontmatter Reference（全フィールド）

```yaml
---
name: skill-name              # kebab-case, max 64 chars. 省略時はディレクトリ名
description: |                 # 【最重要】Claudeがいつ発火するか判断する唯一の材料
  What + When を明記。トリガーワードを含める。
argument-hint: "[target]"      # 補完時のヒント表示。引数ありスキル用
disable-model-invocation: false # true = 手動 /name でのみ起動（副作用あるスキル向け）
user-invocable: true           # false = /メニュー非表示（背景知識スキル向け）
allowed-tools: Read, Grep, Bash # 許可ツール。指定すると制限にもなる。省略=全ツール継承
model: sonnet                  # スキル実行時のモデル指定（省略=親から継承）
context: fork                  # fork = サブエージェントで隔離実行
agent: general-purpose         # fork時のエージェント種別: Explore, Plan, general-purpose
hooks:                         # スキル内フック定義
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "./scripts/lint.sh"
---
```

## Description設計（最重要 — 発火品質を決める）

descriptionはClaude Codeが「このスキルを使うか否か」を判断する**唯一の材料**。
本文は発火判定に使われない。

### 7項目チェックリスト

| # | チェック | 悪い例 | 良い例 |
|---|---------|-------|-------|
| 1 | What: 何をするか明記 | "ドキュメント処理" | "PDFからテーブルを抽出しCSVに変換" |
| 2 | When: いつ使うか明記 | (なし) | "データ分析ワークフローで使用" |
| 3 | トリガーワード含有 | (なし) | "「記事QC」「バリデーション」で起動" |
| 4 | 具体的なアクション動詞 | "管理する" | "抽出・変換・検証する" |
| 5 | 長さ: 1-3文（50-200文字） | 1単語 | 2文で概要+トリガー |
| 6 | 既存スキルと差別化 | 他スキルと被る | 独自の守備範囲を明示 |
| 7 | 角括弧 [] を使わない | "[PDF]を処理" | "PDFを処理" |

## Dynamic Features（動的機能）

### 引数置換

スキル呼び出し時の引数を動的に埋め込む：

```
/my-skill 結婚 kekkon
```
- `$ARGUMENTS` → `結婚 kekkon`（全引数）
- `$0` → `結婚`（第1引数）
- `$1` → `kekkon`（第2引数）

`$ARGUMENTS` を本文で使わない場合、末尾に自動追加される。

### 動的コンテキスト `!`command``

スキル読み込み前にシェルコマンドを実行し、結果を埋め込む：

```markdown
## 現在のブランチ
!`git branch --show-current`

## 最近のコミット
!`git log --oneline -5`
```

**用途**: GSCデータ取得、ファイル一覧、環境変数、API応答の事前取得。

## Execution Patterns（実行パターン）

### Pattern A: インライン実行（デフォルト）

メイン会話内で直接実行。ガイドライン型・短いタスク向け。

```yaml
---
name: coding-standards
description: コーディング規約参照。コードレビューや新規実装時に自動適用。
user-invocable: false  # 背景知識として自動ロード
---
```

### Pattern B: Fork実行（隔離）

サブエージェントで隔離実行。重い処理・大量出力向け。

```yaml
---
name: deep-research
description: 指定トピックの網羅的リサーチ。Web検索・X検索を駆使して調査レポート作成。
context: fork
agent: general-purpose
allowed-tools: Read, Grep, Glob, Bash, WebSearch, WebFetch
---
```

**注意**: `context: fork` はガイドラインだけのスキルに使うな。
サブエージェントには明確なタスクが必要。

### Pattern C: 手動専用（副作用あり）

デプロイ・送信など副作用があるスキル。Claudeの自動発火を禁止。

```yaml
---
name: deploy
description: 本番環境にデプロイ。
disable-model-invocation: true  # /deploy でのみ起動
---
```

## File Structure（ファイル構成）

```
~/.claude/skills/skill-name/
├── SKILL.md              # 必須。500行以内。
├── reference.md          # 任意。詳細なAPI仕様・ルール集。
├── examples/             # 任意。入出力サンプル。
└── scripts/              # 任意。実行スクリプト。
```

**Progressive Disclosure**: SKILL.md本体は500行以内。
詳細はreference.md等に分離し、Claude が必要時に参照する。

## Creation Checklist（作成時チェックリスト）

スキル作成時、以下を順に確認：

1. **description**: 7項目チェック通過するか
2. **既存スキルとの重複**: `ls ~/.claude/skills/` で確認
3. **実行パターン選択**: インライン / fork / 手動専用
4. **allowed-tools**: 必要最小限に制限するか、全ツール許可か
5. **引数設計**: `$0`, `$1` 等の引数を使うか → `argument-hint` 記載
6. **動的コンテキスト**: `!`command`` で事前取得すべきデータはあるか
7. **500行制限**: 本体が長すぎないか → reference.md分離
8. **テスト**: `/skill-name test-arg` で実際に動くか

## 将軍システム固有ルール

- 保存先: `~/.claude/skills/shogun-{skill-name}/`
- スキル候補は足軽が発見 → 家老経由で将軍に報告 → 将軍が設計 → 殿が承認 → 家老が作成
- 将軍システム連携（inbox_write, task YAML等）が必要なスキルは allowed-tools に Bash を含めよ
- north_star はフロントマターでなく**本文に記載**（フロントマターのカスタムフィールドはClaude Codeに無視される）

## Anti-Patterns（やってはいけないこと）

| NG | 理由 | 代わりに |
|----|------|---------|
| SKILL.md 1000行超 | 読み込みコスト爆増 | reference.md に分離 |
| description が曖昧 | 発火しない or 誤発火 | What + When + トリガーワード |
| `context: fork` + ガイドラインのみ | サブエージェントがタスク不明で迷走 | インライン or subagent の skills: で参照 |
| `disable-model-invocation` + `user-invocable: false` | 誰も起動できない | どちらか片方だけ |
| allowed-tools 未指定で重い処理 | 意図しないツール使用 | 必要なツールのみ列挙 |
| フロントマターに独自フィールド追加 | Claude Codeに無視される | 本文のMarkdownに記載 |
