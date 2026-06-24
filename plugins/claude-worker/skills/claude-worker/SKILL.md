---
name: claude-worker
description: Use this skill for non-trivial coding tasks when the user wants Codex to save context by delegating implementation to normal Claude Code CLI. Codex should plan briefly, choose sync or visible background dispatch, keep runs isolated, coordinate related tasks through batch status files, review the actual diff, request fixes when needed, run validation, and only accept passing work.
---

# Claude Worker

Use normal Claude Code CLI like a human would from the terminal, but keep Codex as the controller.

## What Changed In v0.4

- background dispatch now defaults to visible terminals
- visible interactive mode now starts real foreground Claude with `claude "initial prompt"`, not print mode
- Windows visible mode prefers `wt.exe` and falls back to visible `powershell.exe`
- macOS visible mode uses `Terminal.app` through `osascript`
- `WorkspaceMode worktree` remains available for compatibility
- visible foreground work should use `WorkspaceMode mirrorPool` with stable reusable mirror slots
- parallel foreground runs occupy different slots in the same source repo pool
- mirrorPool defaults to review-only merge; Codex reviews slot diffs before applying anything to the real repo
- related runs can coordinate through simple batch files outside the Git repo
- per-run `--settings` injects hooks for PreToolUse, PostToolUse, Stop, UserPromptSubmit, and optional MessageDisplay logging
- helper scripts now cover start, check, list, stop, and cleanup

## Core Principle

Claude Code is the implementation worker.
Codex is still responsible for:

- scoping the task
- deciding whether work can run in parallel
- reviewing the real diff
- running final validation
- accepting or rejecting the outcome

Do not trust a worker summary without inspecting the actual result.

## Workflow

1. Codex reads only enough context to define a clear scoped task.
2. Codex decides whether the work should be:
   - synchronous and single-scope
   - background and independent
   - background with batch coordination
   - serial handoff instead of parallel work
3. Codex dispatches Claude Code with one prompt per owned scope.
4. Each foreground background run works in an isolated workspace. Prefer stable mirrorPool slots for visible interactive dispatch; use worktrees when specifically needed.
5. Codex monitors active runs, reviews the real diff, and runs final validation.
6. If the result is flawed, Codex sends a correction run with concrete feedback.
7. Stop after 3 failed review rounds on the same scope and ask the user for direction.

## When To Use Sync vs Background

Use the synchronous helper for:

- one small task
- tight scope
- quick expected turnaround
- no need for a visible separate terminal

Use background dispatch for:

- long-running implementation
- multiple independent scopes
- any case where user visibility matters
- any case where Codex should stay responsive while workers run

Default for background work is:

- `DisplayMode = visible`
- for foreground experiments, `WorkspaceMode = mirrorPool`
- `HoldOnExit = onFailure`

## Dispatch Rules

### Small single-scope task

```powershell
& "<skill_dir>\scripts\dispatch-claude.ps1" `
  -WorkingDirectory "<repo>" `
  -Prompt "<task prompt>" `
  -TimeoutSeconds 7200 `
  -RetryCount 1 `
  -PermissionMode acceptEdits
```

### Background task

```powershell
& "<skill_dir>\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "<repo>" `
  -Prompt "<task prompt>" `
  -DisplayMode visible `
  -WorkspaceMode mirrorPool `
  -RunLabel "<label>" `
  -PermissionMode acceptEdits
```

### Related background task with coordination

```powershell
& "<skill_dir>\scripts\start-claude-dispatch.ps1" `
  -WorkingDirectory "<repo>" `
  -Prompt "<task prompt>" `
  -DisplayMode visible `
  -WorkspaceMode mirrorPool `
  -BatchId "<batch-id>" `
  -BatchGoal "<goal>" `
  -RunLabel "<label>" `
  -OwnedPaths @("path/a", "path/b") `
  -DependencyRunIds @("<run-id>")
```

## Background Parameters

Use these parameters deliberately:

- `DisplayMode = visible|hidden`
- `WorkspaceMode = worktree|mirrorPool`
- `MirrorPoolSize` default `4`
- `MirrorSlot` optional
- `MirrorRefresh = clean|incremental`
- `MergeMode = reviewOnly|applyOwnedPaths`
- `RunLabel`
- `BatchId`
- `BatchGoal`
- `OwnedPaths`
- `DependencyRunIds`
- `ClaudePath`
- `HoldOnExit = onFailure|always|never`
- `ClaudeRunMode = interactive|print`
- `DisableHooks`

Guidance:

- keep `hidden` as an explicit downgrade, not the default
- use `mirrorPool` when the user wants to watch foreground Claude work in a stable trusted directory
- keep `MergeMode reviewOnly` unless the user explicitly asks for controlled apply-back behavior
- set `RunLabel` to something user-readable
- use `OwnedPaths` whenever parallel runs touch different areas
- use `DependencyRunIds` for related work that must observe upstream progress
- use `HoldOnExit always` when you want the visible window to stay open for inspection

## Mirror Pool Rules

`mirrorPool` is the recommended foreground mode.

- Claude opens `<StateRoot>/workspaces/_mirror/<sourceKey>/slots/<slot>/repo`, not the real source repo.
- Each active run owns exactly one slot.
- A slot cannot be started twice while active.
- Different slots can run in parallel when owned paths do not overlap.
- `MirrorPoolSize` defaults to `4`; if the pool is full, stop a run or increase the pool size.
- Cleanup releases the slot lock but keeps the slot directory by default so Claude trust can be reused.
- Use `cleanup-claude-dispatch.ps1 -RemoveMirrorSlot` only when you intentionally want to delete that reusable slot.
- `bypassPermissions` is only reasonable inside `mirrorPool`, and even then it protects the real repo, not the slot repo.

v0.4 does not automatically merge slot changes back into the source repo. Codex must inspect the slot diff and decide what to apply.

## Parallelization Rules

Parallelize only when ownership is clean.

Good candidates:

- different packages
- different directories
- different tests for different features

Do not parallelize:

- overlapping file ownership
- shared migrations
- broad refactors
- work that needs one ordered diff

If two scopes would touch the same file or same migration path, switch to serial handoff.

## Batch Coordination Contract

Batch state lives outside the repo under:

```text
<StateRoot>\batches\<batchId>\
```

Files:

- `batch.json`
- `runs/<runId>/status.json`
- `handoffs/<toRunId>/...`

Worker contract:

- read `batch.json` before starting related work
- read dependency `status.json` files before crossing a dependency edge
- update only your own `status.json`
- send short handoff notes only under the destination handoff directory
- never rewrite another run's prompt or status
- if ownership boundaries become unclear, stop and record the blocker

Scheduler contract:

- Codex is the only scheduler
- Codex decides whether to re-split, retry, serialize, or stop a run
- workers do not renegotiate task boundaries among themselves

## Monitoring

Check a run:

```powershell
& "<skill_dir>\scripts\check-claude-dispatch.ps1" `
  -RunId "<run-id>" `
  -WaitSeconds 600
```

List all runs:

```powershell
& "<skill_dir>\scripts\list-claude-dispatch.ps1"
```

Stop a run:

```powershell
& "<skill_dir>\scripts\stop-claude-dispatch.ps1" -RunId "<run-id>"
```

Clean up a run:

```powershell
& "<skill_dir>\scripts\cleanup-claude-dispatch.ps1" -RunId "<run-id>" -Force
```

Remove a reusable mirror slot only when needed:

```powershell
& "<skill_dir>\scripts\cleanup-claude-dispatch.ps1" -RunId "<run-id>" -Force -RemoveMirrorSlot
```

`check-claude-dispatch.ps1` reports that run's own workspace status, not the source repo's global dirty state.

## Waiting Rules

- do not block the whole session behind one silent long-running dispatch
- for long background runs, use `watch-claude-dispatch.ps1` or call `check-claude-dispatch.ps1 -WaitSeconds 600` roughly every 10 minutes
- after each check, give the user a brief update on progress, changes, and blockers
- if a run stops making progress across multiple checks, inspect the diff and narrow the next prompt

## Prompt Contract

Keep prompts short but specific. Include:

- what to change
- relevant files or owned paths
- acceptance criteria
- keep changes scoped
- follow existing patterns
- run relevant validation
- do not commit, push, or deploy
- report changed files and validation result
- keep working until complete or blocked

For batch runs, assume the coordination preamble from `start-claude-dispatch.ps1` will be injected automatically.

## Review Rules

After a worker finishes, Codex must:

1. inspect the real diff in the run workspace
2. look for logic bugs, scope creep, unrelated edits, and missing tests
3. run final validation itself or trigger the right validation command
4. accept only if the result actually passes

Reject and re-dispatch if you find:

- failed tests
- missing validation
- broad unrelated churn
- missing error handling
- unsafe ownership crossover
- broken or misleading status reporting

Codex may edit directly only for:

- tiny mechanical fixes
- final integration
- small follow-up cleanup
- explicit user requests for Codex to take over
