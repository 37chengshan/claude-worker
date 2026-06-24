# Claude Worker

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

`claude-worker` 是一个 Codex 插件，将普通 Claude Code CLI 作为实施工作者，而 Codex 负责规划、调度、diff 审查、验证和最终验收。

v0.4 将前台调度实验升级为稳定的镜像槽工作流：

- 后台任务默认使用可见终端窗口
- 默认使用真正的前台交互式 Claude Code（`claude "初始提示"`，而非 `claude -p`）
- Windows 和 macOS 可见启动支持
- 兼容的 `git worktree` 模式
- 推荐 `mirrorPool` 模式进行前台工作，使用稳定可复用的槽目录
- 基于文件的简单协调机制，用于关联的并行任务
- 通过 `--settings` 注入的安全钩子、心跳和停止合约检查
- 日常操作的列表、监控、停止和清理脚本

## 解决什么问题

此插件适用于以下团队需求：

- Codex 通过委派长任务来节省 token 和注意力
- Claude Code 在真实终端中工作，而非不可见的黑盒
- 并行运行互不干扰
- 关联任务协调状态，而非变成失控的 agent 对话

工作模型很简单：

1. Codex 只读取足够的上下文来定义有明确范围的任务。
2. Codex 决定任务是单次运行、并行还是串行交接。
3. Claude Code 在自己的工作区中完成实施工作。
4. Codex 审查实际 diff 并运行最终验证。
5. Codex 要么接受结果，要么调度修正。

## v0.4 亮点

### 1. 默认可见终端

后台调度默认使用 `DisplayMode visible`。

- Windows：优先使用 `wt.exe`，回退到可见的 `powershell.exe`
- macOS：通过 `osascript` 使用 `Terminal.app`
- hidden 模式仍可显式降级使用

这让演示和实际工作中更容易信任委派过程，因为你能在普通终端窗口中看到 Claude 的进展。

### 2. 稳定的镜像槽池用于前台工作

前台调度应使用 `WorkspaceMode mirrorPool`。Claude 不会打开真正的源仓库，也不会打开随机的一次性 worktree。它打开一个稳定的槽仓库：

```text
<StateRoot>\workspaces\_mirror\<sourceKey>\slots\slot-1\repo
<StateRoot>\workspaces\_mirror\<sourceKey>\slots\slot-2\repo
```

每个槽可以被 Claude Code 信任一次，并在后续任务中复用。源仓库保持不变，Codex 审查槽的 diff。

这意味着：

- 本地 diff 更容易检查
- `check-claude-dispatch.ps1` 只报告该运行的变更
- 并行任务可以在文件所有权分离时使用不同槽
- 清理默认保留槽目录，以便复用信任

`WorkspaceMode worktree` 仍作为兼容默认值。需要原生 Git worktree 时使用它。前台委派推荐使用 `mirrorPool`。

### 3. 简单的关联任务协调

当任务相关时，Codex 可将它们放入共享批次：

```text
<StateRoot>\batches\<batchId>\
```

文件：

- `batch.json`：批次目标、运行列表、依赖关系、拥有的路径
- `runs/<runId>/status.json`：每个运行的当前状态快照
- `handoffs/<runId>/`：发送给该运行的简短交接消息

合约有意保持精简：

- 每个运行只写自己的 `status.json`
- 每个运行只写自己发送的交接
- 只有 Codex 充当调度器
- agent 同步状态，但不重新协商任务边界

## 仓库结构

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

## 前置条件

先安装并认证 Claude Code CLI：

```powershell
claude --version
```

如果输出版本号，插件即可使用。

Windows 可见模式优先使用 `wt.exe`，但不是必需的。缺少 Windows Terminal 时，插件回退到可见的 Windows PowerShell。

macOS 可见模式需要 `Terminal.app` 和 `osascript`。

## 安装

将仓库添加为 Codex 市场并安装插件：

```powershell
codex plugin marketplace add <你的 GitHub 仓库或本地路径>
codex plugin add claude-worker --marketplace claude-worker
```

使用本地目录示例：

```powershell
codex plugin marketplace add D:\work\claude-worker
codex plugin add claude-worker --marketplace claude-worker
```

然后刷新或重启 Codex 使技能可用。

## 主要脚本

### 同步助手

用于单个小型有界任务：

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\dispatch-claude.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "修复此 bug，保持变更范围小，运行相关测试，报告更改的文件。" `
  -TimeoutSeconds 7200 `
  -RetryCount 1 `
  -PermissionMode acceptEdits
```

### 后台调度

用于较长或多部分的工作：

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "在拥有的文件中实现此功能，关键里程碑后更新状态，如被阻塞则停止。" `
  -DisplayMode visible `
  -WorkspaceMode mirrorPool `
  -RunLabel "feature-api" `
  -OwnedPaths @("src/api", "tests/api") `
  -PermissionMode acceptEdits
```

关键参数：

- `DisplayMode = visible|hidden`
- `WorkspaceMode = worktree|mirrorPool`
- `MirrorPoolSize` 默认 `4`
- `MirrorSlot` 可选，例如 `slot-1`
- `MirrorRefresh = clean|incremental`
- `MergeMode = reviewOnly|applyOwnedPaths`（`reviewOnly` 是 v0.4 默认值）
- `RunLabel` / `BatchId` / `BatchGoal`
- `OwnedPaths` / `DependencyRunIds`
- `ClaudePath` / `HoldOnExit` / `ClaudeRunMode` / `DisableHooks`

### 监控运行

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\check-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -WaitSeconds 600
```

### 每 10 分钟监控一次

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\watch-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -IntervalSeconds 600
```

### 列出运行

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\list-claude-dispatch.ps1"
```

### 停止运行

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\stop-claude-dispatch.ps1" `
  -RunId "<run-id>"
```

### 清理运行

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\cleanup-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -Force
```

对于 `WorkspaceMode mirrorPool`，清理释放槽锁但默认保留槽目录。仅在确实需要删除可复用的受信槽时添加 `-RemoveMirrorSlot`。

## 批次协调示例

独立任务在所有权分离时可并行运行：

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "只处理 API 部分。" `
  -WorkspaceMode mirrorPool `
  -BatchId "feature-42" `
  -RunLabel "api" `
  -OwnedPaths @("src/api", "tests/api")

& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "只处理 UI 部分。" `
  -WorkspaceMode mirrorPool `
  -BatchId "feature-42" `
  -RunLabel "ui" `
  -OwnedPaths @("src/ui", "tests/ui")
```

## 推荐的使用规则

- 小型有界任务使用同步调度。
- 前台委派使用 `WorkspaceMode mirrorPool`。
- 保持默认 `MergeMode reviewOnly`；Codex 应在合并前审查槽 diff。
- 只在文件所有权清晰时并行化。
- 如果两个运行会触及相同文件或迁移，改用串行交接。
- 不要让子 agent 自行创造新的所有权边界。
- Codex 应始终是唯一的调度器和审查者。

## 测试

仓库包含 Pester 测试和 fake Claude 夹具。

```powershell
Invoke-Pester -Path ".\tests\claude-dispatch.tests.ps1"
```

覆盖范围包括：

- 可见和隐藏启动器构造
- Windows 路径含空格的引号处理
- 运行元数据和状态流
- 隔离的 worktree 和 mirrorPool 槽分配
- 镜像池槽分配、池满错误、释放和清理行为
- 钩子拒绝写入源仓库或其它槽
- 列表、停止和清理生命周期
- 批次协调文件创建和清理

## 设计边界

此插件有意不做的事情：

- 替代 Codex 的审查和最终验证
- 让多个 agent 自由共编同一文件
- 自动将镜像槽变更合并回源仓库
- 自动提交、推送或部署
- 将状态文件变成共享编辑层

目标不是"全自动自主集群"。目标是可控的委派——有可见性、隔离性和恰到好处的协调。

## 许可证

MIT
