# Claude Worker

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

`claude-worker` は、通常の Claude Code CLI を実装ワーカーとして扱い、Codex が計画・調整・diff レビュー・検証・最終承認を担当する Codex プラグインです。

v0.4 では、フォアグラウンド_dispatch の実験を安定したミラースロットワークフローに昇格させました：

- バックグラウンド作業でデフォルトで可視ターミナルウィンドウを使用
- デフォルトで真のフォアグラウンド対話型 Claude Code を使用（`claude "初期プロンプト"`、`claude -p` ではなく）
- Windows および macOS の可視起動サポート
- 互換性のある `git worktree` モード
- フォアグラウンド作業に `mirrorPool` モードを推奨、安定した再利用可能なスロットディレクトリを使用
- 関連する並列タスクのためのシンプルなファイルベースの調整
- `--settings` 経由で注入される安全フック・ハートビート・停止契約チェック
- 日常操作用のリスト・監視・停止・クリーンアップスクリプト

## 解決する問題

このプラグインは以下のようなチーム向けです：

- Codex が長い実装作業を委任することで token と注意を節約したい
- Claude Code が見えないブラックボックスではなく、実際のターミナルで作業してほしい
- 並列実行が互いに干渉しないようにしたい
- 関連タスクが制御不能な agent 会話にならないようにステータスを調整したい

動作モデルはシンプルです：

1. Codex は明確なスコープのタスクを定義するのに十分なコンテキストだけを読み取る
2. Codex が単一実行・並列・シリアルハンドオフのいずれかを判断
3. Claude Code が独自のワークスペースで実装作業を実行
4. Codex が実際の diff をレビューし、最終検証を実行
5. Codex が結果を受け入れるか、修正を dispatch する

## v0.4 のハイライト

### 1. デフォルトで可視ターミナル

バックグラウンド dispatch はデフォルトで `DisplayMode visible` を使用します。

- Windows：`wt.exe` を優先し、可視の `powershell.exe` にフォールバック
- macOS：`osascript` 経由で `Terminal.app` を使用
- hidden モードも明示的なダウングレードとして引き続き利用可能

デモや実際の作業中に Claude の進行状況を通常のターミナルウィンドウで確認できるため、委任を信頼しやすくなります。

### 2. フォアグラウンド作業用の安定したミラースロットプール

フォアグラウンド dispatch には `WorkspaceMode mirrorPool` を使用すべきです。Claude は実際のソースリポジトリもランダムなワンショット worktree も開きません。安定したスロットリポジトリを開きます：

```text
<StateRoot>\workspaces\_mirror\<sourceKey>\slots\slot-1\repo
<StateRoot>\workspaces\_mirror\<sourceKey>\slots\slot-2\repo
```

各スロットは Claude Code に一度信頼され、後続のタスクで再利用できます。Codex がスロットの diff をレビューする間、ソースリポジトリは変更されません。

つまり：

- ローカル diff が検査しやすくなる
- `check-claude-dispatch.ps1` はその実行の変更のみを報告
- 並列タスクはファイル所有権が分離されている場合、異なるスロットを使用可能
- クリーンアップはデフォルトでスロットディレクトリを保持し、信頼を再利用可能

`WorkspaceMode worktree` は互換性のためのデフォルトとして残ります。ネイティブ Git worktree を意図的に使用したい場合に使用してください。フォアグラウンドの委任には `mirrorPool` を推奨します。

### 3. 関連タスクのシンプルな調整

タスクが関連している場合、Codex はそれらを共有バッチに配置できます：

```text
<StateRoot>\batches\<batchId>\
```

ファイル：

- `batch.json`：バッチ目標、実行リスト、依存関係、所有パス
- `runs/<runId>/status.json`：各実行の現在のステータススナップショット
- `handoffs/<runId>/`：その実行宛ての短いハンドオフメッセージ

契約は意図的に小さく保たれています：

- 各実行は自身の `status.json` のみを書き込む
- 各実行は自身が送信するハンドオフのみを書き込む
- Codex のみがスケジューラーとして機能
- agent はステータスを同期するが、タスクの境界を再交渉しない

## リポジトリ構成

```text
marketplace.json
plugins/
  claude-worker/
    .codex-plugin/plugin.json
    skills/
      claude-worker/
        SKILL.md
        agents/openai.yaml
        scripts/
          dispatch-claude.ps1
          start-claude-dispatch.ps1
          check-claude-dispatch.ps1
          list-claude-dispatch.ps1
          stop-claude-dispatch.ps1
          cleanup-claude-dispatch.ps1
          claude-dispatch-common.ps1
tests/
  claude-dispatch.tests.ps1
  fixtures/fake-claude.ps1
```

## 前提条件

まず Claude Code CLI をインストールして認証してください：

```powershell
claude --version
```

バージョンが表示されれば、プラグインは使用可能です。

Windows の可視モードでは `wt.exe` が推奨されますが、必須ではありません。Windows Terminal がない場合、プラグインは可視の Windows PowerShell にフォールバックします。

macOS の可視モードでは `Terminal.app` と `osascript` が必要です。

## インストール

リポジトリを Codex のマーケットプレイスとして追加し、プラグインをインストールします：

```powershell
codex plugin marketplace add <GitHub リポジトリまたはローカルパス>
codex plugin add claude-worker --marketplace claude-worker
```

ローカルディレクトリの例：

```powershell
codex plugin marketplace add D:\work\claude-worker
codex plugin add claude-worker --marketplace claude-worker
```

その後、Codex をリフレッシュまたは再起動してスキルを利用可能にします。

## 主要スクリプト

### 同期ヘルパー

単一の小さな有界タスクに使用：

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\dispatch-claude.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "このバグを修正し、変更範囲を小さく保ち、関連テストを実行し、変更されたファイルを報告してください。" `
  -TimeoutSeconds 7200 `
  -RetryCount 1 `
  -PermissionMode acceptEdits
```

### バックグラウンド dispatch

長時間または複数の作業に使用：

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "所有ファイルにこの機能を実装し、重要なマイルストーン後にステータスを更新し、ブロックされたら停止してください。" `
  -DisplayMode visible `
  -WorkspaceMode mirrorPool `
  -RunLabel "feature-api" `
  -OwnedPaths @("src/api", "tests/api") `
  -PermissionMode acceptEdits
```

主要パラメータ：

- `DisplayMode = visible|hidden`
- `WorkspaceMode = worktree|mirrorPool`
- `MirrorPoolSize` デフォルト `4`
- `MirrorSlot` オプション、例：`slot-1`
- `MirrorRefresh = clean|incremental`
- `MergeMode = reviewOnly|applyOwnedPaths`（`reviewOnly` が v0.4 のデフォルト）
- `RunLabel` / `BatchId` / `BatchGoal`
- `OwnedPaths` / `DependencyRunIds`
- `ClaudePath` / `HoldOnExit` / `ClaudeRunMode` / `DisableHooks`

### 実行の監視

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\check-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -WaitSeconds 600
```

### 10 分ごとに監視

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\watch-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -IntervalSeconds 600
```

### 実行の一覧表示

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\list-claude-dispatch.ps1"
```

### 実行の停止

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\stop-claude-dispatch.ps1" `
  -RunId "<run-id>"
```

### 実行のクリーンアップ

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\cleanup-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -Force
```

`WorkspaceMode mirrorPool` の場合、クリーンアップはスロットロックを解放しますが、デフォルトでスロットディレクトリを保持します。再利用可能な信頼済みスロットを意図的に削除したい場合のみ `-RemoveMirrorSlot` を追加してください。

## バッチ調整の例

ファイル所有権が分離されていれば、独立タスクを並列実行できます：

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "API 部分のみを担当してください。" `
  -WorkspaceMode mirrorPool `
  -BatchId "feature-42" `
  -RunLabel "api" `
  -OwnedPaths @("src/api", "tests/api")

& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "UI 部分のみを担当してください。" `
  -WorkspaceMode mirrorPool `
  -BatchId "feature-42" `
  -RunLabel "ui" `
  -OwnedPaths @("src/ui", "tests/ui")
```

## 推奨される運用ルール

- 小さな有界タスクには同期 dispatch を使用。
- フォアグラウンドの委任には `WorkspaceMode mirrorPool` を使用。
- デフォルトの `MergeMode reviewOnly` を維持；Codex はマージ前にスロット diff をレビューすべき。
- ファイル所有権が明確な場合のみ並列化。
- 2 つの実行が同じファイルやマイグレーションに触れる場合は、シリアルハンドオフを使用。
- 子 agent に新しい所有権境界を独自に作成させない。
- Codex は常に唯一のスケジューラーおよびレビュアーであるべき。

## テスト

リポジトリには Pester テストと fake Claude フィクスチャが含まれています。

```powershell
Invoke-Pester -Path ".\tests\claude-dispatch.tests.ps1"
```

カバー範囲：

- 可視および隠しランチャーの構築
- スペースを含む Windows パスの引用符処理
- 実行メタデータとステータスフロー
- 隔離された worktree と mirrorPool スロット割り当て
- ミラープールスロット割り当て、プール満杯エラー、解放、クリーンアップ動作
- ソースリポジトリや他のスロットへの書き込みに対するフック拒否
- リスト・停止・クリーンアップのライフサイクル
- バッチ調整ファイルの作成とクリーンアップ

## 設計の境界

このプラグインが意図的に行わないこと：

- Codex のレビューと最終検証の置き換え
- 複数の agent が同じファイルを自由に共同編集
- ミラースロットの変更をソースリポジトリに自動マージ
- 自動コミット・プッシュ・デプロイ
- ステータスファイルを共有編集レイヤーに変換

目標は「完全自律型スウォーム」ではありません。目標は、可視性・隔离性・ちょうど十分な調整を備えた制御された委任です。

## ライセンス

MIT
