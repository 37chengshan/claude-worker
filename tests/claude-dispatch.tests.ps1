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

Describe "Claude dispatch v2.0 scripts" {
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

    $check.status | Should -Be "completed" -Because "Expected run status to be completed."
    $check.batchId | Should -Be "batch-1" -Because "Expected batch id to be preserved."
    $check.workspaceDirectory | Should -Not -Be $repoPath -Because "Expected isolated workspace instead of source repo path."
    $check.ownedPaths | Should -Contain "src/owned.txt" -Because "Expected owned paths to include src/owned.txt."
    $check.changedFiles.path | Should -Contain "worker-output.txt" -Because "Expected changed files to include worker-output.txt."
    $check.taskPath | Should -Match '\\\.claude-dispatch\\TASK\.md$' -Because "Expected task path to live in the workspace control directory."
    $check.statusPath | Should -Match '\\\.claude-dispatch\\status\.json$' -Because "Expected status path to live in the workspace control directory."
    $check.finalReportPath | Should -Match '\\\.claude-dispatch\\final-report\.md$' -Because "Expected final report path to live in the workspace control directory."
    (Test-Path -LiteralPath $check.statusPath) | Should -BeTrue -Because "Expected status.json to exist."
    (Test-Path -LiteralPath (Join-Path $stateRoot "batches\batch-1\batch.json")) | Should -BeTrue -Because "Expected batch.json to exist."
    (Test-Path -LiteralPath (Join-Path $stateRoot "batches\batch-1\handoffs\$($start.runId)")) | Should -BeTrue -Because "Expected handoff directory to exist."
    (Test-Path -LiteralPath (Join-Path $stateRoot "batches\batch-1\runs\$($start.runId)\status.json")) | Should -BeTrue -Because "Expected canonical batch status file to exist."

    $status = Get-Content -LiteralPath $check.statusPath -Raw | ConvertFrom-Json
    $status.phase | Should -Be "completed" -Because "Expected status phase to be completed."
    $status.ownedPaths | Should -Contain "worker-output.txt" -Because "Expected status owned paths to include worker-output.txt."
    $status.blockedOn | Should -BeNullOrEmpty -Because "Expected blockedOn to be empty."

    $batch = Get-Content -LiteralPath (Join-Path $stateRoot "batches\batch-1\batch.json") -Raw | ConvertFrom-Json
    (($batch.runs | ForEach-Object { $_.runId } | Where-Object { $_ -eq $start.runId }).Count -gt 0) | Should -BeTrue -Because "Expected batch runs to include the started run."
    (($batch.runs | ForEach-Object { @($_.dependsOnRunIds) } | ForEach-Object { $_ } | Where-Object { $_ -eq "run-bootstrap" }).Count -gt 0) | Should -BeTrue -Because "Expected dependency run ids to include run-bootstrap."

    $promptText = Get-Content -LiteralPath (Join-Path $start.stateDirectory "prompt.txt") -Raw
    $taskText = Get-Content -LiteralPath $check.taskPath -Raw
    $promptText | Should -Match 'update-claude-dispatch-status\.ps1' -Because "Expected batch prompt to include the status helper path."
    $promptText | Should -Match 'write-claude-dispatch-handoff\.ps1' -Because "Expected batch prompt to include the handoff helper path."
    $promptText | Should -Match 'Status helper example:' -Because "Expected batch prompt to include the helper usage example."
    $promptText | Should -Match 'Handoff helper example:' -Because "Expected batch prompt to include the handoff usage example."
    $promptText | Should -Match 'powershell(\.exe)? .*?-File .*?update-claude-dispatch-status\.ps1' -Because "Expected batch status helper example to be shell-compatible."
    $taskText | Should -Match 'Use the workspace control directory above as the source of truth' -Because "Expected task contract to emphasize the workspace control directory."
    $taskText | Should -Match 'Write the final report to the exact final report path shown above\.' -Because "Expected task contract to emphasize the exact final report path."
    $taskText | Should -Match 'Prefer direct Read/Write/Edit updates on status\.json and final-report\.md inside the workspace control directory\.' -Because "Expected task contract to prefer direct control-file edits for foreground work."
    $taskText | Should -Match 'Workspace-root status helper shortcut: powershell(\.exe)? .*?-File .*?update-claude-dispatch-status\.ps1' -Because "Expected single-run status helper shortcut to use a shell-compatible PowerShell invocation."
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

    $windowsVisible.FilePath | Should -Be "C:\Windows\System32\wt.exe" -Because "Expected visible Windows launcher to use wt.exe."
    $windowsVisible.ArgumentList[0] | Should -Be "-w" -Because "Expected wt launcher to start with -w."
    $windowsVisible.ArgumentList | Should -Contain "nt" -Because "Expected wt launcher to include new-tab token."

    $windowsHidden = New-DispatchLauncherSpec `
      -Platform "Windows" `
      -DisplayMode "hidden" `
      -PowerShellPath "powershell.exe" `
      -RunnerArguments @("-File", "runner.ps1") `
      -WindowTitle "dispatch-hidden"

    $windowsHidden.FilePath | Should -Be "powershell.exe" -Because "Expected hidden Windows launcher to use powershell.exe."
    $windowsHidden.WindowStyle | Should -Be "Hidden" -Because "Expected hidden Windows launcher to request hidden window style."

    $macVisible = New-DispatchLauncherSpec `
      -Platform "MacOS" `
      -DisplayMode "visible" `
      -PowerShellPath "/usr/local/bin/pwsh" `
      -RunnerArguments @("-File", "/tmp/runner.ps1") `
      -WindowTitle "dispatch-mac"

    $macVisible.FilePath | Should -Be "osascript" -Because "Expected visible macOS launcher to use osascript."
    $macVisible.ArgumentList | Should -Contain "-e" -Because "Expected macOS launcher to pass AppleScript via -e."
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
    $commandLine | Should -Match '"Claude Dispatch visible-smoke"' -Because "Expected quoted window title in launcher command line."
    $commandLine | Should -Match '"C:\\Temp Folder\\workspace"' -Because "Expected quoted starting directory in launcher command line."
    $commandLine | Should -Match '"C:\\Temp Folder\\runner.ps1"' -Because "Expected quoted runner path in launcher command line."
    $commandLine | Should -Match '"C:\\Temp Folder\\prompt file.txt"' -Because "Expected quoted prompt path in launcher command line."
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

    $resolved | Should -Be $exePath -Because "Expected Windows foreground dispatch to prefer a non-PowerShell Claude launcher."
  }

  It "puts the interactive Claude prompt before flags and keeps print mode explicit" {
    . $commonScript

    $interactiveArguments = Get-DispatchClaudeArguments `
      -PermissionMode "bypassPermissions" `
      -SettingsPath "C:\Temp\settings.json" `
      -SystemPromptPath "C:\Temp\SYSTEM_PROMPT.md" `
      -ClaudeRunMode "interactive" `
      -InitialPrompt "Read TASK.md and begin."

    $interactiveArguments[0] | Should -Be "Read TASK.md and begin." -Because "Expected the interactive prompt to be the first Claude argument."
    $interactiveArguments[1] | Should -Be "--permission-mode" -Because "Expected interactive mode flags to follow the prompt."

    $printArguments = Get-DispatchClaudeArguments `
      -PermissionMode "bypassPermissions" `
      -SettingsPath "C:\Temp\settings.json" `
      -SystemPromptPath "C:\Temp\SYSTEM_PROMPT.md" `
      -ClaudeRunMode "print" `
      -InitialPrompt "Read TASK.md and begin."

    $printArguments | Should -Contain "-p" -Because "Expected print mode to include the -p flag."
    $printArguments[-1] | Should -Be "Read TASK.md and begin." -Because "Expected print mode to pass the prompt after -p."
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

      $result.TimedOut | Should -Be $true -Because "Expected command capture to report a timeout."
      $result.ExitCode | Should -Be -408 -Because "Expected timeout exit code."
      $result.StandardError | Should -Match "timed out" -Because "Expected timeout message in stderr."
      $elapsedSeconds | Should -BeLessThan 10 -Because "Expected timeout to return quickly."
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
    $runMeta | Should -Match '"displayMode"\s*:\s*"hidden"' -Because "Expected run metadata to record hidden display mode."
    $runMeta | Should -Match '"holdOnExit"\s*:\s*"always"' -Because "Expected run metadata to record holdOnExit."

    $runnerScriptText = Get-Content -LiteralPath (Join-Path $start.stateDirectory "runner.ps1") -Raw
    $runnerScriptText | Should -Match '\[string\]\$DisplayMode' -Because "Expected runner script to accept DisplayMode."
    $runnerScriptText | Should -Match '\[string\]\$HoldOnExit' -Because "Expected runner script to accept HoldOnExit."
    $runMeta | Should -Match '"windowTitle"\s*:\s*"Claude Dispatch hold-check"' -Because "Expected run metadata to record the visible window title."
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

    $list.runs.runId | Should -Contain $standalone.runId -Because "Expected standalone run to appear in list output."
    $list.runs.runId | Should -Contain $batched.runId -Because "Expected batched run to appear in list output."
    (($list.runs | Where-Object { $_.runId -eq $batched.runId }).batchId) | Should -Be "batch-2" -Because "Expected listed batched run to keep its batch id."
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

    $stop.status | Should -Be "stopped" -Because "Expected stopped status after controller stop."

    $cleanup = Invoke-JsonScript -Path $cleanupScript -Parameters @{
      RunId = $start.runId
      StateRoot = $stateRoot
      Force = $true
    }

    $cleanup.removed | Should -BeTrue -Because "Expected cleanup to remove run state."
    (Test-Path -LiteralPath $cleanup.stateDirectory) | Should -Be $false -Because "Expected state directory to be deleted."
    if ($cleanup.workspaceDirectory -and ($cleanup.workspaceDirectory -ne $cleanup.sourceWorkingDirectory)) {
      (Test-Path -LiteralPath $cleanup.workspaceDirectory) | Should -Be $false -Because "Expected isolated workspace to be deleted."
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
    (Test-Path -LiteralPath (Join-Path $batchRoot "batch.json")) | Should -BeTrue -Because "Expected batch.json to exist before cleanup."
    (Test-Path -LiteralPath (Join-Path $batchRoot "runs\$($start.runId)\status.json")) | Should -BeTrue -Because "Expected batch run status to exist before cleanup."
    (Test-Path -LiteralPath (Join-Path $batchRoot "handoffs\$($start.runId)")) | Should -BeTrue -Because "Expected batch handoff directory to exist before cleanup."

    $cleanup = Invoke-JsonScript -Path $cleanupScript -Parameters @{
      RunId = $start.runId
      StateRoot = $stateRoot
      Force = $true
    }

    $cleanup.removed | Should -BeTrue -Because "Expected cleanup to remove the batched run."
    (Test-Path -LiteralPath $batchRoot) | Should -Be $false -Because "Expected empty batch root to be deleted."
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

    $updatedStatus.phase | Should -Be "blocked" -Because "Expected helper script to update the phase."
    $updatedStatus.summary | Should -Be "Waiting for an upstream decision." -Because "Expected helper script to update the summary."
    $updatedStatus.blockedOn | Should -Contain "run-upstream" -Because "Expected helper script to persist blockedOn values."
    $updatedStatus.progress | Should -Be 75 -Because "Expected helper script to persist progress."

    $handoff = Invoke-JsonScript -Path $handoffHelperScript -Parameters @{
      HandoffDirectory = $start.handoffDirectory
      FromRunId = $start.runId
      Summary = "Ready for downstream work."
      Message = "The owned refactor is finished and downstream validation can continue."
      RelatedPaths = @("src/owned.txt", "worker-output.txt")
      NextStep = "Read my status file and continue."
    }

    (Test-Path -LiteralPath $handoff.path) | Should -BeTrue -Because "Expected handoff helper to create a handoff file."
    $handoff.handoff.fromRunId | Should -Be $start.runId -Because "Expected handoff helper to preserve fromRunId."
    $handoff.handoff.summary | Should -Be "Ready for downstream work." -Because "Expected handoff helper to preserve the summary."
    $handoff.handoff.relatedPaths | Should -Contain "worker-output.txt" -Because "Expected handoff helper to persist related paths."
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

    $updatedStatus.runId | Should -Be $start.runId -Because "Expected helper script to resolve the matching run id."
    $updatedStatus.phase | Should -Be "running" -Because "Expected helper script to update the phase from RunId."
    $updatedStatus.summary | Should -Be "Foreground worker updated status from the workspace." -Because "Expected helper script to update the summary from RunId."

    $status = Get-Content -LiteralPath $start.statusPath -Raw | ConvertFrom-Json
    $status.summary | Should -Be "Foreground worker updated status from the workspace." -Because "Expected helper script to persist the summary to the workspace control status file."
    $status.progress | Should -Be 75 -Because "Expected helper script to persist progress when resolving StatusPath from RunId."
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

    $status.phase | Should -Be "running" -Because "Expected the runner to enter the running phase before the worker helper updates status."

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
    $check.status | Should -Be "completed" -Because "Expected delayed run to complete successfully."
    $status.summary | Should -Be "Landing page ready for review." -Because "Expected the worker-authored summary to be preserved."
    $status.lastCompletedStep | Should -Be "Created index.html and styles.css." -Because "Expected the worker-authored lastCompletedStep to be preserved."
    $status.nextStep | Should -Be "Open the page in a browser and verify layout." -Because "Expected the worker-authored nextStep to be preserved."

    Invoke-JsonScript -Path $cleanupScript -Parameters @{
      RunId = $start.runId
      StateRoot = $stateRoot
      Force = $true
    } | Out-Null
  }

  It "prefers Windows PowerShell for launcher hosting on Windows" -Skip:([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    . $commonScript

    $powerShellPath = Get-DispatchPowerShellPath -Platform "Windows"

    (Split-Path -Leaf $powerShellPath) | Should -Be "powershell.exe" -Because "Expected Windows launcher host to be powershell.exe."
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
    ($null -ne $workspaceProject) | Should -BeTrue -Because "Expected trust helper to create a project entry for the workspace."
    $workspaceProject.hasTrustDialogAccepted | Should -Be $true -Because "Expected trust helper to mark the workspace as trusted."
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

    $firstKey | Should -Be $secondKey -Because "Expected source key to be stable for equivalent source paths."
    $poolRoot | Should -Match "\\workspaces\\_mirror\\$firstKey$" -Because "Expected mirror pool root to include the stable source key."
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

    $first.workspaceMode | Should -Be "mirrorPool" -Because "Expected first run to record mirrorPool mode."
    $second.workspaceMode | Should -Be "mirrorPool" -Because "Expected second run to record mirrorPool mode."
    $first.mirrorSlot | Should -Not -Be $second.mirrorSlot -Because "Expected concurrent runs to occupy different mirror slots."
    $first.workspaceDirectory | Should -Match "\\slots\\$($first.mirrorSlot)\\repo$" -Because "Expected workspace directory to be the first slot repo."
    $second.workspaceDirectory | Should -Match "\\slots\\$($second.mirrorSlot)\\repo$" -Because "Expected workspace directory to be the second slot repo."
    (Test-Path -LiteralPath (Join-Path $first.mirrorSlotDirectory ".slot\lock.json")) | Should -BeTrue -Because "Expected first slot lock file to exist."
    (Test-Path -LiteralPath (Join-Path $second.mirrorSlotDirectory ".slot\lock.json")) | Should -BeTrue -Because "Expected second slot lock file to exist."

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

    $poolFullMessage | Should -Match "Mirror pool is full" -Because "Expected a clear pool-full error when all slots are active."

    Invoke-JsonScript -Path $stopScript -Parameters @{ RunId = $first.runId; StateRoot = $stateRoot } | Out-Null
    Invoke-JsonScript -Path $stopScript -Parameters @{ RunId = $second.runId; StateRoot = $stateRoot } | Out-Null

    (Test-Path -LiteralPath (Join-Path $first.mirrorSlotDirectory ".slot\lock.json")) | Should -Be $false -Because "Expected stop to release first slot lock."
    (Test-Path -LiteralPath (Join-Path $second.mirrorSlotDirectory ".slot\lock.json")) | Should -Be $false -Because "Expected stop to release second slot lock."
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
    $acquiredSlots.Count | Should -BeLessOrEqual 2 -Because "Expected at most 2 slots acquired with MirrorPoolSize=2, got $($acquiredSlots.Count)."
    $acquiredSlots.Count | Should -Be $uniqueSlots.Count -Because "Expected all acquired slots to be unique (no duplicate slot allocation)."
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

    $cleanup.removed | Should -BeTrue -Because "Expected cleanup to remove run state."
    (Test-Path -LiteralPath $first.mirrorSlotDirectory) | Should -BeTrue -Because "Expected default cleanup to preserve the mirror slot directory."

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

    $cleanupRemove.removed | Should -BeTrue -Because "Expected cleanup to remove run state."
    (Test-Path -LiteralPath $second.mirrorSlotDirectory) | Should -Be $false -Because "Expected -RemoveMirrorSlot to remove the mirror slot directory."
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
    (Test-Path -LiteralPath (Join-Path $repoDir "tracked.txt")) | Should -BeTrue -Because "Expected tracked.txt after clean sync."

    # Add a file that only exists in the slot (not in source)
    Set-Content -LiteralPath (Join-Path $repoDir "slot-only.txt") -Value "slot data" -Encoding utf8

    # Second sync: incremental (should NOT delete slot-only.txt)
    $result2 = Sync-MirrorSlotFromSource -SourceWorkingDirectory $repoPath -MirrorSlotDirectory $slotDir -MirrorRefresh "incremental"
    (Test-Path -LiteralPath (Join-Path $repoDir "tracked.txt")) | Should -BeTrue -Because "Expected tracked.txt after incremental sync."
    (Test-Path -LiteralPath (Join-Path $repoDir "slot-only.txt")) | Should -BeTrue -Because "Expected slot-only.txt to survive incremental sync."

    # Third sync: clean (should delete slot-only.txt)
    $result3 = Sync-MirrorSlotFromSource -SourceWorkingDirectory $repoPath -MirrorSlotDirectory $slotDir -MirrorRefresh "clean"
    (Test-Path -LiteralPath (Join-Path $repoDir "tracked.txt")) | Should -BeTrue -Because "Expected tracked.txt after second clean sync."
    (Test-Path -LiteralPath (Join-Path $repoDir "slot-only.txt")) | Should -Be $false -Because "Expected slot-only.txt to be removed by clean sync."
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

    $check.workspaceMode | Should -Be "mirrorPool" -Because "Expected check output to include mirrorPool mode."
    $check.changedFiles.path | Should -Contain "worker-output.txt" -Because "Expected slot repo diff to include worker-output.txt."
    (Test-Path -LiteralPath (Join-Path $repoPath "worker-output.txt")) | Should -Be $false -Because "Expected source repository to remain unchanged."
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

    $sourceOutput | Should -Match '"permissionDecision"\s*:\s*"deny"' -Because "Expected hook to deny writes to the source repository."
    $sourceOutput | Should -Match "source repository" -Because "Expected source repository denial reason."
    $otherSlotOutput | Should -Match '"permissionDecision"\s*:\s*"deny"' -Because "Expected hook to deny writes to another mirror slot."
    $otherSlotOutput | Should -Match "another mirror slot" -Because "Expected other slot denial reason."
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

    $output | Should -Match '\[Claude Dispatch\] Claude accepted the task and is starting work\.' -Because "Expected visible hook output to show that Claude started working."
    $output | Should -Match '"hookEventName"\s*:\s*"UserPromptSubmit"' -Because "Expected hook JSON output to remain intact."
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

    $check.status | Should -Be "completed" -Because "Expected check script to infer completion from final-report.md."
    $check.phase | Should -Be "completed" -Because "Expected inferred completion to update the status file phase."
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

      $check.status | Should -Be "completed" -Because "Expected runner to mark the interactive run completed from control files."
      $check.phase | Should -Be "completed" -Because "Expected status phase to remain completed."
      $check.processAlive | Should -Be $false -Because "Expected runner process to exit after control-file completion."
      (Test-Path -LiteralPath (Join-Path $start.mirrorSlotDirectory ".slot\lock.json")) | Should -Be $false -Because "Expected completed run to release its mirror slot."
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

    $watch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 1.5 -Because "Expected check to wait for the visible launcher handoff deadline before declaring unknown."
    $check.status | Should -Be "unknown" -Because "Expected check to mark the run unknown after the wait deadline expires."
  }

  It "denies dispatch with -DisplayMode hidden through PreToolUse hook" {
    $tempRoot = New-TestTempDirectory
    $statusPath = Join-Path $tempRoot "status.json"
    $eventsPath = Join-Path $tempRoot "events.ndjson"
    $taskPath = Join-Path $tempRoot "TASK.md"
    $finalReportPath = Join-Path $tempRoot "final-report.md"
    $hookScript = Join-Path $scriptRoot "invoke-claude-dispatch-hook.ps1"

    Set-Content -LiteralPath $taskPath -Value "task" -Encoding utf8
    Set-Content -LiteralPath $statusPath -Value '{"summary":"Q","lastCompletedStep":"n","nextStep":"s","blockedOn":[],"progress":0,"heartbeatAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","finalReportWritten":false}' -Encoding utf8
    Set-Content -LiteralPath $finalReportPath -Value "" -Encoding utf8

    $jsonInput = '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"start-claude-dispatch.ps1 -DisplayMode hidden -Prompt test"}}'
    $output = $jsonInput | & $hookScript -EventName "PreToolUse" -StateDirectory $tempRoot -StatusPath $statusPath -EventsPath $eventsPath -TaskPath $taskPath -FinalReportPath $finalReportPath -WorkspaceDirectory "C:\Temp" -DisplayMode "hidden" | Out-String

    $output | Should -Match '"permissionDecision"\s*:\s*"deny"' -Because "Expected hook to deny hidden dispatch."
    $output | Should -Match "Visible terminal principle" -Because "Expected denial reason to cite visible terminal principle."
  }

  It "alignment hook respects confirmed status and allows dispatch" {
    $tempRoot = New-TestTempDirectory
    $stateRoot = Join-Path $tempRoot "state"
    $stateDir = Join-Path $stateRoot "state"
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $alignmentPath = Join-Path $stateDir "alignment.json"
    
    [ordered]@{
      status = "confirmed"
      goal = "Add feature X"
      successCriteria = "Tests pass"
      constraints = "No breaking changes"
      nonGoals = "Refactoring"
      confirmedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $alignmentPath -Encoding utf8
    
    $alignment = Get-Content -LiteralPath $alignmentPath -Raw | ConvertFrom-Json
    $alignment.status | Should -Be "confirmed" -Because "alignment.json should be confirmed"
    $alignment.goal | Should -Not -BeNullOrEmpty -Because "goal should be filled"
    $alignment.successCriteria | Should -Not -BeNullOrEmpty -Because "successCriteria should be filled"
  }

  It "wait-for-answer exits with timeout when no answer arrives" {
    $tempRoot = New-TestTempDirectory
    $questionPath = Join-Path $tempRoot "q-001.json"
    $answerPath = Join-Path $tempRoot "a-001.json"
    
    [ordered]@{
      questionId = "q-001"
      askedAt = (Get-Date).ToString("o")
      question = "REST or GraphQL?"
      options = @("REST", "GraphQL")
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $questionPath -Encoding utf8
    
    $waitScript = Join-Path $scriptRoot "wait-for-answer.ps1"
    $result = & $waitScript -QuestionPath $questionPath -AnswerPath $answerPath -TimeoutSeconds 2 -PollIntervalSeconds 1 2>&1 | Out-String
    
    $result | Should -Match "timedOut" -Because "should timeout when no answer file is created"
  }

  It "quality gate blocks stop when configured commands fail" {
    $tempRoot = New-TestTempDirectory
    $statusPath = Join-Path $tempRoot "status.json"
    $eventsPath = Join-Path $tempRoot "events.ndjson"
    $taskPath = Join-Path $tempRoot "TASK.md"
    $finalReportPath = Join-Path $tempRoot "final-report.md"
    $settingsPath = Join-Path $tempRoot "claude-settings.json"
    $hookScript = Join-Path $scriptRoot "invoke-claude-dispatch-hook.ps1"
    $controlDir = Join-Path $tempRoot "control"
    New-Item -ItemType Directory -Path $controlDir -Force | Out-Null

    Set-Content -LiteralPath $taskPath -Value "task" -Encoding utf8
    Set-Content -LiteralPath $statusPath -Value '{"summary":"Done","lastCompletedStep":"finished","nextStep":"none","blockedOn":[],"progress":100,"heartbeatAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","finalReportWritten":true}' -Encoding utf8
    Set-Content -LiteralPath $finalReportPath -Value "Final report content here." -Encoding utf8
    
    [ordered]@{
      permissions = [ordered]@{ defaultMode = "acceptEdits"; deny = @() }
      hooks = @{}
      qualityGate = [ordered]@{
        commands = @("exit 1")
        timeoutSeconds = 10
      }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $settingsPath -Encoding utf8

    $jsonInput = '{"hook_event_name":"Stop"}'
    $output = $jsonInput | & $hookScript -EventName "Stop" -StateDirectory $tempRoot -StatusPath $statusPath -EventsPath $eventsPath -TaskPath $taskPath -FinalReportPath $finalReportPath -WorkspaceDirectory $tempRoot -CommonPath $commonScript | Out-String

    $output | Should -Match '"decision"\s*:\s*"block"' -Because "quality gate failure should block stop"
    $output | Should -Match "Quality gate" -Because "block reason should mention quality gate"
  }
}
