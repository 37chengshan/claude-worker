---
name: claude-worker
description: >
  Skill component of the claude-worker Codex plugin.
  Use this skill for non-trivial coding tasks when the user wants Codex to save context by delegating implementation to normal Claude Code CLI.
  This skill is part of the claude-worker plugin — install via the plugin marketplace, not as a standalone skill.
  Codex should run align-intent first, choose dispatch mode using the decision tree, dispatch with appropriate parameters, monitor via events, review against the checklist, run quality gates, apply accepted changes, and only accept passing work.
---

# Claude Worker

Use normal Claude Code CLI like a human would from the terminal, but keep Codex as the controller.

## What Changed In v2.0

- **Alignment gate**: `$align-intent` creates `alignment.json` that gates dispatch until intent is confirmed
- **Task decomposition decision tree**: structured guidance for choosing sync vs background vs parallel dispatch
- **Prompt templates**: standardized templates for bug fix, new feature, refactor, and test addition tasks
- **Q&A protocol**: workers can ask structured questions during execution; Codex answers via file exchange
- **Event-driven monitoring**: FileSystemWatcher replaces polling loops in runner and event subscription
- **Quality gate**: configurable validation commands run before Stop hook allows exit
- **One-click apply**: `apply-dispatch.ps1` applies slot diffs back to source repo with commit
- **Dispatch log**: `dispatch-log.ndjson` records every dispatch outcome for historical reference
- **Post-dispatch review checklist**: structured checklist for Codex review after worker completes
- background dispatch defaults to visible terminals
- visible interactive mode starts real foreground Claude with `claude "initial prompt"`
- Windows visible mode prefers `wt.exe` and falls back to visible `powershell.exe`
- macOS visible mode uses `Terminal.app` through `osascript`
- `WorkspaceMode mirrorPool` is the recommended foreground mode
- per-run `--settings` injects hooks for PreToolUse, PostToolUse, Stop, UserPromptSubmit, and MessageDisplay

## Core Principle

Claude Code is the implementation worker.
Codex is still responsible for:

- scoping the task
- deciding whether work can run in parallel
- reviewing the real diff
- running final validation
- accepting or rejecting the outcome

Do not trust a worker summary without inspecting the actual result.

## Alignment Gate

Before dispatching any task, Codex should ensure intent alignment with the user through the alignment gate system.

### Trigger

Run `$align-intent` (or the `align-intent.ps1` script) before the first dispatch of a session or when the user changes direction:

```powershell
& "<skill_dir>\scripts\align-intent.ps1" -WorkingDirectory "<repo>"
```

This creates `.dispatch/state/alignment.json` with status, goal, success criteria, constraints, and non-goals.

### Codex-side Hooks (`.codex/hooks.json`)

Three hooks enforce the alignment gate:

1. **UserPromptSubmit**: If `alignment.json` does not exist or `status != confirmed`, injects context reminding Codex to run `$align-intent` before dispatching.
2. **PreToolUse (Bash)**: Denies `start-claude-dispatch` / `dispatch-claude` commands when alignment is not confirmed.
3. **Stop**: Blocks session end if alignment interview is in-progress (status = `in-progress`).

### Installation

Copy `codex-hooks/hooks.json` to your `.codex/hooks.json` to enable the alignment gate.

### Lifecycle

```
alignment.json: not exists → in-progress → confirmed
                                      ↑              ↓
                               (re-run align)   (dispatch proceeds)
```

Once confirmed, the goal and success criteria are injected into TASK.md as acceptance criteria for the Claude worker.

### Integration with TASK.md

When `alignment.json` exists and is confirmed, `start-claude-dispatch.ps1` automatically injects the goal, success criteria, and constraints into the TASK.md acceptance criteria section.

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

## Task Decomposition Decision Tree

Use this tree to choose the right dispatch mode:

- Files ≤ 5, clear logic boundaries → `dispatch-claude.ps1` (synchronous)
- Files 6-20 or multi-module scope → `start-claude-dispatch.ps1` (background single task)
- Clearly separable OwnedPaths with no overlap → parallel (`start-claude-dispatch.ps1` × N, no file overlap)
- Sequential dependency chain → serial handoff (`DependencyRunIds`)
- Schema / migration changes → **forced serial**, never parallel

When in doubt, start with a single background task. Split into parallel only when ownership is unambiguous.

## Prompt Templates

Structure prompts based on task type:

### Bug Fix Template

```
Bug: <one-line description>

Reproduction steps:
1. <step>
2. <step>

Expected behavior: <what should happen>
Actual behavior: <what happens instead>

Files likely involved: <list>
Do NOT modify: <list of files to leave alone>

Validation: <test command to verify fix>
```

### New Feature Template

```
Feature: <one-line description>

Interface/Signature:
<function/API definition>

Acceptance criteria:
- <criterion 1>
- <criterion 2>

Related files: <list of files that may need changes>
Dependencies: <external APIs, libraries, or internal modules>

Validation: <test/build command>
```

### Refactor Template

```
Refactor: <what to change and why>

Behavior invariant: this refactor must NOT change any observable behavior.

Proof of correctness:
- <test command that must pass before AND after>
- <specific test cases that cover the refactored paths>

Do NOT add new features during this refactor.
Files in scope: <list>

Validation: <full test suite command>
```

### Test Addition Template

```
Add tests for: <module/feature>

Current coverage: <if known>
Target: <coverage goal or specific scenarios>

Scenarios to cover:
1. <scenario 1>
2. <scenario 2>
3. <edge case>

Testing framework: <jest, pester, pytest, etc.>
Run tests: <command>
```

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
- `QualityGateCommands` — validation commands to run before Stop hook allows exit (e.g., `@("npm test", "pnpm tsc --noEmit")`)

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

v2.0 does not automatically merge slot changes back into the source repo. Codex must inspect the slot diff and decide what to apply. Use `apply-dispatch.ps1` for one-click merge.

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

## Q&A Protocol

When a Claude worker encounters ambiguity, it can ask structured questions instead of guessing.

### Directory Structure

```text
<stateDir>/
  questions/q-<id>.json    ← worker writes (has a question)
  answers/q-<id>.json      ← Codex writes (provides answer)
```

### Question Schema (q-<id>.json)

```json
{
  "questionId": "q-001",
  "askedAt": "2026-06-25T...",
  "question": "Should src/api.ts use REST or GraphQL?",
  "options": ["REST", "GraphQL"],
  "context": "Existing code uses fetch() with no clear protocol layer.",
  "blockedPaths": ["src/api.ts"]
}
```

### Worker Behavior

When the worker encounters ambiguity:
1. Write a question file to `<stateDir>/questions/q-<id>.json`
2. Update status: set `phase` to `waiting-question`
3. Use `wait-for-answer.ps1` to poll for the answer
4. Resume work after receiving the answer

### Codex Behavior

When Codex sees `phase: waiting-question`:
1. Read the question file
2. Write the answer to `<stateDir>/answers/q-<id>.json`
3. The worker automatically resumes

### Helper Script

```powershell
& "<skill_dir>\scripts\wait-for-answer.ps1" `
  -QuestionPath "<stateDir>/questions/q-001.json" `
  -AnswerPath "<stateDir>/answers/q-001.json" `
  -TimeoutSeconds 300
```

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

### Post-Dispatch Review Checklist

Use this checklist for every completed dispatch:

- [ ] `git diff --name-only` shows changes only within OwnedPaths
- [ ] `final-report.md` validation results are all passing
- [ ] No new features beyond what the task described (scope creep)
- [ ] Tests cover the core change paths
- [ ] No TODO/FIXME comments left behind
- [ ] Error handling is present for failure paths
- [ ] No secrets, credentials, or .env files were touched
- [ ] Status reporting was accurate throughout the run

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
