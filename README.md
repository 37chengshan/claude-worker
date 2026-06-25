# Claude Worker

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

`claude-worker` is a Codex plugin that treats normal Claude Code CLI as the implementation worker while Codex stays in charge of planning, orchestration, diff review, validation, and final acceptance.

v2.0 turns the foreground dispatch experiment into a structured workflow with alignment gates, quality gates, and one-click merge:

- visible terminal windows by default for background work
- true foreground interactive Claude Code by default (`claude "initial prompt"`, not `claude -p`)
- Windows and macOS visible-launch support
- compatible `git worktree` mode for existing users
- recommended `mirrorPool` mode for foreground work, using stable reusable slot directories
- simple file-based coordination for related parallel tasks
- hook-injected safety, heartbeat, and stop-contract checks via `--settings`
- list, watch, stop, and cleanup scripts for day-to-day operations

## What It Solves

This plugin is for teams who want:

- Codex to save tokens and attention by delegating long implementation work
- Claude Code to work in a real terminal instead of an invisible black box
- parallel runs to avoid stepping on each other
- related runs to coordinate status without turning into uncontrolled agent chatter

The operating model is simple:

1. Codex reads just enough context to define a scoped task.
2. Codex decides whether the work is single-run, parallel, or serial handoff.
3. Claude Code does the implementation work in its own workspace.
4. Codex reviews the real diff and runs final validation.
5. Codex either accepts the result or dispatches a correction.

## v2.0 Highlights

### 1. Visible terminal by default

Background dispatches now default to `DisplayMode visible`.

- Windows: prefer `wt.exe` and fall back to visible `powershell.exe`
- macOS: use `Terminal.app` through `osascript`
- hidden mode still exists as an explicit downgrade

This makes delegation much easier to trust during demos and real work because you can see Claude progressing in a normal terminal window.

### 2. Stable mirror slot pool for foreground work

Foreground dispatches should use `WorkspaceMode mirrorPool`. Claude does not open the real source repo and does not open a random one-off worktree. It opens a stable slot repo such as:

```text
<StateRoot>\workspaces\_mirror\<sourceKey>\slots\slot-1\repo
<StateRoot>\workspaces\_mirror\<sourceKey>\slots\slot-2\repo
```

Each slot can be trusted once by Claude Code and reused across later tasks. The source repo stays untouched while Codex reviews the slot diff.

That means:

- run-local diffs are easier to inspect
- `check-claude-dispatch.ps1` reports only that run's changes
- parallel tasks can use different slots when their owned files are separate
- cleanup keeps slot directories by default so trust can be reused

`WorkspaceMode worktree` remains the compatibility default. Use it when you specifically want native Git worktrees. Use `mirrorPool` for visible foreground delegation.

### 3. Simple coordination for related tasks

When tasks are related, Codex can place them in a shared batch under:

```text
<StateRoot>\batches\<batchId>\
```

Files:

- `batch.json`: batch goal, runs, dependencies, owned paths
- `runs/<runId>/status.json`: each run's current status snapshot
- `handoffs/<runId>/`: short handoff messages addressed to that run

The contract is intentionally small:

- each run only writes its own `status.json`
- each run only writes handoffs it sends
- only Codex acts as the scheduler
- agents synchronize state, but do not renegotiate task boundaries

## Repository Layout

```text
marketplace.json
plugins/
  claude-worker/
    .codex-plugin/plugin.json
    skills/
      claude-worker/
        SKILL.md
        agents/openai.yaml
        codex-hooks/
          hooks.json
          README.md
        scripts/
          align-intent.ps1
          apply-dispatch.ps1
          check-claude-dispatch.ps1
          cleanup-claude-dispatch.ps1
          claude-dispatch-common.ps1
          dispatch-claude.ps1
          list-claude-dispatch.ps1
          start-claude-dispatch.ps1
          start-claude-dispatch-runner.ps1
          stop-claude-dispatch.ps1
          subscribe-dispatch-events.ps1
          update-claude-dispatch-status.ps1
          wait-for-answer.ps1
          watch-claude-dispatch.ps1
          write-claude-dispatch-handoff.ps1
          invoke-claude-dispatch-hook.ps1
tests/
  claude-dispatch.tests.ps1
  fixtures/fake-claude.ps1
```

## Prerequisites

Install and authenticate normal Claude Code CLI first:

```powershell
claude --version
```

If that prints a version, the plugin can use it.

For Windows visible mode, `wt.exe` is preferred but not required.
If Windows Terminal is missing, the plugin falls back to visible Windows PowerShell.

For macOS visible mode, `Terminal.app` and `osascript` are expected.

## Install

Add the repo as a Codex marketplace and install the plugin:

```powershell
codex plugin marketplace add <your-github-repo-or-local-path>
codex plugin add claude-worker --marketplace claude-worker
```

Example with a local checkout:

```powershell
codex plugin marketplace add D:\work\claude-worker
codex plugin add claude-worker --marketplace claude-worker
```

Then refresh or restart Codex so the skill is available.

## Main Scripts

### Synchronous helper

Use this for a single small scoped task:

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\dispatch-claude.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "Fix the bug, keep the change scoped, run the relevant tests, and report changed files." `
  -TimeoutSeconds 7200 `
  -RetryCount 1 `
  -PermissionMode acceptEdits
```

### Background dispatch

Use this for longer or multi-part work:

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "Implement the feature in the owned files, update status after key milestones, and stop if blocked." `
  -DisplayMode visible `
  -WorkspaceMode mirrorPool `
  -RunLabel "feature-api" `
  -OwnedPaths @("src/api", "tests/api") `
  -PermissionMode acceptEdits
```

Key parameters:

- `DisplayMode = visible|hidden`
- `WorkspaceMode = worktree|mirrorPool`
- `MirrorPoolSize` default `4`
- `MirrorSlot` optional, for example `slot-1`
- `MirrorRefresh = clean|incremental`
- `MergeMode = reviewOnly|applyOwnedPaths` (`reviewOnly` is the default)
- `RunLabel`
- `BatchId`
- `BatchGoal`
- `OwnedPaths`
- `DependencyRunIds`
- `ClaudePath`
- `HoldOnExit = onFailure|always|never`
- `ClaudeRunMode = interactive|print`
- `DisableHooks`

### Monitor a run

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\check-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -WaitSeconds 600
```

The check output includes:

- run status and phase
- changed files and diff stat from that run's workspace
- event tail from hooks
- final-report tail when present
- log tail for print/failure paths
- touched files since start


### Watch a run every 10 minutes

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\watch-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -IntervalSeconds 600
```

This is a local supervisor loop. It writes `monitor-summary.ndjson` under the run state directory and does not depend on ChatGPT staying active in the browser.

### List runs

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\list-claude-dispatch.ps1"
```

### Stop a run

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\stop-claude-dispatch.ps1" `
  -RunId "<run-id>"
```

### Clean up a run

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\cleanup-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -Force
```

Cleanup removes:

- run state directory
- isolated worktree and temporary branch for `WorkspaceMode worktree`
- batch `status.json` and handoff artifacts for that run

For `WorkspaceMode mirrorPool`, cleanup releases the slot lock but keeps the slot directory by default. Add `-RemoveMirrorSlot` only when you intentionally want to delete the reusable trusted slot:

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\cleanup-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -Force `
  -RemoveMirrorSlot
```

## Batch Coordination Example

Independent tasks can run in parallel if ownership is separated:

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "Work on the API slice only." `
  -WorkspaceMode mirrorPool `
  -BatchId "feature-42" `
  -BatchGoal "Ship feature 42 safely" `
  -RunLabel "api" `
  -OwnedPaths @("src/api", "tests/api")

& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "Work on the UI slice only." `
  -WorkspaceMode mirrorPool `
  -BatchId "feature-42" `
  -BatchGoal "Ship feature 42 safely" `
  -RunLabel "ui" `
  -OwnedPaths @("src/ui", "tests/ui")
```

Related tasks can also hand off through dependency status:

```powershell
& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "Prepare the shared schema change." `
  -BatchId "feature-43" `
  -RunLabel "schema" `
  -OwnedPaths @("db/migrations")

& ".\plugins\claude-worker\skills\claude-worker\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "D:\work\your-repo" `
  -Prompt "Implement the dependent API update after the schema status shows ready." `
  -BatchId "feature-43" `
  -RunLabel "api-followup" `
  -OwnedPaths @("src/api") `
  -DependencyRunIds @("schema-run-id")
```

## Recommended Operating Rules

- Use synchronous dispatch for small, well-bounded tasks.
- Use `WorkspaceMode mirrorPool` for visible foreground delegation.
- Keep the default `MergeMode reviewOnly`; Codex should review the slot diff before merging anything back.
- Only parallelize when file ownership is clean.
- If two runs would touch the same files or migration, use serial handoff instead.
- Do not let child agents invent new ownership boundaries on their own.
- Codex should remain the only scheduler and reviewer.

## Testing

The repo includes Pester tests and a fake Claude fixture.

Run the test suite:

```powershell
Invoke-Pester -Path ".\tests\claude-dispatch.tests.ps1"
```

Covered areas include:

- visible and hidden launcher construction
- Windows quoting for paths with spaces
- run metadata and status flow
- isolated worktree and mirrorPool slot attribution
- mirrorPool slot allocation, pool-full errors, release, and cleanup behavior
- hook denial for writes to the source repo or another slot
- list, stop, and cleanup lifecycle
- batch coordination file creation and cleanup

## Design Boundaries

This plugin intentionally does not:

- replace Codex review and final validation
- let multiple agents freely co-edit the same files
- automatically merge mirror slot changes back into the source repo
- automatically commit, push, or deploy
- turn status files into a shared editing layer

The goal is not “full autonomous swarm.” The goal is controlled delegation with visibility, isolation, and just enough coordination.

## License

MIT

## v2.0 Workflow

The v2.0 workflow adds structured stages from intent to merge:

### 1. Alignment

```powershell
& "scripts/align-intent.ps1" -WorkingDirectory "<repo>"
```

Creates `.dispatch/state/alignment.json` with goal, success criteria, constraints, and non-goals. Must be confirmed before dispatching.

### 2. Dispatch

Choose mode based on task complexity:

- **Sync** (`dispatch-claude.ps1`): ≤ 5 files, clear scope
- **Background** (`start-claude-dispatch.ps1`): 6-20 files or multi-module
- **Parallel**: separable OwnedPaths with no file overlap
- **Serial**: sequential dependencies via `DependencyRunIds`

### 3. Monitor

```powershell
# Real-time event stream (replaces polling)
& "scripts/subscribe-dispatch-events.ps1" -EventsPath "<stateDir>/events.ndjson"

# Check status
& "scripts/check-claude-dispatch.ps1" -RunId "<run-id>" -WaitSeconds 600
```

### 4. Review

Use the post-dispatch review checklist from SKILL.md:

- Changes within OwnedPaths
- Validation passing
- No scope creep
- Tests covering core paths

### 5. Apply

```powershell
# Preview changes
& "scripts/apply-dispatch.ps1" -RunId "<run-id>" -DryRun

# Apply and commit
& "scripts/apply-dispatch.ps1" -RunId "<run-id>"
```

### Quality Gate

Configure validation commands that run before the Stop hook allows exit:

```powershell
& "scripts/start-claude-dispatch.ps1" `
  -WorkingDirectory "<repo>" `
  -Prompt "<task>" `
  -QualityGateCommands @("npm test", "pnpm tsc --noEmit")
```

### Dispatch History

Every completed dispatch appends to `.dispatch/dispatch-log.ndjson` during cleanup.
