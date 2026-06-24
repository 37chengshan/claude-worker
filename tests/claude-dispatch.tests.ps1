$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$scriptRoot = Join-Path $repoRoot "plugins\claude-worker\skills\claude-worker\scripts"
$fixtureRoot = Join-Path $PSScriptRoot "fixtures"
$startScript = Join-Path $scriptRoot "start-claude-dispatch.ps1"
$checkScript = Join-Path $scriptRoot "check-claude-dispatch.ps1"
$listScript = Join-Path $scriptRoot "list-claude-dispatch.ps1"
$stopScript = Join-Path $scriptRoot "stop-claude-dispatch.ps1"
$cleanupScript = Join-Path $scriptRoot "cleanup-claude-dispatch.ps1"
$commonScript = Join-Path $scriptRoot "claude-dispatch-common.ps1"
$statusHelperScript = Join-Path $scriptRoot "update-claude-dispatch-status.ps1"
$handoffHelperScript = Join-Path $scriptRoot "write-claude-dispatch-handoff.ps1"
$fakeClaude = Join-Path $fixtureRoot "fake-claude.ps1"

function New-TestTempDirectory {
  $path = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-dispatch-tests-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $path -Force | Out-Null
  return $path
}

function Initialize-TestRepository {
  param([string]$Path)

  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  & git -C $Path init | Out-Null
  & git -C $Path config user.email "tests@example.com"
  & git -C $Path config user.name "Dispatch Tests"

  Set-Content -LiteralPath (Join-Path $Path "tracked.txt") -Value "base" -Encoding utf8
  New-Item -ItemType Directory -Path (Join-Path $Path "src") -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $Path "src\owned.txt") -Value "owned" -Encoding utf8

  & git -C $Path add .
  & git -C $Path commit -m "test baseline" | Out-Null
}

function Invoke-JsonScript {
  param(
    [string]$Path,
    [hashtable]$Parameters = @{},
    [string]$WorkingDirectory
  )

  $output = if ($WorkingDirectory) {
    Push-Location $WorkingDirectory
    try {
      & $Path @Parameters | Out-String
    } finally {
      Pop-Location
    }
  } else {
    & $Path @Parameters | Out-String
  }
  return ($output | ConvertFrom-Json)
}

function Assert-Equal {
  param(
    $Actual,
    $Expected,
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw ($Message + " Expected: '$Expected'. Actual: '$Actual'.")
  }
}

function Assert-NotEqual {
  param(
    $Actual,
    $Unexpected,
    [string]$Message
  )

  if ($Actual -eq $Unexpected) {
    throw ($Message + " Unexpected value: '$Unexpected'.")
  }
}

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Match {
  param(
    [string]$Actual,
    [string]$Pattern,
    [string]$Message
  )

  if ($Actual -notmatch $Pattern) {
    throw ($Message + " Pattern: $Pattern")
  }
}

function Assert-NullOrEmpty {
  param(
    $Actual,
    [string]$Message
  )

  if ($null -eq $Actual) {
    return
  }

  if ($Actual -is [string]) {
    if ([string]::IsNullOrEmpty($Actual)) {
      return
    }
  } elseif ($Actual -is [System.Collections.IEnumerable]) {
    if (@($Actual).Count -eq 0) {
      return
    }
  }

  throw $Message
}

Describe "Claude dispatch v0.4 scripts" {
  BeforeEach {
    $env:FAKE_CLAUDE_BEHAVIOR = $null
    $env:FAKE_CLAUDE_TOUCH_FILE = $null
    $env:FAKE_CLAUDE_SLEEP_SECONDS = $null
    $env:FAKE_CLAUDE_PRE_SLEEP_SECONDS = $null
  }

  It "creates isolated run state, batch coordination files, and workspace metadata" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "touch-and-complete"
    $env:FAKE_CLAUDE_TOUCH_FILE = "worker-output.txt"

    $start = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Create the worker output file and finish."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      BatchId = "batch-1"
      RunLabel = "worker-a"
      OwnedPaths = @("src/owned.txt", "worker-output.txt")
      DependencyRunIds = @("run-bootstrap")
      ClaudePath = $fakeClaude
    }

    $check = Invoke-JsonScript -Path $checkScript -Parameters @{
      RunId = $start.runId
      StateRoot = $stateRoot
      WaitSeconds = 10
    }

    Assert-Equal $check.status "completed" "Expected run status to be completed."
    Assert-Equal $check.batchId "batch-1" "Expected batch id to be preserved."
    Assert-NotEqual $check.workspaceDirectory $repoPath "Expected isolated workspace instead of source repo path."
    Assert-True ($check.ownedPaths -contains "src/owned.txt") "Expected owned paths to include src/owned.txt."
    Assert-True ($check.changedFiles.path -contains "worker-output.txt") "Expected changed files to include worker-output.txt."
    Assert-Match $check.taskPath '\\\.claude-dispatch\\TASK\.md$' "Expected task path to live in the workspace control directory."
    Assert-Match $check.statusPath '\\\.claude-dispatch\\status\.json$' "Expected status path to live in the workspace control directory."
    Assert-Match $check.finalReportPath '\\\.claude-dispatch\\final-report\.md$' "Expected final report path to live in the workspace control directory."
    Assert-True (Test-Path -LiteralPath $check.statusPath) "Expected status.json to exist."
    Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot "batches\batch-1\batch.json")) "Expected batch.json to exist."
    Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot "batches\batch-1\handoffs\$($start.runId)")) "Expected handoff directory to exist."
    Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot "batches\batch-1\runs\$($start.runId)\status.json")) "Expected canonical batch status file to exist."

    $status = Get-Content -LiteralPath $check.statusPath -Raw | ConvertFrom-Json
    Assert-Equal $status.phase "completed" "Expected status phase to be completed."
    Assert-True ($status.ownedPaths -contains "worker-output.txt") "Expected status owned paths to include worker-output.txt."
    Assert-NullOrEmpty $status.blockedOn "Expected blockedOn to be empty."

    $batch = Get-Content -LiteralPath (Join-Path $stateRoot "batches\batch-1\batch.json") -Raw | ConvertFrom-Json
    Assert-True ((($batch.runs | ForEach-Object { $_.runId } | Where-Object { $_ -eq $start.runId }).Count -gt 0)) "Expected batch runs to include the started run."
    Assert-True ((($batch.runs | ForEach-Object { @($_.dependsOnRunIds) } | ForEach-Object { $_ } | Where-Object { $_ -eq "run-bootstrap" }).Count -gt 0)) "Expected dependency run ids to include run-bootstrap."

    $promptText = Get-Content -LiteralPath (Join-Path $start.stateDirectory "prompt.txt") -Raw
    $taskText = Get-Content -LiteralPath $check.taskPath -Raw
    Assert-Match $promptText 'update-claude-dispatch-status\.ps1' "Expected batch prompt to include the status helper path."
    Assert-Match $promptText 'write-claude-dispatch-handoff\.ps1' "Expected batch prompt to include the handoff helper path."
    Assert-Match $promptText 'Status helper example:' "Expected batch prompt to include the helper usage example."
    Assert-Match $promptText 'Handoff helper example:' "Expected batch prompt to include the handoff usage example."
    Assert-Match $promptText 'powershell(\.exe)? .*?-File .*?update-claude-dispatch-status\.ps1' "Expected batch status helper example to be shell-compatible."
    Assert-Match $taskText 'Use the workspace control directory above as the source of truth' "Expected task contract to emphasize the workspace control directory."
    Assert-Match $taskText 'Write the final report to the exact final report path shown above\.' "Expected task contract to emphasize the exact final report path."
    Assert-Match $taskText 'Prefer direct Read/Write/Edit updates on status\.json and final-report\.md inside the workspace control directory\.' "Expected task contract to prefer direct control-file edits for foreground work."
    Assert-Match $taskText 'Workspace-root status helper shortcut: powershell(\.exe)? .*?-File .*?update-claude-dispatch-status\.ps1' "Expected single-run status helper shortcut to use a shell-compatible PowerShell invocation."
  }

  It "builds cross-platform launcher specs for visible and hidden runs" {
    . $commonScript

    $windowsVisible = New-DispatchLauncherSpec `
      -Platform "Windows" `
      -DisplayMode "visible" `
      -PowerShellPath "powershell.exe" `
      -WindowsTerminalPath "C:\Windows\System32\wt.exe" `
      -RunnerArguments @("-File", "runner.ps1") `
      -WindowTitle "dispatch-visible"

    Assert-Equal $windowsVisible.FilePath "C:\Windows\System32\wt.exe" "Expected visible Windows launcher to use wt.exe."
    Assert-Equal $windowsVisible.ArgumentList[0] "-w" "Expected wt launcher to start with -w."
    Assert-True ($windowsVisible.ArgumentList -contains "nt") "Expected wt launcher to include new-tab token."

    $windowsHidden = New-DispatchLauncherSpec `
      -Platform "Windows" `
      -DisplayMode "hidden" `
      -PowerShellPath "powershell.exe" `
      -RunnerArguments @("-File", "runner.ps1") `
      -WindowTitle "dispatch-hidden"

    Assert-Equal $windowsHidden.FilePath "powershell.exe" "Expected hidden Windows launcher to use powershell.exe."
    Assert-Equal $windowsHidden.WindowStyle "Hidden" "Expected hidden Windows launcher to request hidden window style."

    $macVisible = New-DispatchLauncherSpec `
      -Platform "MacOS" `
      -DisplayMode "visible" `
      -PowerShellPath "/usr/local/bin/pwsh" `
      -RunnerArguments @("-File", "/tmp/runner.ps1") `
      -WindowTitle "dispatch-mac"

    Assert-Equal $macVisible.FilePath "osascript" "Expected visible macOS launcher to use osascript."
    Assert-True ($macVisible.ArgumentList -contains "-e") "Expected macOS launcher to pass AppleScript via -e."
  }

  It "quotes launcher arguments for visible Windows runs with spaces" {
    . $commonScript

    $spec = New-DispatchLauncherSpec `
      -Platform "Windows" `
      -DisplayMode "visible" `
      -PowerShellPath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -WindowsTerminalPath "C:\Users\tester\AppData\Local\Microsoft\WindowsApps\wt.exe" `
      -RunnerArguments @(
        "-File",
        "C:\Temp Folder\runner.ps1",
        "-PromptPath",
        "C:\Temp Folder\prompt file.txt"
      ) `
      -WindowTitle "Claude Dispatch visible-smoke" `
      -WindowName "claude-dispatch-window" `
      -StartingDirectory "C:\Temp Folder\workspace"

    $commandLine = Join-ProcessArgumentList -Arguments $spec.ArgumentList
    Assert-Match $commandLine '"Claude Dispatch visible-smoke"' "Expected quoted window title in launcher command line."
    Assert-Match $commandLine '"C:\\Temp Folder\\workspace"' "Expected quoted starting directory in launcher command line."
    Assert-Match $commandLine '"C:\\Temp Folder\\runner.ps1"' "Expected quoted runner path in launcher command line."
    Assert-Match $commandLine '"C:\\Temp Folder\\prompt file.txt"' "Expected quoted prompt path in launcher command line."
  }

  It "resolves a Windows Claude PowerShell shim to a safer foreground launcher" {
    . $commonScript

    $tempRoot = New-TestTempDirectory
    $npmRoot = Join-Path $tempRoot "npm"
    $ps1Path = Join-Path $npmRoot "claude.ps1"
    $cmdPath = Join-Path $npmRoot "claude.cmd"
    $exePath = Join-Path $npmRoot "node_modules\@anthropic-ai\claude-code\bin\claude.exe"

    New-Item -ItemType Directory -Path (Split-Path -Parent $exePath) -Force | Out-Null
    Set-Content -LiteralPath $ps1Path -Value "exit 0" -Encoding utf8
    Set-Content -LiteralPath $cmdPath -Value "@echo off`r`nexit /b 0`r`n" -Encoding ascii
    Set-Content -LiteralPath $exePath -Value "" -Encoding ascii

    $resolved = Resolve-DispatchClaudePath -ClaudePath $ps1Path -Platform "Windows"

    Assert-Equal $resolved $exePath "Expected Windows foreground dispatch to prefer a non-PowerShell Claude launcher."
  }

  It "puts the interactive Claude prompt before flags and keeps print mode explicit" {
    . $commonScript

    $interactiveArguments = Get-DispatchClaudeArguments `
      -PermissionMode "bypassPermissions" `
      -SettingsPath "C:\Temp\settings.json" `
      -SystemPromptPath "C:\Temp\SYSTEM_PROMPT.md" `
      -ClaudeRunMode "interactive" `
      -InitialPrompt "Read TASK.md and begin."

    Assert-Equal $interactiveArguments[0] "Read TASK.md and begin." "Expected the interactive prompt to be the first Claude argument."
    Assert-Equal $interactiveArguments[1] "--permission-mode" "Expected interactive mode flags to follow the prompt."

    $printArguments = Get-DispatchClaudeArguments `
      -PermissionMode "bypassPermissions" `
      -SettingsPath "C:\Temp\settings.json" `
      -SystemPromptPath "C:\Temp\SYSTEM_PROMPT.md" `
      -ClaudeRunMode "print" `
      -InitialPrompt "Read TASK.md and begin."

    Assert-True ($printArguments -contains "-p") "Expected print mode to include the -p flag."
    Assert-Equal $printArguments[-1] "Read TASK.md and begin." "Expected print mode to pass the prompt after -p."
  }

  It "times out command capture so trust prewarm cannot block foreground launch forever" {
    . $commonScript

    $env:FAKE_CLAUDE_BEHAVIOR = "sleep"
    $env:FAKE_CLAUDE_SLEEP_SECONDS = "30"
    try {
      $startedAt = Get-Date
      $result = Invoke-DispatchCommandCapture `
        -CommandPath $fakeClaude `
        -ArgumentList @("--permission-mode", "acceptEdits", "-p", "OK") `
        -WorkingDirectory $repoRoot `
        -TimeoutSeconds 1
      $elapsedSeconds = ((Get-Date) - $startedAt).TotalSeconds

      Assert-Equal $result.TimedOut $true "Expected command capture to report a timeout."
      Assert-Equal $result.ExitCode -408 "Expected timeout exit code."
      Assert-Match $result.StandardError "timed out" "Expected timeout message in stderr."
      Assert-True ($elapsedSeconds -lt 10) "Expected timeout to return quickly."
    } finally {
      Remove-Item Env:\FAKE_CLAUDE_BEHAVIOR -ErrorAction SilentlyContinue
      Remove-Item Env:\FAKE_CLAUDE_SLEEP_SECONDS -ErrorAction SilentlyContinue
    }
  }

  It "passes display and hold settings through to the runner process" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "complete"

    $start = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Finish quickly."
      DisplayMode = "hidden"
      HoldOnExit = "always"
      StateRoot = $stateRoot
      RunLabel = "hold-check"
      ClaudePath = $fakeClaude
    }

    $runMeta = Get-Content -LiteralPath (Join-Path $start.stateDirectory "run.json") -Raw
    Assert-Match $runMeta '"displayMode"\s*:\s*"hidden"' "Expected run metadata to record hidden display mode."
    Assert-Match $runMeta '"holdOnExit"\s*:\s*"always"' "Expected run metadata to record holdOnExit."

    $runnerScriptText = Get-Content -LiteralPath (Join-Path $start.stateDirectory "runner.ps1") -Raw
    Assert-Match $runnerScriptText '\[string\]\$DisplayMode' "Expected runner script to accept DisplayMode."
    Assert-Match $runnerScriptText '\[string\]\$HoldOnExit' "Expected runner script to accept HoldOnExit."
    Assert-Match $runMeta '"windowTitle"\s*:\s*"Claude Dispatch hold-check"' "Expected run metadata to record the visible window title."
  }

  It "lists active and completed runs across standalone and batch directories" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "complete"

    $standalone = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Finish quickly."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      RunLabel = "solo"
      ClaudePath = $fakeClaude
    }

    $batched = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Finish quickly in a batch."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      BatchId = "batch-2"
      RunLabel = "batch-worker"
      ClaudePath = $fakeClaude
    }

    Start-Sleep -Seconds 2
    $list = Invoke-JsonScript -Path $listScript -Parameters @{ StateRoot = $stateRoot }

    Assert-True ($list.runs.runId -contains $standalone.runId) "Expected standalone run to appear in list output."
    Assert-True ($list.runs.runId -contains $batched.runId) "Expected batched run to appear in list output."
    Assert-Equal (($list.runs | Where-Object { $_.runId -eq $batched.runId }).batchId) "batch-2" "Expected listed batched run to keep its batch id."
  }

  It "stops long-running tasks and cleans up run state and worktrees" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "sleep"
    $env:FAKE_CLAUDE_SLEEP_SECONDS = "120"

    $start = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Stay alive until stopped."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      RunLabel = "long-run"
      ClaudePath = $fakeClaude
    }

    Start-Sleep -Seconds 2

    $stop = Invoke-JsonScript -Path $stopScript -Parameters @{
      RunId = $start.runId
      StateRoot = $stateRoot
    }

    Assert-Equal $stop.status "stopped" "Expected stopped status after controller stop."

    $cleanup = Invoke-JsonScript -Path $cleanupScript -Parameters @{
      RunId = $start.runId
      StateRoot = $stateRoot
      Force = $true
    }

    Assert-True $cleanup.removed "Expected cleanup to remove run state."
    Assert-Equal (Test-Path -LiteralPath $cleanup.stateDirectory) $false "Expected state directory to be deleted."
    if ($cleanup.workspaceDirectory -and ($cleanup.workspaceDirectory -ne $cleanup.sourceWorkingDirectory)) {
      Assert-Equal (Test-Path -LiteralPath $cleanup.workspaceDirectory) $false "Expected isolated workspace to be deleted."
    }
  }

  It "removes batch coordination artifacts when a batched run is cleaned up" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "complete"

    $start = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Finish in batch and leave cleanup evidence."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      BatchId = "batch-cleanup"
      RunLabel = "cleanup-worker"
      ClaudePath = $fakeClaude
    }

    $batchRoot = Join-Path $stateRoot "batches\batch-cleanup"
    Assert-True (Test-Path -LiteralPath (Join-Path $batchRoot "batch.json")) "Expected batch.json to exist before cleanup."
    Assert-True (Test-Path -LiteralPath (Join-Path $batchRoot "runs\$($start.runId)\status.json")) "Expected batch run status to exist before cleanup."
    Assert-True (Test-Path -LiteralPath (Join-Path $batchRoot "handoffs\$($start.runId)")) "Expected batch handoff directory to exist before cleanup."

    $cleanup = Invoke-JsonScript -Path $cleanupScript -Parameters @{
      RunId = $start.runId
      StateRoot = $stateRoot
      Force = $true
    }

    Assert-True $cleanup.removed "Expected cleanup to remove the batched run."
    Assert-Equal (Test-Path -LiteralPath $batchRoot) $false "Expected empty batch root to be deleted."
  }

  It "updates status and writes handoff files through worker helper scripts" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "complete"

    $start = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Set up helper script verification."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      BatchId = "batch-helpers"
      RunLabel = "helpers-worker"
      ClaudePath = $fakeClaude
    }

    $updatedStatus = Invoke-JsonScript -Path $statusHelperScript -Parameters @{
      StatusPath = $start.statusPath
      Phase = "blocked"
      Summary = "Waiting for an upstream decision."
      LastCompletedStep = "Finished the owned refactor."
      NextStep = "Resume after dependency review."
      BlockedOn = @("run-upstream")
      Progress = 75
    }

    Assert-Equal $updatedStatus.phase "blocked" "Expected helper script to update the phase."
    Assert-Equal $updatedStatus.summary "Waiting for an upstream decision." "Expected helper script to update the summary."
    Assert-True ($updatedStatus.blockedOn -contains "run-upstream") "Expected helper script to persist blockedOn values."
    Assert-Equal $updatedStatus.progress 75 "Expected helper script to persist progress."

    $handoff = Invoke-JsonScript -Path $handoffHelperScript -Parameters @{
      HandoffDirectory = $start.handoffDirectory
      FromRunId = $start.runId
      Summary = "Ready for downstream work."
      Message = "The owned refactor is finished and downstream validation can continue."
      RelatedPaths = @("src/owned.txt", "worker-output.txt")
      NextStep = "Read my status file and continue."
    }

    Assert-True (Test-Path -LiteralPath $handoff.path) "Expected handoff helper to create a handoff file."
    Assert-Equal $handoff.handoff.fromRunId $start.runId "Expected handoff helper to preserve fromRunId."
    Assert-Equal $handoff.handoff.summary "Ready for downstream work." "Expected handoff helper to preserve the summary."
    Assert-True ($handoff.handoff.relatedPaths -contains "worker-output.txt") "Expected handoff helper to persist related paths."
  }

  It "lets the worker status helper resolve the workspace control status file from RunId in the workspace" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "complete"

    $start = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Set up single-run status helper verification."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      RunLabel = "single-run-helper"
      ClaudePath = $fakeClaude
    }

    $updatedStatus = Invoke-JsonScript -Path $statusHelperScript -Parameters @{
      RunId = $start.runId
      Phase = "running"
      Summary = "Foreground worker updated status from the workspace."
      LastCompletedStep = "Created the first foreground artifact."
      NextStep = "Write the final report."
      Progress = 75
    } -WorkingDirectory $start.workspaceDirectory

    Assert-Equal $updatedStatus.runId $start.runId "Expected helper script to resolve the matching run id."
    Assert-Equal $updatedStatus.phase "running" "Expected helper script to update the phase from RunId."
    Assert-Equal $updatedStatus.summary "Foreground worker updated status from the workspace." "Expected helper script to update the summary from RunId."

    $status = Get-Content -LiteralPath $start.statusPath -Raw | ConvertFrom-Json
    Assert-Equal $status.summary "Foreground worker updated status from the workspace." "Expected helper script to persist the summary to the workspace control status file."
    Assert-Equal $status.progress 75 "Expected helper script to persist progress when resolving StatusPath from RunId."
  }

  It "preserves worker-authored status details when the run exits successfully" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "sleep"
    $env:FAKE_CLAUDE_SLEEP_SECONDS = "3"

    $start = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Finish after a short delay."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      RunLabel = "preserve-status"
      ClaudePath = $fakeClaude
    }

    $deadline = (Get-Date).AddSeconds(10)
    do {
      Start-Sleep -Milliseconds 250
      $status = Get-Content -LiteralPath $start.statusPath -Raw | ConvertFrom-Json
    } while ($status.phase -ne "running" -and (Get-Date) -lt $deadline)

    Assert-Equal $status.phase "running" "Expected the runner to enter the running phase before the worker helper updates status."

    Invoke-JsonScript -Path $statusHelperScript -Parameters @{
      StatusPath = $start.statusPath
      Phase = "running"
      Summary = "Landing page ready for review."
      LastCompletedStep = "Created index.html and styles.css."
      NextStep = "Open the page in a browser and verify layout."
    } | Out-Null

    $check = Invoke-JsonScript -Path $checkScript -Parameters @{
      RunId = $start.runId
      StateRoot = $stateRoot
      WaitSeconds = 10
    }

    $status = Get-Content -LiteralPath $start.statusPath -Raw | ConvertFrom-Json
    Assert-Equal $check.status "completed" "Expected delayed run to complete successfully."
    Assert-Equal $status.summary "Landing page ready for review." "Expected the worker-authored summary to be preserved."
    Assert-Equal $status.lastCompletedStep "Created index.html and styles.css." "Expected the worker-authored lastCompletedStep to be preserved."
    Assert-Equal $status.nextStep "Open the page in a browser and verify layout." "Expected the worker-authored nextStep to be preserved."

    Invoke-JsonScript -Path $cleanupScript -Parameters @{
      RunId = $start.runId
      StateRoot = $stateRoot
      Force = $true
    } | Out-Null
  }

  It "prefers Windows PowerShell for launcher hosting on Windows" -Skip:([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    . $commonScript

    $powerShellPath = Get-DispatchPowerShellPath -Platform "Windows"

    Assert-Equal (Split-Path -Leaf $powerShellPath) "powershell.exe" "Expected Windows launcher host to be powershell.exe."
  }

  It "marks an interactive workspace as trusted before launching Claude" {
    . $commonScript

    $tempRoot = New-TestTempDirectory
    $claudeConfigPath = Join-Path $tempRoot ".claude.json"
    $workspaceDirectory = "C:\Temp\dispatch-workspace"

    Set-Content -LiteralPath $claudeConfigPath -Value '{"projects":{"C:/existing":{"hasTrustDialogAccepted":false}}}' -Encoding utf8

    Ensure-DispatchWorkspaceTrust -WorkspaceDirectory $workspaceDirectory -ClaudeConfigPath $claudeConfigPath

    $config = Get-Content -LiteralPath $claudeConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    $workspaceProject = $config.projects.'C:/Temp/dispatch-workspace'
    Assert-True ($null -ne $workspaceProject) "Expected trust helper to create a project entry for the workspace."
    Assert-Equal $workspaceProject.hasTrustDialogAccepted $true "Expected trust helper to mark the workspace as trusted."
  }

  It "uses a stable source key and mirror pool root for the same source repository" {
    . $commonScript

    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"
    Initialize-TestRepository -Path $repoPath

    $firstKey = Get-DispatchStableWorkspaceKey -SourceWorkingDirectory $repoPath
    $secondKey = Get-DispatchStableWorkspaceKey -SourceWorkingDirectory ($repoPath.TrimEnd("\") + "\")
    $poolRoot = Get-MirrorPoolRoot -StateRoot $stateRoot -SourceWorkingDirectory $repoPath

    Assert-Equal $firstKey $secondKey "Expected source key to be stable for equivalent source paths."
    Assert-Match $poolRoot "\\workspaces\\_mirror\\$firstKey$" "Expected mirror pool root to include the stable source key."
  }

  It "allocates concurrent mirrorPool runs to different slots and rejects a full pool" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "sleep"
    $env:FAKE_CLAUDE_SLEEP_SECONDS = "120"

    $first = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Stay alive in mirror slot 1."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      RunLabel = "slot-a"
      WorkspaceMode = "mirrorPool"
      MirrorPoolSize = 2
      ClaudePath = $fakeClaude
    }

    $second = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Stay alive in mirror slot 2."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      RunLabel = "slot-b"
      WorkspaceMode = "mirrorPool"
      MirrorPoolSize = 2
      ClaudePath = $fakeClaude
    }

    Assert-Equal $first.workspaceMode "mirrorPool" "Expected first run to record mirrorPool mode."
    Assert-Equal $second.workspaceMode "mirrorPool" "Expected second run to record mirrorPool mode."
    Assert-NotEqual $first.mirrorSlot $second.mirrorSlot "Expected concurrent runs to occupy different mirror slots."
    Assert-Match $first.workspaceDirectory "\\slots\\$($first.mirrorSlot)\\repo$" "Expected workspace directory to be the first slot repo."
    Assert-Match $second.workspaceDirectory "\\slots\\$($second.mirrorSlot)\\repo$" "Expected workspace directory to be the second slot repo."
    Assert-True (Test-Path -LiteralPath (Join-Path $first.mirrorSlotDirectory ".slot\lock.json")) "Expected first slot lock file to exist."
    Assert-True (Test-Path -LiteralPath (Join-Path $second.mirrorSlotDirectory ".slot\lock.json")) "Expected second slot lock file to exist."

    $poolFullMessage = ""
    try {
      Invoke-JsonScript -Path $startScript -Parameters @{
        WorkingDirectory = $repoPath
        Prompt = "This should not start because the pool is full."
        DisplayMode = "hidden"
        StateRoot = $stateRoot
        RunLabel = "slot-c"
        WorkspaceMode = "mirrorPool"
        MirrorPoolSize = 2
        ClaudePath = $fakeClaude
      } | Out-Null
    } catch {
      $poolFullMessage = $_.Exception.Message
    }

    Assert-Match $poolFullMessage "Mirror pool is full" "Expected a clear pool-full error when all slots are active."

    Invoke-JsonScript -Path $stopScript -Parameters @{ RunId = $first.runId; StateRoot = $stateRoot } | Out-Null
    Invoke-JsonScript -Path $stopScript -Parameters @{ RunId = $second.runId; StateRoot = $stateRoot } | Out-Null

    Assert-Equal (Test-Path -LiteralPath (Join-Path $first.mirrorSlotDirectory ".slot\lock.json")) $false "Expected stop to release first slot lock."
    Assert-Equal (Test-Path -LiteralPath (Join-Path $second.mirrorSlotDirectory ".slot\lock.json")) $false "Expected stop to release second slot lock."
  }

  It "prevents concurrent Acquire-MirrorSlot calls from allocating the same slot" {
    $tempRoot = New-TestTempDirectory
    $stateRoot = Join-Path $tempRoot "state"
    $repoPath = Join-Path $tempRoot "repo"
    Initialize-TestRepository -Path $repoPath

    . $commonScript

    $sourceKey = Get-DispatchStableWorkspaceKey -SourceWorkingDirectory $repoPath

    # Simulate concurrent acquisition by running Acquire-MirrorSlot in parallel jobs.
    $jobs = @()
    for ($i = 1; $i -le 4; $i++) {
      $jobs += Start-Job -ScriptBlock {
        param($CommonScript, $StateRoot, $RepoPath, $RunId)
        . $CommonScript
        try {
          $result = Acquire-MirrorSlot -StateRoot $StateRoot -SourceWorkingDirectory $RepoPath -RunId $RunId -MirrorPoolSize 2
          [ordered]@{ success = $true; slot = $result.mirrorSlot; runId = $RunId }
        } catch {
          [ordered]@{ success = $false; error = $_.Exception.Message; runId = $RunId }
        }
      } -ArgumentList $commonScript, $stateRoot, $repoPath, "run-concurrent-$i"
    }

    $results = $jobs | Wait-Job -Timeout 30 | Receive-Job
    $jobs | Remove-Job -Force

    $acquiredSlots = @($results | Where-Object { $_.success } | ForEach-Object { $_.slot })
    $uniqueSlots = @($acquiredSlots | Sort-Object -Unique)

    # With MirrorPoolSize=2, at most 2 unique slots should be acquired.
    Assert-True ($acquiredSlots.Count -le 2) "Expected at most 2 slots acquired with MirrorPoolSize=2, got $($acquiredSlots.Count)."
    Assert-Equal $acquiredSlots.Count $uniqueSlots.Count "Expected all acquired slots to be unique (no duplicate slot allocation)."
  }

  It "keeps mirror slot directories during normal cleanup and removes them only when requested" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "complete"

    $first = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Finish quickly in mirror slot."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      RunLabel = "cleanup-keep-slot"
      WorkspaceMode = "mirrorPool"
      MirrorSlot = "slot-1"
      ClaudePath = $fakeClaude
    }

    Invoke-JsonScript -Path $checkScript -Parameters @{ RunId = $first.runId; StateRoot = $stateRoot; WaitSeconds = 10 } | Out-Null
    $cleanup = Invoke-JsonScript -Path $cleanupScript -Parameters @{ RunId = $first.runId; StateRoot = $stateRoot; Force = $true }

    Assert-True $cleanup.removed "Expected cleanup to remove run state."
    Assert-True (Test-Path -LiteralPath $first.mirrorSlotDirectory) "Expected default cleanup to preserve the mirror slot directory."

    $second = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Finish quickly in mirror slot again."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      RunLabel = "cleanup-remove-slot"
      WorkspaceMode = "mirrorPool"
      MirrorSlot = "slot-1"
      ClaudePath = $fakeClaude
    }

    Invoke-JsonScript -Path $checkScript -Parameters @{ RunId = $second.runId; StateRoot = $stateRoot; WaitSeconds = 10 } | Out-Null
    $cleanupRemove = Invoke-JsonScript -Path $cleanupScript -Parameters @{ RunId = $second.runId; StateRoot = $stateRoot; Force = $true; RemoveMirrorSlot = $true }

    Assert-True $cleanupRemove.removed "Expected cleanup to remove run state."
    Assert-Equal (Test-Path -LiteralPath $second.mirrorSlotDirectory) $false "Expected -RemoveMirrorSlot to remove the mirror slot directory."
  }

  It "supports incremental mirror refresh that preserves existing slot contents" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    . $commonScript

    $slotDir = Join-Path $stateRoot "test-slot"
    $repoDir = Get-MirrorSlotRepoDirectory -MirrorSlotDirectory $slotDir

    # First sync: clean
    $result1 = Sync-MirrorSlotFromSource -SourceWorkingDirectory $repoPath -MirrorSlotDirectory $slotDir -MirrorRefresh "clean"
    Assert-True (Test-Path -LiteralPath (Join-Path $repoDir "tracked.txt")) "Expected tracked.txt after clean sync."

    # Add a file that only exists in the slot (not in source)
    Set-Content -LiteralPath (Join-Path $repoDir "slot-only.txt") -Value "slot data" -Encoding utf8

    # Second sync: incremental (should NOT delete slot-only.txt)
    $result2 = Sync-MirrorSlotFromSource -SourceWorkingDirectory $repoPath -MirrorSlotDirectory $slotDir -MirrorRefresh "incremental"
    Assert-True (Test-Path -LiteralPath (Join-Path $repoDir "tracked.txt")) "Expected tracked.txt after incremental sync."
    Assert-True (Test-Path -LiteralPath (Join-Path $repoDir "slot-only.txt")) "Expected slot-only.txt to survive incremental sync."

    # Third sync: clean (should delete slot-only.txt)
    $result3 = Sync-MirrorSlotFromSource -SourceWorkingDirectory $repoPath -MirrorSlotDirectory $slotDir -MirrorRefresh "clean"
    Assert-True (Test-Path -LiteralPath (Join-Path $repoDir "tracked.txt")) "Expected tracked.txt after second clean sync."
    Assert-Equal (Test-Path -LiteralPath (Join-Path $repoDir "slot-only.txt")) $false "Expected slot-only.txt to be removed by clean sync."
  }

  It "reports mirrorPool diff from the slot repo instead of the source repository" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "touch-and-complete"
    $env:FAKE_CLAUDE_TOUCH_FILE = "worker-output.txt"

    $start = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Create a mirror-only output file."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      RunLabel = "mirror-diff"
      WorkspaceMode = "mirrorPool"
      OwnedPaths = @("worker-output.txt")
      ClaudePath = $fakeClaude
    }

    $check = Invoke-JsonScript -Path $checkScript -Parameters @{ RunId = $start.runId; StateRoot = $stateRoot; WaitSeconds = 10 }

    Assert-Equal $check.workspaceMode "mirrorPool" "Expected check output to include mirrorPool mode."
    Assert-True ($check.changedFiles.path -contains "worker-output.txt") "Expected slot repo diff to include worker-output.txt."
    Assert-Equal (Test-Path -LiteralPath (Join-Path $repoPath "worker-output.txt")) $false "Expected source repository to remain unchanged."
  }

  It "blocks hook writes to the source repository and other mirror slots" {
    $tempRoot = New-TestTempDirectory
    $sourcePath = Join-Path $tempRoot "source"
    $slotOneRepo = Join-Path $tempRoot "pool\slots\slot-1\repo"
    $slotTwoRepo = Join-Path $tempRoot "pool\slots\slot-2\repo"
    New-Item -ItemType Directory -Path $sourcePath, $slotOneRepo, $slotTwoRepo -Force | Out-Null

    $statusPath = Join-Path $tempRoot "status.json"
    $eventsPath = Join-Path $tempRoot "events.ndjson"
    $taskPath = Join-Path $slotOneRepo ".claude-dispatch\TASK.md"
    $finalReportPath = Join-Path $slotOneRepo ".claude-dispatch\final-report.md"
    New-Item -ItemType Directory -Path (Split-Path -Parent $taskPath) -Force | Out-Null
    Set-Content -LiteralPath $statusPath -Value '{"summary":"Queued","lastCompletedStep":"none"}' -Encoding utf8
    Set-Content -LiteralPath $taskPath -Value "task" -Encoding utf8
    Set-Content -LiteralPath $finalReportPath -Value "" -Encoding utf8

    $sourceWrite = @{ hook_event_name = "PreToolUse"; tool_name = "Write"; tool_input = @{ file_path = (Join-Path $sourcePath "owned.txt") } } | ConvertTo-Json -Depth 6
    $sourceOutput = $sourceWrite | & (Join-Path $scriptRoot "invoke-claude-dispatch-hook.ps1") `
      -EventName "PreToolUse" `
      -StateDirectory $tempRoot `
      -StatusPath $statusPath `
      -EventsPath $eventsPath `
      -TaskPath $taskPath `
      -FinalReportPath $finalReportPath `
      -WorkspaceDirectory $slotOneRepo `
      -OwnedPathsJson '[]' `
      -SourceWorkingDirectory $sourcePath `
      -MirrorPoolRoot (Join-Path $tempRoot "pool") `
      -MirrorSlotDirectory (Join-Path $tempRoot "pool\slots\slot-1") | Out-String

    $otherSlotWrite = @{ hook_event_name = "PreToolUse"; tool_name = "Write"; tool_input = @{ file_path = (Join-Path $slotTwoRepo "owned.txt") } } | ConvertTo-Json -Depth 6
    $otherSlotOutput = $otherSlotWrite | & (Join-Path $scriptRoot "invoke-claude-dispatch-hook.ps1") `
      -EventName "PreToolUse" `
      -StateDirectory $tempRoot `
      -StatusPath $statusPath `
      -EventsPath $eventsPath `
      -TaskPath $taskPath `
      -FinalReportPath $finalReportPath `
      -WorkspaceDirectory $slotOneRepo `
      -OwnedPathsJson '[]' `
      -SourceWorkingDirectory $sourcePath `
      -MirrorPoolRoot (Join-Path $tempRoot "pool") `
      -MirrorSlotDirectory (Join-Path $tempRoot "pool\slots\slot-1") | Out-String

    Assert-Match $sourceOutput '"permissionDecision"\s*:\s*"deny"' "Expected hook to deny writes to the source repository."
    Assert-Match $sourceOutput "source repository" "Expected source repository denial reason."
    Assert-Match $otherSlotOutput '"permissionDecision"\s*:\s*"deny"' "Expected hook to deny writes to another mirror slot."
    Assert-Match $otherSlotOutput "another mirror slot" "Expected other slot denial reason."
  }

  It "prints visible progress lines for visible hook events without breaking JSON output" {
    $tempRoot = New-TestTempDirectory
    $statusPath = Join-Path $tempRoot "status.json"
    $eventsPath = Join-Path $tempRoot "events.ndjson"
    $taskPath = Join-Path $tempRoot "TASK.md"
    $finalReportPath = Join-Path $tempRoot "final-report.md"
    $hookScript = Join-Path $scriptRoot "invoke-claude-dispatch-hook.ps1"

    Set-Content -LiteralPath $taskPath -Value "task" -Encoding utf8
    $status = [ordered]@{
      summary = "Queued"
      lastCompletedStep = "none"
      nextStep = "start"
      blockedOn = @()
      progress = 0
      heartbeatAt = "2026-06-24T00:00:00.0000000+00:00"
      updatedAt = "2026-06-24T00:00:00.0000000+00:00"
      finalReportWritten = $false
    }
    $status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusPath -Encoding utf8

    $jsonInput = '{"hook_event_name":"UserPromptSubmit","prompt":"Begin now."}'
    $output = $jsonInput | & $hookScript `
      -EventName "UserPromptSubmit" `
      -StateDirectory $tempRoot `
      -StatusPath $statusPath `
      -EventsPath $eventsPath `
      -TaskPath $taskPath `
      -FinalReportPath $finalReportPath `
      -WorkspaceDirectory "C:\Temp" `
      -OwnedPathsJson "[]" `
      -DisplayMode "visible" 6>&1 | Out-String

    Assert-Match $output '\[Claude Dispatch\] Claude accepted the task and is starting work\.' "Expected visible hook output to show that Claude started working."
    Assert-Match $output '"hookEventName"\s*:\s*"UserPromptSubmit"' "Expected hook JSON output to remain intact."
  }

  It "infers completion from final-report.md when the runner exits without a terminal status" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "complete"

    $start = Invoke-JsonScript -Path $startScript -Parameters @{
      WorkingDirectory = $repoPath
      Prompt = "Finish quickly."
      DisplayMode = "hidden"
      StateRoot = $stateRoot
      RunLabel = "infer-complete"
      ClaudePath = $fakeClaude
    }

    $metaPath = Join-Path $start.stateDirectory "run.json"
    $finalReportPath = Join-Path $start.stateDirectory "final-report.md"
    Set-Content -LiteralPath $finalReportPath -Value "summary" -Encoding utf8

    $metadata = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    $metadata.status = "running"
    $metadata.finishedAt = $null
    $metadata.exitCode = $null
    $metadata.runnerPid = $null
    $metadata.launcherPid = $null
    $metadata | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $metaPath -Encoding utf8

    $check = Invoke-JsonScript -Path $checkScript -Parameters @{
      RunId = $start.runId
      StateRoot = $stateRoot
      WaitSeconds = 0
    }

    Assert-Equal $check.status "completed" "Expected check script to infer completion from final-report.md."
    Assert-Equal $check.phase "completed" "Expected inferred completion to update the status file phase."
  }

  It "finishes an interactive run when Claude writes terminal control files but stays open" {
    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"
    $start = $null

    Initialize-TestRepository -Path $repoPath

    $env:FAKE_CLAUDE_BEHAVIOR = "complete-and-hang"
    $env:FAKE_CLAUDE_SLEEP_SECONDS = "30"

    try {
      $start = Invoke-JsonScript -Path $startScript -Parameters @{
        WorkingDirectory = $repoPath
        Prompt = "Complete and remain interactive."
        DisplayMode = "hidden"
        StateRoot = $stateRoot
        RunLabel = "interactive-terminal-control"
        WorkspaceMode = "mirrorPool"
        ClaudeRunMode = "interactive"
        ClaudePath = $fakeClaude
      }

      $check = Invoke-JsonScript -Path $checkScript -Parameters @{
        RunId = $start.runId
        StateRoot = $stateRoot
        WaitSeconds = 15
      }

      Assert-Equal $check.status "completed" "Expected runner to mark the interactive run completed from control files."
      Assert-Equal $check.phase "completed" "Expected status phase to remain completed."
      Assert-Equal $check.processAlive $false "Expected runner process to exit after control-file completion."
      Assert-Equal (Test-Path -LiteralPath (Join-Path $start.mirrorSlotDirectory ".slot\lock.json")) $false "Expected completed run to release its mirror slot."
    } finally {
      Remove-Item Env:\FAKE_CLAUDE_BEHAVIOR -ErrorAction SilentlyContinue
      Remove-Item Env:\FAKE_CLAUDE_SLEEP_SECONDS -ErrorAction SilentlyContinue
      if ($start) {
        & $stopScript -RunId $start.runId -StateRoot $stateRoot | Out-Null
      }
    }
  }

  It "waits for a visible launcher handoff before marking a starting run unknown" {
    . $commonScript

    $tempRoot = New-TestTempDirectory
    $repoPath = Join-Path $tempRoot "repo"
    $stateRoot = Join-Path $tempRoot "state"
    $runId = "launcher-handoff"
    $stateDirectory = Join-Path $stateRoot "runs\$runId"
    $workspaceDirectory = Join-Path $stateRoot "workspaces\$runId"

    Initialize-TestRepository -Path $repoPath
    New-Item -ItemType Directory -Path $stateDirectory, $workspaceDirectory -Force | Out-Null
    $statusPath = Join-Path $stateDirectory "status.json"
    $finalReportPath = Join-Path $stateDirectory "final-report.md"
    $logPath = Join-Path $stateDirectory "claude.log"
    $eventsPath = Join-Path $stateDirectory "events.ndjson"
    $metaPath = Join-Path $stateDirectory "run.json"

    New-DispatchStatus -RunId $runId -RunLabel "handoff" -BatchId "" -OwnedPaths @() -DependencyRunIds @() | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statusPath -Encoding utf8
    Set-Content -LiteralPath $finalReportPath -Value "" -Encoding utf8
    Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
    Set-Content -LiteralPath $eventsPath -Value "" -Encoding utf8

    [ordered]@{
      schemaVersion = "claude-dispatch-run/v0.4"
      runId = $runId
      runLabel = "handoff"
      status = "starting"
      startedAt = Get-DispatchTimestamp
      lastActivityAt = Get-DispatchTimestamp
      finishedAt = $null
      sourceWorkingDirectory = $repoPath
      workspaceDirectory = $workspaceDirectory
      workspaceMode = "mirrorPool"
      stateDirectory = $stateDirectory
      statusPath = $statusPath
      finalReportPath = $finalReportPath
      logPath = $logPath
      eventsPath = $eventsPath
      runnerPid = $null
      launcherPid = 999999
      exitCode = $null
      error = $null
      ownedPaths = @()
      dependencyRunIds = @()
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $metaPath -Encoding utf8

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $check = Invoke-JsonScript -Path $checkScript -Parameters @{
      RunId = $runId
      StateRoot = $stateRoot
      WaitSeconds = 2
    }
    $watch.Stop()

    Assert-True ($watch.Elapsed.TotalSeconds -ge 1.5) "Expected check to wait for the visible launcher handoff deadline before declaring unknown."
    Assert-Equal $check.status "unknown" "Expected check to mark the run unknown after the wait deadline expires."
  }
}
