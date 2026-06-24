param(
  [string]$StateRoot = ""
)

$ErrorActionPreference = "Stop"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory "claude-dispatch-common.ps1")

$resolvedStateRoot = Get-StateRoot -StateRoot $StateRoot
$runsRoot = Join-Path $resolvedStateRoot "runs"
$runs = @()

if (Test-Path -LiteralPath $runsRoot) {
  foreach ($runDirectory in Get-ChildItem -LiteralPath $runsRoot -Directory) {
    $metaPath = Join-Path $runDirectory.FullName "run.json"
    $metadata = Read-JsonFile -Path $metaPath
    if (-not $metadata) {
      continue
    }

    $runs += [ordered]@{
      runId = $metadata.runId
      runLabel = $metadata.runLabel
      batchId = $metadata.batchId
      status = $metadata.status
      displayMode = $metadata.displayMode
      windowTitle = $metadata.windowTitle
      startedAt = $metadata.startedAt
      finishedAt = $metadata.finishedAt
      sourceWorkingDirectory = $metadata.sourceWorkingDirectory
      workspaceDirectory = $metadata.workspaceDirectory
      workspaceMode = $metadata.workspaceMode
      workspaceKey = $metadata.workspaceKey
      mirrorSlot = $metadata.mirrorSlot
      mirrorSlotDirectory = $metadata.mirrorSlotDirectory
      mirrorSlotActive = if ($metadata.mirrorSlotDirectory) { Test-MirrorSlotActive -MirrorSlotDirectory $metadata.mirrorSlotDirectory } else { $false }
      stateDirectory = $metadata.stateDirectory
      statusPath = $metadata.statusPath
    }
  }
}

[ordered]@{
  stateRoot = $resolvedStateRoot
  runCount = $runs.Count
  runs = $runs
} | ConvertTo-Json -Depth 6
