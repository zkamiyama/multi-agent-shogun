# 将軍Android

将軍マルチエージェントシステム専用Androidアプリ（MVP版）

## 概要

スマホからSSH経由でWSL2上の将軍システムを操作するAndroidアプリ。

## 機能

### 3画面タブ構成

| 画面 | 機能 |
|------|------|
| 将軍 | tmux capture-pane で将軍ペインを3秒ごと自動リフレッシュ。テキスト/音声入力 → send-keys |
| エージェント | 8ペインを2列グリッド表示。20秒ごと自動更新。タップで拡大 + コマンド送信 |
| ダッシュボード | dashboard.md をMarkdownレンダリング表示。プルダウン更新 |

### 設定（設定タブ）

SharedPreferencesで永続化:
- SSH host / port / user / 秘密鍵パス
- tmuxセッション名（将軍 / エージェント）

## 技術スタック

- Kotlin + Jetpack Compose
- SSH: JSch 0.1.55
- Markdown: Markwon 4.6.2
- 音声: Android SpeechRecognizer API
- Min API: 26 (Android 8.0) / Target: 34

## ビルド

```bash
./gradlew assembleDebug
```

## セットアップ

1. アプリ起動 → 設定タブでSSH情報を入力・保存
2. 将軍タブに戻ると自動接続開始
3. WSL2側でSSHサーバー起動が必要:
   ```bash
   sudo service ssh start
   ```
