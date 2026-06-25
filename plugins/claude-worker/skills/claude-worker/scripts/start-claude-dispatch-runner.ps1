param(
  [string]$MetaPath,
  [string]$CommonPath,
  [string]$PromptPath,
  [string]$TaskPath,
  [string]$LogPath,
  [string]$EventsPath,
  [string]$FinalReportPath,
  [string]$SettingsPath,
  [string]$SystemPromptPath,
  [string]$WorkingDirectory,
  [string]$PermissionMode,
  [string]$ClaudePath,
  [string]$ClaudeRunMode,
  [string]$DisplayMode,
  [string]$HoldOnExit
)

$ErrorActionPreference = "Stop"
. $CommonPath

$metadata = Read-JsonFile -Path $MetaPath
if (-not $metadata) {
  throw "Run metadata not found: $MetaPath"
}

Update-DispatchMetadata -Path $MetaPath -Mutator {
  param($run)
  $run.status = "running"
  $run.runnerPid = $PID
} | Out-Null

if ($metadata.workspaceMode -eq "mirrorPool" -and $metadata.mirrorSlotDirectory) {
  $lockPath = Get-MirrorSlotLockPath -MirrorSlotDirectory $metadata.mirrorSlotDirectory
  $lock = Read-JsonFile -Path $lockPath
  if ($lock -and ([string]$lock.runId -eq [string]$metadata.runId)) {
    $lock.pid = $PID
    Write-JsonFile -Path $lockPath -Value $lock
  }
}

Update-DispatchStatusFile -StatusPath $metadata.statusPath -Phase "running" -Summary "Claude Code is actively working." -LastCompletedStep "Dispatch process started." -NextStep "Inspect files, implement changes, and report progress." -BlockedOn @()

if ($WorkingDirectory) {
  Set-Location -LiteralPath $WorkingDirectory
}

function Test-TerminalControlFiles {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StatusPath,
    [Parameter(Mandatory = $true)]
    [string]$FinalReportPath
  )

  $status = Read-JsonFile -Path $StatusPath
  if (-not $status) {
    return $null
  }

  $phase = [string]$status.phase
  if ($phase -notin @("completed", "failed", "blocked")) {
    return $null
  }

  if (-not (Test-Path -LiteralPath $FinalReportPath)) {
    return $null
  }

  $finalReport = Get-Content -LiteralPath $FinalReportPath -Raw -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($finalReport)) {
    return $null
  }

  return [ordered]@{
    phase = $phase
    status = $status
  }
}

function Start-InteractiveClaudeProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ClaudeExecutablePath,
    [Parameter(Mandatory = $true)]
    [object[]]$ClaudeArguments
  )

  $filePath = $ClaudeExecutablePath
  $argumentList = @($ClaudeArguments)
  if ([System.IO.Path]::GetExtension($ClaudeExecutablePath) -ieq ".ps1") {
    $filePath = (Get-Process -Id $PID).Path
    $powerShellArguments = @("-NoLogo", "-NoProfile")
    if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
      $powerShellArguments += @("-ExecutionPolicy", "Bypass")
    }
    $argumentList = $powerShellArguments + @("-File", $ClaudeExecutablePath) + @($ClaudeArguments)
  }

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $filePath
  $startInfo.Arguments = Join-ProcessArgumentList -Arguments $argumentList
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $false
  $startInfo.RedirectStandardError = $false
  $startInfo.RedirectStandardInput = $false
  $startInfo.CreateNoWindow = $false
  if ($WorkingDirectory) {
    $startInfo.WorkingDirectory = $WorkingDirectory
  }

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  $null = $process.Start()
  return $process
}

try {
  $initialPrompt = "Read and follow the dispatch task file at: $TaskPath`nUse the workspace control directory from that task file as the source of truth for status.json and final-report.md.`nDo not assume status.json or final-report.md exist in the workspace root.`nBegin now."
  $env:CLAUDE_DISPATCH_STATE_DIR = $metadata.stateDirectory
  $env:CLAUDE_DISPATCH_STATUS_PATH = $metadata.statusPath
  $env:CLAUDE_DISPATCH_EVENTS_PATH = $metadata.eventsPath
  $env:CLAUDE_DISPATCH_TASK_PATH = $metadata.taskPath
  $env:CLAUDE_DISPATCH_FINAL_REPORT_PATH = $metadata.finalReportPath
  Append-DispatchEvent -EventsPath $metadata.eventsPath -EventName "RunnerInvokingClaude" -Data ([ordered]@{ claudeRunMode = $ClaudeRunMode; permissionMode = $PermissionMode; taskPath = $TaskPath })

  $claudeArguments = Get-DispatchClaudeArguments `
    -PermissionMode $PermissionMode `
    -SettingsPath $SettingsPath `
    -SystemPromptPath $SystemPromptPath `
    -ClaudeRunMode $ClaudeRunMode `
    -InitialPrompt $initialPrompt
  if ($ClaudeRunMode -eq "print") {
    & $ClaudePath @claudeArguments 2>&1 | Tee-Object -FilePath $LogPath -Append
    $exitCode = if ($LASTEXITCODE -eq $null) { 0 } else { $LASTEXITCODE }
  } else {
    $claudeProcess = Start-InteractiveClaudeProcess -ClaudeExecutablePath $ClaudePath -ClaudeArguments $claudeArguments
    Update-DispatchMetadata -Path $MetaPath -Mutator {
      param($run)
      $run.claudePid = $claudeProcess.Id
    } | Out-Null
    Append-DispatchEvent -EventsPath $metadata.eventsPath -EventName "RunnerClaudeProcessStarted" -Data ([ordered]@{ pid = $claudeProcess.Id })

    $terminalSignal = $null
    $exitCode = $null

    # Event-driven monitoring with FileSystemWatcher
    $watcher = $null
    try {
      $controlDir = Split-Path -Parent $metadata.statusPath
      if ($controlDir -and (Test-Path -LiteralPath $controlDir)) {
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $controlDir
        $watcher.Filter = "*.json"
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName
        $watcher.EnableRaisingEvents = $true
      }

      $checkInterval = 500  # ms fallback poll
      $elapsed = [System.Diagnostics.Stopwatch]::StartNew()

      while ($true) {
        if ($claudeProcess.HasExited) {
          $exitCode = $claudeProcess.ExitCode
          break
        }

        # Wait for filesystem event or fallback timeout
        $eventReceived = $false
        if ($watcher) {
          $result = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::Changed -bor [System.IO.WatcherChangeTypes]::Created, $checkInterval)
          if (-not $result.TimedOut) {
            $eventReceived = $true
          }
        } else {
          Start-Sleep -Milliseconds $checkInterval
        }

        # Check terminal control files on event or periodic fallback
        $terminalSignal = Test-TerminalControlFiles -StatusPath $metadata.statusPath -FinalReportPath $metadata.finalReportPath
        if ($terminalSignal) {
          $exitCode = if ($terminalSignal.phase -eq "completed") { 0 } else { 1 }
          Append-DispatchEvent -EventsPath $metadata.eventsPath -EventName "RunnerObservedTerminalControlFiles" -Data ([ordered]@{ phase = $terminalSignal.phase; pid = $claudeProcess.Id; eventDriven = $eventReceived })
          if (-not $claudeProcess.HasExited) {
            Stop-Process -Id $claudeProcess.Id -Force -ErrorAction SilentlyContinue
            [void]$claudeProcess.WaitForExit(5000)
            Append-DispatchEvent -EventsPath $metadata.eventsPath -EventName "RunnerStoppedInteractiveClaude" -Data ([ordered]@{ pid = $claudeProcess.Id; phase = $terminalSignal.phase })
          }
          break
        }
      }
    } finally {
      if ($watcher) {
        $watcher.Dispose()
      }
    }
  }
  Append-DispatchEvent -EventsPath $metadata.eventsPath -EventName "RunnerClaudeExited" -Data ([ordered]@{ exitCode = $exitCode })

  Update-DispatchMetadata -Path $MetaPath -Mutator {
    param($run)
    $run.exitCode = $exitCode
    $run.finishedAt = Get-DispatchTimestamp
    $run.status = if ($exitCode -eq 0) { "completed" } else { "failed" }
    $run.claudePid = $null
  } | Out-Null

  $currentStatus = Read-JsonFile -Path $metadata.statusPath
  if ($exitCode -eq 0) {
    $summary = "Claude Code finished successfully."
    $lastCompletedStep = "Claude Code exited successfully."
    $nextStep = $null

    if ($currentStatus) {
      if ($currentStatus.summary -and $currentStatus.summary -ne "Claude Code is actively working.") {
        $summary = $currentStatus.summary
      }
      if ($currentStatus.lastCompletedStep) {
        $lastCompletedStep = $currentStatus.lastCompletedStep
      }
      if ($currentStatus.nextStep -and $currentStatus.nextStep -ne "Inspect files, implement changes, and report progress.") {
        $nextStep = $currentStatus.nextStep
      }
    }

    Update-DispatchStatusFile -StatusPath $metadata.statusPath -Phase "completed" -Summary $summary -LastCompletedStep $lastCompletedStep -NextStep $nextStep -BlockedOn @()
  } else {
    $summary = "Claude Code exited with a non-zero code."
    $lastCompletedStep = "Claude Code exited with failure."
    $nextStep = "Inspect logs and decide whether to retry."

    if ($currentStatus) {
      if ($currentStatus.summary -and $currentStatus.summary -ne "Claude Code is actively working.") {
        $summary = $currentStatus.summary
      }
      if ($currentStatus.lastCompletedStep) {
        $lastCompletedStep = $currentStatus.lastCompletedStep
      }
      if ($currentStatus.nextStep -and $currentStatus.nextStep -ne "Inspect files, implement changes, and report progress.") {
        $nextStep = $currentStatus.nextStep
      }
    }

    Update-DispatchStatusFile -StatusPath $metadata.statusPath -Phase "failed" -Summary $summary -LastCompletedStep $lastCompletedStep -NextStep $nextStep -BlockedOn @()
  }

  if ($metadata.workspaceMode -eq "mirrorPool") {
    Release-MirrorSlot -Metadata $metadata
  }

  $shouldHold = $false
  if ($DisplayMode -eq "visible") {
    if ($HoldOnExit -eq "always") {
      $shouldHold = $true
    } elseif ($HoldOnExit -eq "onFailure" -and $exitCode -ne 0) {
      $shouldHold = $true
    }
  }

  if ($shouldHold) {
    Write-Host ""
    Write-Host "Claude dispatch finished. Press Enter to close this window."
    [void](Read-Host)
  }

  exit $exitCode
} catch {
  $_ | Out-String | Add-Content -LiteralPath $LogPath -Encoding utf8
  Append-DispatchEvent -EventsPath $metadata.eventsPath -EventName "RunnerException" -Data ([ordered]@{ message = $_.Exception.Message })

  Update-DispatchMetadata -Path $MetaPath -Mutator {
    param($run)
    $run.exitCode = -1
    $run.finishedAt = Get-DispatchTimestamp
    $run.status = "failed"
    $run.error = $_.Exception.Message
    $run.claudePid = $null
  } | Out-Null

  $currentStatus = Read-JsonFile -Path $metadata.statusPath
  $summary = "Runner hit an exception."
  $lastCompletedStep = "Runner process threw an exception."
  $nextStep = "Inspect logs and decide whether to retry."

  if ($currentStatus) {
    if ($currentStatus.summary -and $currentStatus.summary -ne "Claude Code is actively working.") {
      $summary = $currentStatus.summary
    }
    if ($currentStatus.lastCompletedStep) {
      $lastCompletedStep = $currentStatus.lastCompletedStep
    }
    if ($currentStatus.nextStep -and $currentStatus.nextStep -ne "Inspect files, implement changes, and report progress.") {
      $nextStep = $currentStatus.nextStep
    }
  }

  Update-DispatchStatusFile -StatusPath $metadata.statusPath -Phase "failed" -Summary $summary -LastCompletedStep $lastCompletedStep -NextStep $nextStep -BlockedOn @()

  if ($metadata.workspaceMode -eq "mirrorPool") {
    Release-MirrorSlot -Metadata $metadata
  }

  if ($DisplayMode -eq "visible" -and ($HoldOnExit -eq "always" -or $HoldOnExit -eq "onFailure")) {
    Write-Host ""
    Write-Host "Claude dispatch failed. Press Enter to close this window."
    [void](Read-Host)
  }

  exit 1
}
