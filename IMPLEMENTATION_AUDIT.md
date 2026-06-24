# Implementation Audit — claude-worker v0.3 foreground dispatch

## Result

Applied the v2 audited design directly to the uploaded project package. This patch converts visible background dispatch from non-interactive `claude -p` style execution to foreground interactive Claude Code execution by default.

## Changed areas

- `start-claude-dispatch.ps1`
  - default permission mode changed to `acceptEdits`
  - added `ClaudeRunMode interactive|print`
  - interactive mode invokes `claude "<initial prompt>"` without stdin pipe, `-p`, or `Tee-Object`
  - generates `TASK.md`, `SYSTEM_PROMPT.md`, `claude-settings.json`, `events.ndjson`, and `final-report.md` path
  - passes `--settings` and `--append-system-prompt-file` into Claude Code
- `claude-dispatch-common.ps1`
  - atomic JSON writes
  - NDJSON event helper
  - v0.3 metadata/status schemas
  - safer macOS visible launch via generated `launch.sh`
- `invoke-claude-dispatch-hook.ps1`
  - UserPromptSubmit context injection
  - PreToolUse guardrails for dangerous bash, secrets, and owned-path writes
  - PostToolUse heartbeat/event logging
  - Stop hook block until final report/status are complete
  - MessageDisplay side-effect logging only
- `watch-claude-dispatch.ps1`
  - local 10-minute supervisor loop
- `README.md` and `SKILL.md`
  - updated operating model and safer defaults

## Audit notes

- Static syntax review performed in this container.
- PowerShell/Pester execution was not possible because `pwsh` is not installed in the sandbox.
- Real foreground Terminal.app / Windows Terminal launch cannot be validated inside this Linux container; the code paths were checked against documented CLI and hook behavior.

## Known limitations

- Stop hook requires `final-report.md`; if Claude is asked to exit immediately without writing it, the hook will block and ask it to complete the report.
- Owned-path enforcement is intentionally conservative for Write/Edit/MultiEdit. If a task legitimately needs cross-boundary edits, include those paths in `OwnedPaths` or leave `OwnedPaths` empty for broad tasks.
- MCP is intentionally not included; this package uses hooks + files + supervisor because that is the simpler fit for foreground dispatch.

## Static verification performed in sandbox

| Check | Result |
|---|---|
| `start-claude-dispatch.ps1` default permission is `acceptEdits` | PASS |
| `ClaudeRunMode interactive|print` exists | PASS |
| interactive mode invokes Claude without `-p`/stdin pipe/`Tee-Object` | PASS |
| print mode keeps explicit `-p` path for non-interactive use | PASS |
| per-run `--settings` is generated and passed to Claude | PASS |
| `--append-system-prompt-file` is generated and passed to Claude | PASS |
| JSON writes in common helper are atomic temp-file moves | PASS |
| macOS visible launcher uses generated `launch.sh` rather than a long AppleScript command | PASS |
| hook runner includes `PreToolUse` deny decisions | PASS |
| hook runner includes `Stop` block decisions for missing final report/status | PASS |
| synchronous helper default permission changed to `acceptEdits` | PASS |

## Official behavior assumptions checked

- Claude Code CLI supports `--permission-mode`, `--settings`, `--append-system-prompt-file`, and `--plugin-dir`; `-p/--print` is the non-interactive print mode.
- Claude Code hooks fire at lifecycle events including `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, and `MessageDisplay`.
- `PreToolUse` uses `hookSpecificOutput.permissionDecision`, while `Stop` uses top-level `decision: "block"`.
- `MessageDisplay` is display-only and cannot block or alter transcript/state, so it is used only for optional event logging.
- `permissions.defaultMode = auto` is ignored from project/local settings; this package defaults to `acceptEdits` and lets the CLI flag override per run.
