# VPS PR #118 検証記録 (cmd_334)

作成日: 2026-05-17  
最終更新: 2026-05-26
作成者: 家老 (karo)

---

## 概要

PR #118 (OpenCode 統合 by ZenkakuHiragana) の merge 加速のため、Contabo VPS (144.91.125.163) を multi-agent-shogun 検証環境として整備し、投稿者 rebase 後の regression 確認、修正再検証、VPS smoke、OpenRouter 実呼び出しまで完了した。

## 最終状態

| 項目 | 状態 |
|------|------|
| PR #118 | ✅ MERGED |
| merge 時刻 | 2026-05-21T08:33:18Z |
| PR head | `964bfd23bdfe29814ff32b26cad6af8507fee06f` |
| merge者 | `yohey-w` |
| VPS SSH | ✅ `ssh -i ~/.ssh/contabo root@144.91.125.163` 接続可 |
| VPS repo | ✅ `/root/multi-agent-shogun` |
| VPS branch/head | ✅ `main` / `bb19915` (2026-05-26 fast-forward 済み) |
| VPS toolchain | ✅ `tmux` / `opencode 1.15.6` 確認 |
| 起動手順 | ✅ `bash -n shutsujin_departure.sh` PASS、`shutsujin_departure.sh -h` PASS |
| osato-lms (:3000) | ✅ HTTP 200 維持 |

## 検証結果

- PR初回再検証では `build_cli_command()` の二重 echo と `send_startup_prompt` 未定義を検出し、PRコメントで差し戻し済み。
- 投稿者修正後、maintainer側で生成Markdown正規化と inbox lock 競合対応も確認済み。
- 最終 PR head `964bfd2` 系で、VPS上の `bats tests/unit/ --timing` は 392/392 PASS。
- OpenCode focused suite は 276/276 PASS。
- 実 `opencode run --agent` smoke は `opencode/qwen3.6-plus-free` と `openrouter/openai/gpt-4o-mini` の双方で PASS。
- 2026-05-26 のローカル再確認では、`git diff --check` PASS、関連 bats 248/248 PASS、SKIP表示なし。

## 安全確認

- VPSの `/root/multi-agent-shogun` は clean 状態から `origin/main` へ fast-forward 済み。
- `shutsujin_departure.sh -s` は既存 tmux session を撤収する実装を含むため、稼働中環境保護のため直接実行していない。
- 代替として構文・ヘルプ・tmux/opencode存在・VPS smoke 実績で「起動可能」条件を確認した。
- 大里LMSデモ環境 `http://127.0.0.1:3000/` は検証前後で HTTP 200 を維持。

## 後続

- PR #118 は完了。追加作業はなし。
- OpenCode 統合の経緯は Zenn 記事化済み: `https://zenn.dev/shio_shoppaize/articles/shogun-opencode-v5-openrouter`
