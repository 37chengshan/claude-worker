param(
  [string]$RunId,
  [string]$StateDirectory,
  [string]$StateRoot = "",
  [int]$WaitSeconds = 0,
  [int]$TailLines = 20
)

$ErrorActionPreference = "Stop"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory "claude-dispatch-common.ps1")

function Get-MetadataValue {
  param(
    $Metadata,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    $Default = $null
  )

  if ($Metadata -and ($Metadata.PSObject.Properties.Name -contains $Name)) {
    return $Metadata.$Name
  }

  return $Default
}

$resolvedStateRoot = Get-StateRoot -StateRoot $StateRoot
if (-not $StateDirectory) {
  if (-not $RunId) {
    throw "Provide -RunId or -StateDirectory."
  }

  $StateDirectory = Get-RunStateDirectory -StateRoot $resolvedStateRoot -RunId $RunId
}

$metaPath = Join-Path $StateDirectory "run.json"
$deadline = (Get-Date).AddSeconds([Math]::Max(0, $WaitSeconds))

while ($true) {
  $metadata = Read-JsonFile -Path $metaPath
  if (-not $metadata) {
    throw "Run metadata not found: $metaPath"
  }

  $processAlive = (Get-DispatchProcessAlive -Metadata $metadata -PropertyName "runnerPid") -or (Get-DispatchProcessAlive -Metadata $metadata -PropertyName "claudePid") -or (Get-DispatchProcessAlive -Metadata $metadata -PropertyName "launcherPid")
  $active = ($metadata.status -in @("starting", "running")) -and $processAlive

  if (-not $active) {
    if (($metadata.status -in @("starting", "running")) -and -not $processAlive -and -not $metadata.finishedAt) {
      $status = if ($metadata.statusPath) { Read-JsonFile -Path $metadata.statusPath } else { $null }
      $hasFinalReport = (Test-DispatchFileHasContent -Path $metadata.finalReportPath)
      $terminalPhase = if ($status) { [string]$status.phase } else { $null }
      $terminalPhaseSet = @("completed", "failed", "stopped", "blocked", "unknown")

      if ($hasFinalReport) {
        $metadata = Update-DispatchMetadata -Path $metaPath -Mutator {
          param($run)
          $run.status = "completed"
          $run.finishedAt = Get-DispatchTimestamp
          if ($null -eq $run.exitCode) {
            $run.exitCode = 0
          }
          $run.error = $null
        }

        if ($metadata.statusPath) {
          $summary = if ($status -and $status.summary) { $status.summary } else { "Claude Code finished successfully." }
          $lastCompletedStep = if ($status -and $status.lastCompletedStep) { $status.lastCompletedStep } else { "Claude Code wrote the final report." }
          $nextStep = if ($status) { $status.nextStep } else { $null }
          $progress = if ($status -and ($status.PSObject.Properties.Name -contains "progress")) { $status.progress } else { 100 }
          Update-DispatchStatusFile -StatusPath $metadata.statusPath -Phase "completed" -Summary $summary -LastCompletedStep $lastCompletedStep -NextStep $nextStep -BlockedOn @() -Progress $progress
        }
      } elseif ($terminalPhaseSet -contains $terminalPhase) {
        $metadata = Update-DispatchMetadata -Path $metaPath -Mutator {
          param($run)
          $run.status = $terminalPhase
          $run.finishedAt = Get-DispatchTimestamp
          if ($null -eq $run.exitCode) {
            $run.exitCode = if ($terminalPhase -eq "completed") { 0 } else { -1 }
          }
        }
      } elseif ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([Math]::Min(5, [int][Math]::Max(1, [Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))))
        continue
      } else {
        $metadata = Update-DispatchMetadata -Path $metaPath -Mutator {
          param($run)
          $run.status = "unknown"
          $run.finishedAt = Get-DispatchTimestamp
          $run.error = "Runner process exited without writing a terminal state."
        }

        if ($metadata.statusPath) {
          Update-DispatchStatusFile -StatusPath $metadata.statusPath -Phase "unknown" -Summary "Runner disappeared before reporting a terminal state." -LastCompletedStep "Dispatch runner stopped unexpectedly." -NextStep "Inspect logs and decide whether to retry." -BlockedOn @()
        }
      }
    }
    break
  }

  if ((Get-Date) -ge $deadline) {
    break
  }

  Start-Sleep -Seconds ([Math]::Min(5, [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)))
}

$metadata = Read-JsonFile -Path $metaPath
$processAlive = (Get-DispatchProcessAlive -Metadata $metadata -PropertyName "runnerPid") -or (Get-DispatchProcessAlive -Metadata $metadata -PropertyName "claudePid") -or (Get-DispatchProcessAlive -Metadata $metadata -PropertyName "launcherPid")
$status = if ($metadata.statusPath) { Read-JsonFile -Path $metadata.statusPath } else { $null }
$logTail = @()
$eventTail = @()
$finalReportTail = @()
$logUpdatedAt = $null

if ($metadata.logPath -and (Test-Path -LiteralPath $metadata.logPath)) {
  $logTail = @(Get-Content -LiteralPath $metadata.logPath -Tail $TailLines | ForEach-Object { ("$_" -replace "`0", "") })
  $logUpdatedAt = (Get-Item -LiteralPath $metadata.logPath).LastWriteTime.ToString("o")
}
if ($metadata.eventsPath -and (Test-Path -LiteralPath $metadata.eventsPath)) {
  $eventTail = @(Get-Content -LiteralPath $metadata.eventsPath -Tail $TailLines | ForEach-Object { ("$_" -replace "`0", "") })
}
if (Test-DispatchFileHasContent -Path $metadata.finalReportPath) {
  $finalReportTail = @(Get-Content -LiteralPath $metadata.finalReportPath -Tail $TailLines | ForEach-Object { ("$_" -replace "`0", "") })
}

$gitState = Get-DispatchGitStatus -WorkspaceDirectory $metadata.workspaceDirectory
$changedFiles = @($gitState.changedFiles)
$diffStat = @($gitState.diffStat)

$startedAt = if ($metadata.startedAt) { [datetimeoffset]::Parse($metadata.startedAt) } else { $null }
$finishedAt = if ($metadata.finishedAt) { [datetimeoffset]::Parse($metadata.finishedAt) } else { $null }
$touchedFilesSinceStart = @()

if ($startedAt -and $metadata.workspaceDirectory) {
  foreach ($entry in $changedFiles) {
    if (-not $entry.path) {
      continue
    }

    $fullPath = Join-Path $metadata.workspaceDirectory $entry.path
    if (-not (Test-Path -LiteralPath $fullPath)) {
      continue
    }

    $lastWriteTime = (Get-Item -LiteralPath $fullPath).LastWriteTime
    if ($lastWriteTime.ToUniversalTime() -ge $startedAt.UtcDateTime) {
      $touchedFilesSinceStart += [ordered]@{
        path = $entry.path
        lastWriteTime = $lastWriteTime.ToString("o")
      }
    }
  }
}

$elapsed = if ($startedAt) {
  if ($finishedAt) {
    [Math]::Round(($finishedAt - $startedAt).TotalMinutes, 1)
  } else {
    [Math]::Round(((Get-Date).ToUniversalTime() - $startedAt.UtcDateTime).TotalMinutes, 1)
  }
} else {
  $null
}

[ordered]@{
  runId = Get-MetadataValue -Metadata $metadata -Name "runId"
  runLabel = Get-MetadataValue -Metadata $metadata -Name "runLabel"
  batchId = Get-MetadataValue -Metadata $metadata -Name "batchId" -Default ""
  status = Get-MetadataValue -Metadata $metadata -Name "status"
  phase = if ($status) { $status.phase } else { $null }
  windowTitle = Get-MetadataValue -Metadata $metadata -Name "windowTitle"
  windowName = Get-MetadataValue -Metadata $metadata -Name "windowName"
  processAlive = $processAlive
  startedAt = Get-MetadataValue -Metadata $metadata -Name "startedAt"
  finishedAt = Get-MetadataValue -Metadata $metadata -Name "finishedAt"
  elapsedMinutes = $elapsed
  sourceWorkingDirectory = Get-MetadataValue -Metadata $metadata -Name "sourceWorkingDirectory"
  workspaceDirectory = Get-MetadataValue -Metadata $metadata -Name "workspaceDirectory"
  workspaceMode = Get-MetadataValue -Metadata $metadata -Name "workspaceMode" -Default "worktree"
  workspaceKey = Get-MetadataValue -Metadata $metadata -Name "workspaceKey"
  mirrorPoolRoot = Get-MetadataValue -Metadata $metadata -Name "mirrorPoolRoot"
  mirrorSlot = Get-MetadataValue -Metadata $metadata -Name "mirrorSlot"
  mirrorSlotDirectory = Get-MetadataValue -Metadata $metadata -Name "mirrorSlotDirectory"
  mirrorSlotActive = if (Get-MetadataValue -Metadata $metadata -Name "mirrorSlotDirectory") { Test-MirrorSlotActive -MirrorSlotDirectory (Get-MetadataValue -Metadata $metadata -Name "mirrorSlotDirectory") } else { $false }
  mergeMode = Get-MetadataValue -Metadata $metadata -Name "mergeMode" -Default "reviewOnly"
  stateDirectory = Get-MetadataValue -Metadata $metadata -Name "stateDirectory"
  statusPath = Get-MetadataValue -Metadata $metadata -Name "statusPath"
  logPath = Get-MetadataValue -Metadata $metadata -Name "logPath"
  eventsPath = Get-MetadataValue -Metadata $metadata -Name "eventsPath"
  taskPath = Get-MetadataValue -Metadata $metadata -Name "taskPath"
  finalReportPath = Get-MetadataValue -Metadata $metadata -Name "finalReportPath"
  claudeRunMode = Get-MetadataValue -Metadata $metadata -Name "claudeRunMode"
  runRoot = $resolvedStateRoot
  runnerPid = Get-MetadataValue -Metadata $metadata -Name "runnerPid"
  claudePid = Get-MetadataValue -Metadata $metadata -Name "claudePid"
  launcherPid = Get-MetadataValue -Metadata $metadata -Name "launcherPid"
  exitCode = Get-MetadataValue -Metadata $metadata -Name "exitCode"
  error = Get-MetadataValue -Metadata $metadata -Name "error"
  ownedPaths = Get-MetadataValue -Metadata $metadata -Name "ownedPaths" -Default @()
  dependencyRunIds = Get-MetadataValue -Metadata $metadata -Name "dependencyRunIds" -Default @()
  statusHelperPath = Get-MetadataValue -Metadata $metadata -Name "statusHelperPath"
  handoffHelperPath = Get-MetadataValue -Metadata $metadata -Name "handoffHelperPath"
  logUpdatedAt = $logUpdatedAt
  outputTail = $logTail
  eventTail = $eventTail
  finalReportTail = $finalReportTail
  changedFileCount = $changedFiles.Count
  changedFiles = $changedFiles
  touchedFileCount = $touchedFilesSinceStart.Count
  touchedFilesSinceStart = $touchedFilesSinceStart
  diffStat = $diffStat
} | ConvertTo-Json -Depth 6
