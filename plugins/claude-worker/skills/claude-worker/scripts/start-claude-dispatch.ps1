param(
  [string]$Prompt,
  [string]$PromptFile,
  [string]$WorkingDirectory,
  [ValidateSet("acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan")]
  [string]$PermissionMode = "acceptEdits",
  [string]$StateRoot = "",
  [ValidateSet("visible", "hidden")]
  [string]$DisplayMode = "visible",
  [ValidateSet("interactive", "print")]
  [string]$ClaudeRunMode = "interactive",
  [ValidateSet("worktree", "mirrorPool")]
  [string]$WorkspaceMode = "worktree",
  [int]$MirrorPoolSize = 4,
  [string]$MirrorSlot = "",
  [ValidateSet("clean", "incremental")]
  [string]$MirrorRefresh = "clean",
  [ValidateSet("reviewOnly", "applyOwnedPaths")]
  [string]$MergeMode = "reviewOnly",
  [switch]$DisableHooks,
  [string]$RunLabel = "",
  [string]$BatchId = "",
  [string]$BatchGoal = "",
  [string[]]$OwnedPaths = @(),
  [string[]]$DependencyRunIds = @(),
  [string]$ClaudePath = "",
  [ValidateSet("onFailure", "always", "never")]
  [string]$HoldOnExit = "onFailure",
  [string[]]$QualityGateCommands = @()
)

$ErrorActionPreference = "Stop"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory "claude-dispatch-common.ps1")

if ($WorkingDirectory) {
  $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
} else {
  $WorkingDirectory = (Get-Location).Path
}

if ($PromptFile) {
  $Prompt = Get-Content -LiteralPath $PromptFile -Raw
}

if (-not $Prompt) {
  throw "Provide -Prompt or -PromptFile."
}

$platform = Get-DispatchPlatform
$windowsTerminalPath = $null
if ($platform -eq "Windows") {
  $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
  if ($wt) { $windowsTerminalPath = $wt.Source }
}
$powerShellPath = Get-DispatchPowerShellPath -Platform $platform
$workerPowerShellCommand = if ($platform -eq "Windows") { "powershell.exe" } else { Split-Path -Leaf $powerShellPath }
if (-not $workerPowerShellCommand) {
  $workerPowerShellCommand = $powerShellPath
}

$resolvedStateRoot = Get-StateRoot -StateRoot $StateRoot
Ensure-Directory -Path $resolvedStateRoot | Out-Null
Ensure-Directory -Path (Join-Path $resolvedStateRoot "runs") | Out-Null
Ensure-Directory -Path (Join-Path $resolvedStateRoot "batches") | Out-Null
Ensure-Directory -Path (Get-WorkspacesRoot -StateRoot $resolvedStateRoot) | Out-Null

if (-not $ClaudePath) {
  $ClaudePath = (Get-Command claude -ErrorAction Stop).Source
}
$ClaudePath = Resolve-DispatchClaudePath -ClaudePath $ClaudePath -Platform $platform

if ($PermissionMode -eq "bypassPermissions" -and $WorkspaceMode -eq "mirrorPool") {
  Write-Warning "bypassPermissions is running inside a mirrorPool slot. It protects the source repository from direct edits, but Claude may freely modify the slot repo."
} elseif ($PermissionMode -eq "bypassPermissions") {
  Write-Warning "bypassPermissions should only be used inside an isolated VM/container/sandbox. The safer default is acceptEdits."
}

$runId = New-DispatchRunId
if (-not $RunLabel) {
  $RunLabel = $runId
}

$ownedPaths = Normalize-PathsArray -Paths $OwnedPaths
$dependencyRunIds = Normalize-PathsArray -Paths $DependencyRunIds
$stateDirectory = Ensure-Directory -Path (Get-RunStateDirectory -StateRoot $resolvedStateRoot -RunId $runId)
$sourceKey = Get-DispatchStableWorkspaceKey -SourceWorkingDirectory $WorkingDirectory
$workspaceKey = if ($WorkspaceMode -eq "mirrorPool") { $sourceKey } else { $runId }
$mirrorSlotInfo = $null
$mirrorPoolRoot = $null
$mirrorSlotName = $null
$mirrorSlotDirectory = $null
$workspaceDirectory = Get-WorkspaceDirectory -StateRoot $resolvedStateRoot -RunId $runId
$workspaceControlPaths = Get-DispatchWorkspaceControlPaths -WorkspaceDirectory $workspaceDirectory
$controlDirectory = $workspaceControlPaths.controlDirectory
$promptPath = Join-Path $stateDirectory "prompt.txt"
$logPath = Join-Path $stateDirectory "claude.log"
$eventsPath = Join-Path $stateDirectory "events.ndjson"
$taskSourcePath = Join-Path $stateDirectory "TASK.md"
$finalReportSourcePath = Join-Path $stateDirectory "final-report.md"
$settingsPath = Join-Path $stateDirectory "claude-settings.json"
$systemPromptPath = Join-Path $stateDirectory "SYSTEM_PROMPT.md"
$launcherScriptPath = Join-Path $stateDirectory "launch.sh"
$metaPath = Join-Path $stateDirectory "run.json"
$statusSourcePath = Join-Path $stateDirectory "status.json"
$runnerPath = Join-Path $stateDirectory "runner.ps1"
$commonPath = Join-Path $scriptDirectory "claude-dispatch-common.ps1"
$statusHelperPath = Join-Path $scriptDirectory "update-claude-dispatch-status.ps1"
$handoffHelperPath = Join-Path $scriptDirectory "write-claude-dispatch-handoff.ps1"
$hookScriptPath = Join-Path $scriptDirectory "invoke-claude-dispatch-hook.ps1"
$branchName = if ($WorkspaceMode -eq "worktree") { Get-DispatchGitBranchName -RunId $runId } else { $null }

if ($WorkspaceMode -eq "mirrorPool") {
  $mirrorSlotInfo = Acquire-MirrorSlot `
    -StateRoot $resolvedStateRoot `
    -SourceWorkingDirectory $WorkingDirectory `
    -RunId $runId `
    -MirrorPoolSize $MirrorPoolSize `
    -MirrorSlot $MirrorSlot
  $mirrorPoolRoot = $mirrorSlotInfo.mirrorPoolRoot
  $mirrorSlotName = $mirrorSlotInfo.mirrorSlot
  $mirrorSlotDirectory = $mirrorSlotInfo.mirrorSlotDirectory
  $workspaceDirectory = Sync-MirrorSlotFromSource `
    -SourceWorkingDirectory $WorkingDirectory `
    -MirrorSlotDirectory $mirrorSlotDirectory `
    -MirrorRefresh $MirrorRefresh
  $workspaceControlPaths = Get-DispatchWorkspaceControlPaths -WorkspaceDirectory $workspaceDirectory
  $controlDirectory = $workspaceControlPaths.controlDirectory
} else {
  Ensure-DispatchWorktree -SourceWorkingDirectory $WorkingDirectory -WorkspaceDirectory $workspaceDirectory -BranchName $branchName
}

if ($DisplayMode -eq "visible" -and $ClaudeRunMode -eq "interactive") {
  Ensure-DispatchWorkspaceTrust -WorkspaceDirectory $workspaceDirectory | Out-Null
}

$batchRoot = $null
$handoffDirectory = $null
$batchRunDirectory = $null
$batchPromptContext = ""
if ($BatchId) {
  $batchRoot = Get-BatchRoot -StateRoot $resolvedStateRoot -BatchId $BatchId
  $handoffDirectory = Join-Path (Join-Path $batchRoot "handoffs") $runId
  $batchRunDirectory = Get-BatchRunDirectory -BatchRoot $batchRoot -RunId $runId
}

$statusSourcePath = if ($batchRunDirectory) { Join-Path $batchRunDirectory "status.json" } else { $statusSourcePath }
$status = New-DispatchStatus -RunId $runId -RunLabel $RunLabel -BatchId $BatchId -OwnedPaths $ownedPaths -DependencyRunIds $dependencyRunIds
Write-JsonFile -Path $statusSourcePath -Value $status
Set-Content -LiteralPath $finalReportSourcePath -Value "" -Encoding utf8

if ($BatchId) {
  Initialize-DispatchBatch -StateRoot $resolvedStateRoot -BatchId $BatchId -RunId $runId -RunLabel $RunLabel -OwnedPaths $ownedPaths -DependencyRunIds $dependencyRunIds -BatchGoal $BatchGoal -StatusPath $statusSourcePath | Out-Null

  $ownedPathsText = if ($ownedPaths -and $ownedPaths.Count -gt 0) { [string]::Join(", ", $ownedPaths) } else { "(none)" }
  $batchPromptLines = @(
    "Claude dispatch coordination contract v0.2:",
    "- You are run '$RunId' with label '$RunLabel' in batch '$BatchId'.",
    "- Read batch context from '$((Join-Path $batchRoot "batch.json"))' before making changes.",
    "- Read dependency run status files before starting related work.",
    "- Update only your own status file at '$($workspaceControlPaths.statusPath)' when you complete a meaningful step or become blocked.",
    "- Send short handoff notes only by creating files under '$handoffDirectory'.",
    "- Do not edit another run's status file, prompt, or handoff directory.",
    "- Restrict code changes to these owned paths when possible: $ownedPathsText.",
    "- If work crosses owned-path boundaries or conflicts with a dependency run, stop and record the blocker in status.json.",
    "- The controller is the only scheduler. Do not renegotiate task boundaries with other runs."
  )

  if ($dependencyRunIds -is [array] -and $dependencyRunIds.Count -gt 0) {
    $dependencyStatusPaths = @()
    foreach ($dependencyRunId in $dependencyRunIds) {
      $dependencyStatusPaths += (Join-Path (Get-BatchRunDirectory -BatchRoot $batchRoot -RunId $dependencyRunId) "status.json")
    }

    $batchPromptLines += ("- Dependency run status files: " + ([string]::Join(", ", $dependencyStatusPaths)))
  }

  $statusHelperExample = "$workerPowerShellCommand -NoProfile -ExecutionPolicy Bypass -File '$statusHelperPath' -StatusPath '$($workspaceControlPaths.statusPath)' -Phase running -Summary 'Updated a key milestone.' -LastCompletedStep 'Finished the first scoped change.' -NextStep 'Run validation and update status again.'"
  $handoffHelperExample = "$workerPowerShellCommand -NoProfile -ExecutionPolicy Bypass -File '$handoffHelperPath' -HandoffDirectory '$handoffDirectory' -FromRunId '$runId' -Summary 'Schema is ready.' -Message 'The migration landed and the downstream API worker can continue.' -RelatedPaths @('db/migrations/001.sql') -NextStep 'Read my latest status and continue.'"
  $batchPromptLines += @(
    "- Prefer the helper script '$statusHelperPath' to update status instead of hand-editing JSON.",
    "- Prefer the helper script '$handoffHelperPath' to write handoff messages instead of hand-creating files.",
    "- Status helper example: $statusHelperExample",
    "- Handoff helper example: $handoffHelperExample"
  )

  $batchPromptContext = ([string]::Join([Environment]::NewLine, $batchPromptLines) + [Environment]::NewLine + [Environment]::NewLine)
}

$effectivePrompt = $batchPromptContext + $Prompt
Set-Content -LiteralPath $promptPath -Value $effectivePrompt -Encoding utf8
Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
Set-Content -LiteralPath $eventsPath -Value "" -Encoding utf8

$ownedPathsText = if ($ownedPaths -and $ownedPaths.Count -gt 0) { [string]::Join([Environment]::NewLine, ($ownedPaths | ForEach-Object { "- $_" })) } else { "- (none specified; keep changes minimal and ask/status-block if scope is unclear)" }
$dependencyRunIdsText = if ($dependencyRunIds -and $dependencyRunIds.Count -gt 0) { [string]::Join([Environment]::NewLine, ($dependencyRunIds | ForEach-Object { "- $_" })) } else { "- (none)" }
$statusHelperExactExample = "$workerPowerShellCommand -NoProfile -ExecutionPolicy Bypass -File '$statusHelperPath' -StatusPath '$($workspaceControlPaths.statusPath)' -Phase running -Summary 'Finished a milestone.' -LastCompletedStep 'Created the first scoped change.' -NextStep 'Write the final report.'"
$statusHelperWorkspaceShortcut = "$workerPowerShellCommand -NoProfile -ExecutionPolicy Bypass -File '$statusHelperPath' -RunId '$runId' -Phase running -Summary 'Finished a milestone.' -LastCompletedStep 'Created the first scoped change.' -NextStep 'Write the final report.'"
$taskDocument = @"
# Claude Dispatch Task

You are the foreground Claude Code worker for this dispatch run.

## Run identity

- RunId: $runId
- RunLabel: $RunLabel
- BatchId: $BatchId
- Workspace: $workspaceDirectory
- Workspace control directory: $controlDirectory
- Task file: $($workspaceControlPaths.taskPath)
- Status file: $($workspaceControlPaths.statusPath)
- Handoff directory: $handoffDirectory
- Final report: $($workspaceControlPaths.finalReportPath)

## Owned paths

$ownedPathsText

## Dependency run ids

$dependencyRunIdsText

## Required operating contract

1. Work only inside the workspace above.
2. Keep edits scoped to the owned paths when owned paths are provided.
3. Use the workspace control directory above as the source of truth for TASK.md, status.json, and final-report.md.
4. Do not assume status.json or final-report.md exist in the workspace root. Use the exact control-file paths shown above.
5. Do not commit, push, publish, deploy, or run destructive commands.
6. Update the status file at the exact path shown above after every meaningful milestone and before any long-running validation.
7. If blocked, set phase to blocked, explain blockedOn, and stop.
8. Write the final report to the exact final report path shown above. Include summary, changed files, validation commands/results, risks, and remaining work.
9. Do not rely on terminal transcript as the source of truth; use the exact control-file paths, handoff files, and the exact final report path above.
10. Prefer direct Read/Write/Edit updates on status.json and final-report.md inside the workspace control directory. Use helper scripts only when shelling out is clearly easier.

## Helper commands

- Exact status helper example: $statusHelperExactExample
- Workspace-root status helper shortcut: $statusHelperWorkspaceShortcut
- The RunId shortcut works when you run it from the workspace root shown above.

## User task

$effectivePrompt
$(if (Test-Path -LiteralPath (Join-Path (Join-Path $resolvedStateRoot "state") "alignment.json")) {
  $alignData = Read-JsonFile -Path (Join-Path (Join-Path $resolvedStateRoot "state") "alignment.json")
  if ($alignData -and $alignData.status -eq "confirmed") {
    @"

## Acceptance Criteria (from alignment)

- **Goal:** $($alignData.goal)
- **Success Criteria:** $($alignData.successCriteria)
- **Constraints:** $($alignData.constraints)
- **Non-Goals:** $($alignData.nonGoals)

Use these criteria to judge task completion. The task is done ONLY when all success criteria are met.
"@
  }
})
"@
Set-Content -LiteralPath $taskSourcePath -Value $taskDocument -Encoding utf8
$workspaceControlPaths = Initialize-DispatchWorkspaceControlFiles `
  -WorkspaceDirectory $workspaceDirectory `
  -TaskPath $taskSourcePath `
  -StatusPath $statusSourcePath `
  -FinalReportPath $finalReportSourcePath
$taskPath = $workspaceControlPaths.taskPath
$statusPath = $workspaceControlPaths.statusPath
$finalReportPath = $workspaceControlPaths.finalReportPath
$controlDirectory = $workspaceControlPaths.controlDirectory

$systemPrompt = @"
You are running under claude-worker foreground dispatch.
The controller monitors files, not terminal output. Keep status files accurate.
Always read the dispatch TASK.md from the workspace control directory before modifying code.
The dispatch control directory lives inside the workspace. Prefer it over any guessed root-level file names.
Do not look for status.json or final-report.md in the workspace root unless TASK.md explicitly says so.
For foreground work, prefer direct Read/Write/Edit updates on the control files instead of shelling out.
Use the exact control-file paths from TASK.md or the helper scripts.
Use the status helper when possible:
$statusHelperPath
If you are already in the dispatch workspace root, the helper also accepts -RunId for the current run.
When using the Bash tool, invoke helper scripts through $workerPowerShellCommand with -File instead of using PowerShell call-operator syntax.
Use the handoff helper when possible:
$handoffHelperPath
Never push, deploy, publish, delete broad directories, or read secret files.
"@
Set-Content -LiteralPath $systemPromptPath -Value $systemPrompt -Encoding utf8

$ownedPathsForHooks = @($ownedPaths)
$ownedPathsJson = if ($ownedPathsForHooks.Count -gt 0) {
  ConvertTo-JsonText -Value $ownedPathsForHooks
} else {
  "[]"
}
$hookBaseArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $hookScriptPath,
  "-StateDirectory", $stateDirectory,
  "-StatusPath", $statusPath,
  "-EventsPath", $eventsPath,
  "-TaskPath", $taskPath,
  "-FinalReportPath", $finalReportPath,
  "-WorkspaceDirectory", $workspaceDirectory,
  "-OwnedPathsJson", $ownedPathsJson,
  "-SourceWorkingDirectory", $WorkingDirectory,
  "-MirrorPoolRoot", $mirrorPoolRoot,
  "-MirrorSlotDirectory", $mirrorSlotDirectory,
  "-DisplayMode", $DisplayMode,
  "-CommonPath", $commonPath
)
function New-HookCommandSpec {
  param([string]$EventName)
  return [ordered]@{
    type = "command"
    command = $powerShellPath
    args = @($hookBaseArgs + @("-EventName", $EventName))
    timeout = 30
  }
}

$terminalApp = Get-DispatchTerminalApp -Platform $platform -DisplayMode $DisplayMode -WindowsTerminalPath $windowsTerminalPath

$hooksConfig = [ordered]@{}
if (-not $DisableHooks) {
  $hooksConfig = [ordered]@{
    UserPromptSubmit = @([ordered]@{ hooks = @((New-HookCommandSpec -EventName "UserPromptSubmit")) })
    PreToolUse = @(
      [ordered]@{ matcher = "Bash|Read|Write|Edit|MultiEdit"; hooks = @((New-HookCommandSpec -EventName "PreToolUse")) }
    )
    PostToolUse = @(
      [ordered]@{ matcher = "Bash|Read|Write|Edit|MultiEdit"; hooks = @((New-HookCommandSpec -EventName "PostToolUse")) }
    )
    Stop = @([ordered]@{ hooks = @((New-HookCommandSpec -EventName "Stop")) })
    MessageDisplay = @([ordered]@{ hooks = @((New-HookCommandSpec -EventName "MessageDisplay")) })
  }
}
$qualityGateConfig = $null
if ($QualityGateCommands -and $QualityGateCommands.Count -gt 0) {
  $qualityGateConfig = [ordered]@{
    commands = $QualityGateCommands
    timeoutSeconds = 300
  }
}

$settings = [ordered]@{
  permissions = [ordered]@{
    defaultMode = "acceptEdits"
    deny = @(
      "Bash(git push *)",
      "Bash(git push*)",
      "Bash(npm publish*)",
      "Bash(pnpm publish*)",
      "Bash(yarn publish*)",
      "Bash(rm -rf *)",
      "Bash(rm -fr *)",
      "Bash(sudo rm *)",
      "Read(./.env)",
      "Read(./.env.*)",
      "Read(./secrets/**)",
      "Read(./**/secrets/**)",
      "Read(./**/*credential*)",
      "Read(./**/*secret*)"
    )
  }
  hooks = $hooksConfig
  qualityGate = $qualityGateConfig
}
Write-JsonFile -Path $settingsPath -Value $settings
Append-DispatchEvent -EventsPath $eventsPath -EventName "DispatchCreated" -Data ([ordered]@{ runId = $runId; runLabel = $RunLabel; claudeRunMode = $ClaudeRunMode; displayMode = $DisplayMode; permissionMode = $PermissionMode; hooksEnabled = (-not $DisableHooks) })

function Invoke-WorkspaceTrustPrewarm {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ClaudeExecutablePath,
    [Parameter(Mandatory = $true)]
    [string]$PowerShellExecutablePath,
    [Parameter(Mandatory = $true)]
    [string]$PermissionMode,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory,
    [Parameter(Mandatory = $true)]
    [string]$EventsPath,
    [Parameter(Mandatory = $true)]
    [string]$LogPath
  )

  $prewarmPrompt = "Reply with exactly: OK"
  $prewarmArguments = @(
    "--setting-sources", "user",
    "--permission-mode", $PermissionMode,
    "-p", $prewarmPrompt
  )

  Append-DispatchEvent -EventsPath $EventsPath -EventName "TrustPrewarmStarted" -Data ([ordered]@{ workspaceDirectory = $WorkspaceDirectory })
  $prewarmResult = Invoke-DispatchCommandCapture `
    -CommandPath $ClaudeExecutablePath `
    -ArgumentList $prewarmArguments `
    -WorkingDirectory $WorkspaceDirectory `
    -PowerShellPath $PowerShellExecutablePath `
    -TimeoutSeconds 15

  $trimmedOutput = if ($prewarmResult.StandardOutput) { $prewarmResult.StandardOutput.Trim() } else { "" }
  if ($trimmedOutput) {
    Add-Content -LiteralPath $LogPath -Value ("[trust-prewarm stdout] " + $trimmedOutput) -Encoding utf8
  }
  if ($prewarmResult.StandardError) {
    Add-Content -LiteralPath $LogPath -Value ("[trust-prewarm stderr] " + $prewarmResult.StandardError.Trim()) -Encoding utf8
  }

  if ($prewarmResult.ExitCode -eq 0) {
    Append-DispatchEvent -EventsPath $EventsPath -EventName "TrustPrewarmCompleted" -Data ([ordered]@{ exitCode = $prewarmResult.ExitCode; output = $trimmedOutput })
    return
  }

  $eventName = if ($prewarmResult.TimedOut) { "TrustPrewarmTimedOut" } else { "TrustPrewarmFailed" }
  Append-DispatchEvent -EventsPath $EventsPath -EventName $eventName -Data ([ordered]@{ exitCode = $prewarmResult.ExitCode; output = $trimmedOutput; error = $prewarmResult.StandardError })
}

if ($DisplayMode -eq "visible" -and $ClaudeRunMode -eq "interactive") {
  Invoke-WorkspaceTrustPrewarm `
    -ClaudeExecutablePath $ClaudePath `
    -PowerShellExecutablePath $powerShellPath `
    -PermissionMode $PermissionMode `
    -WorkspaceDirectory $workspaceDirectory `
    -EventsPath $eventsPath `
    -LogPath $logPath
}

$windowTitle = "Claude Dispatch " + $RunLabel
$windowName = "claude-dispatch-$runId"
$metadata = New-DispatchMetadata `
  -RunId $runId `
  -StateRoot $resolvedStateRoot `
  -SourceWorkingDirectory $WorkingDirectory `
  -WorkspaceDirectory $workspaceDirectory `
  -PromptPath $promptPath `
  -TaskPath $taskPath `
  -LogPath $logPath `
  -EventsPath $eventsPath `
  -FinalReportPath $finalReportPath `
  -SettingsPath $settingsPath `
  -SystemPromptPath $systemPromptPath `
  -StatusPath $statusPath `
  -RunnerPath $runnerPath `
  -RunLabel $RunLabel `
  -BatchId $BatchId `
  -OwnedPaths $ownedPaths `
  -DependencyRunIds $dependencyRunIds `
  -PermissionMode $PermissionMode `
  -ClaudeRunMode $ClaudeRunMode `
  -DisplayMode $DisplayMode `
  -TerminalApp $terminalApp `
  -HoldOnExit $HoldOnExit `
  -WindowTitle $windowTitle `
  -WindowName $windowName `
  -BatchRoot $batchRoot `
  -HandoffDirectory $handoffDirectory `
  -WorkspaceMode $WorkspaceMode `
  -WorkspaceKey $workspaceKey `
  -MirrorPoolRoot $mirrorPoolRoot `
  -MirrorSlot $mirrorSlotName `
  -MirrorSlotDirectory $mirrorSlotDirectory `
  -MirrorRefresh $MirrorRefresh `
  -MergeMode $MergeMode `
  -WorktreeBranch $branchName `
  -StatusHelperPath $statusHelperPath `
  -HandoffHelperPath $handoffHelperPath
Save-DispatchMetadata -Path $metaPath -Metadata $metadata

$runnerSourcePath = Join-Path $PSScriptRoot "start-claude-dispatch-runner.ps1"
Copy-Item -LiteralPath $runnerSourcePath -Destination $runnerPath -Force

$runnerArguments = @(
  "-File",
  $runnerPath,
  "-MetaPath",
  $metaPath,
  "-CommonPath",
  $commonPath,
  "-PromptPath",
  $promptPath,
  "-TaskPath",
  $taskPath,
  "-LogPath",
  $logPath,
  "-EventsPath",
  $eventsPath,
  "-FinalReportPath",
  $finalReportPath,
  "-SettingsPath",
  $settingsPath,
  "-SystemPromptPath",
  $systemPromptPath,
  "-WorkingDirectory",
  $workspaceDirectory,
  "-PermissionMode",
  $PermissionMode,
  "-ClaudePath",
  $ClaudePath,
  "-ClaudeRunMode",
  $ClaudeRunMode,
  "-DisplayMode",
  $DisplayMode,
  "-HoldOnExit",
  $HoldOnExit
)

$launcherSpec = New-DispatchLauncherSpec `
  -Platform $platform `
  -DisplayMode $DisplayMode `
  -PowerShellPath $powerShellPath `
  -RunnerArguments $runnerArguments `
  -WindowTitle $windowTitle `
  -WindowName $windowName `
  -StartingDirectory $workspaceDirectory `
  -HoldOnExit $HoldOnExit `
  -WindowsTerminalPath $windowsTerminalPath `
  -LauncherScriptPath $launcherScriptPath

$process = Start-DispatchProcess `
  -FilePath $launcherSpec.FilePath `
  -ArgumentList $launcherSpec.ArgumentList `
  -WindowStyle $launcherSpec.WindowStyle

$metadata = Update-DispatchMetadata -Path $metaPath -Mutator {
  param($run)
  $run.launcherPid = $process.Id
} 

$ownedPathsText = if ($ownedPaths -is [array] -and $ownedPaths.Count -gt 0) {
  [string]::Join(", ", $ownedPaths)
} elseif ($ownedPaths) {
  [string]$ownedPaths
} else {
  "(none)"
}

$result = [ordered]@{
  runId = $metadata.runId
  runLabel = $metadata.runLabel
  batchId = $metadata.batchId
  status = $metadata.status
  displayMode = $metadata.displayMode
  terminalApp = $metadata.terminalApp
  windowTitle = $metadata.windowTitle
  windowName = $metadata.windowName
  stateRoot = $resolvedStateRoot
  stateDirectory = $metadata.stateDirectory
  workspaceDirectory = $metadata.workspaceDirectory
  sourceWorkingDirectory = $metadata.sourceWorkingDirectory
  statusPath = $metadata.statusPath
  logPath = $metadata.logPath
  eventsPath = $metadata.eventsPath
  taskPath = $metadata.taskPath
  finalReportPath = $metadata.finalReportPath
  settingsPath = $metadata.settingsPath
  systemPromptPath = $metadata.systemPromptPath
  claudeRunMode = $metadata.claudeRunMode
  workspaceMode = $metadata.workspaceMode
  workspaceKey = $metadata.workspaceKey
  mirrorPoolRoot = $metadata.mirrorPoolRoot
  mirrorSlot = $metadata.mirrorSlot
  mirrorSlotDirectory = $metadata.mirrorSlotDirectory
  mirrorRefresh = $metadata.mirrorRefresh
  mergeMode = $metadata.mergeMode
  handoffDirectory = $metadata.handoffDirectory
  statusHelperPath = $metadata.statusHelperPath
  handoffHelperPath = $metadata.handoffHelperPath
  ownedPaths = $metadata.ownedPaths
  dependencyRunIds = $metadata.dependencyRunIds
}

$result | ConvertTo-Json -Depth 6
