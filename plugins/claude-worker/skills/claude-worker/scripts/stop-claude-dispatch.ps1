param(
  [string]$RunId,
  [string]$StateDirectory,
  [string]$StateRoot = ""
)

$ErrorActionPreference = "Stop"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory "claude-dispatch-common.ps1")

$resolvedStateRoot = Get-StateRoot -StateRoot $StateRoot
if (-not $StateDirectory) {
  if (-not $RunId) {
    throw "Provide -RunId or -StateDirectory."
  }

  $StateDirectory = Get-RunStateDirectory -StateRoot $resolvedStateRoot -RunId $RunId
}

$metadata = Load-DispatchMetadata -StateDirectory $StateDirectory
Stop-DispatchProcesses -Metadata $metadata
Release-MirrorSlot -Metadata $metadata

$metaPath = Join-Path $StateDirectory "run.json"
$updated = Update-DispatchMetadata -Path $metaPath -Mutator {
  param($run)
  $run.status = "stopped"
  $run.finishedAt = Get-DispatchTimestamp
  $run.exitCode = -2
  $run.error = "Stopped by controller."
}

Update-DispatchStatusFile -StatusPath $updated.statusPath -Phase "stopped" -Summary "Stopped by controller." -LastCompletedStep "Controller terminated the run." -NextStep $null -BlockedOn @()

[ordered]@{
  runId = $updated.runId
  status = $updated.status
  stateDirectory = $updated.stateDirectory
  workspaceDirectory = $updated.workspaceDirectory
  sourceWorkingDirectory = $updated.sourceWorkingDirectory
  workspaceMode = $updated.workspaceMode
  mirrorSlot = $updated.mirrorSlot
  mirrorSlotDirectory = $updated.mirrorSlotDirectory
} | ConvertTo-Json -Depth 6
