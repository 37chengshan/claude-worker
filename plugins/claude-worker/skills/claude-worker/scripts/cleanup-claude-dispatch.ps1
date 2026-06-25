param(
  [string]$RunId,
  [string]$StateDirectory,
  [string]$StateRoot = "",
  [switch]$Force,
  [switch]$RemoveMirrorSlot
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
if (($metadata.status -in @("running", "starting")) -or $Force) {
  Stop-DispatchProcesses -Metadata $metadata
}

$workspaceMode = if ($metadata.PSObject.Properties.Name -contains "workspaceMode") { [string]$metadata.workspaceMode } else { "worktree" }
if ($workspaceMode -eq "mirrorPool") {
  Release-MirrorSlot -Metadata $metadata -RemoveMirrorSlot:$RemoveMirrorSlot
} else {
  Remove-DispatchWorktree -SourceWorkingDirectory $metadata.sourceWorkingDirectory -WorkspaceDirectory $metadata.workspaceDirectory -BranchName $metadata.worktreeBranch -Force:$Force
}
Remove-DispatchBatchArtifacts -Metadata $metadata

# Append to dispatch log
$dispatchLogPath = Join-Path $resolvedStateRoot "dispatch-log.ndjson"
$finalReportPath = if ($metadata.PSObject.Properties.Name -contains "finalReportPath") { [string]$metadata.finalReportPath } else { "" }
$finalReportContent = ""
if ($finalReportPath -and (Test-Path -LiteralPath $finalReportPath)) {
  $finalReportContent = Get-Content -LiteralPath $finalReportPath -Raw -ErrorAction SilentlyContinue
}
$hasFinalReport = -not [string]::IsNullOrWhiteSpace($finalReportContent)

$statusPath = if ($metadata.PSObject.Properties.Name -contains "statusPath") { [string]$metadata.statusPath } else { "" }
$currentStatus = if ($statusPath) { Read-JsonFile -Path $statusPath } else { $null }
$currentPhase = if ($currentStatus -and $currentStatus.phase) { [string]$currentStatus.phase } else { "unknown" }
$summary = if ($currentStatus -and $currentStatus.summary) { [string]$currentStatus.summary } else { "" }
$exitCode = if ($metadata.PSObject.Properties.Name -contains "exitCode") { $metadata.exitCode } else { $null }
$resultLabel = if ($exitCode -eq 0 -and $hasFinalReport) { "accepted" } else { "rejected" }

$logEntry = [ordered]@{
  timestamp = Get-DispatchTimestamp
  runId = [string]$metadata.runId
  runLabel = if ($metadata.PSObject.Properties.Name -contains "runLabel") { [string]$metadata.runLabel } else { "" }
  batchId = if ($metadata.PSObject.Properties.Name -contains "batchId") { [string]$metadata.batchId } else { "" }
  result = $resultLabel
  phase = $currentPhase
  exitCode = $exitCode
  summary = $summary
  workspaceMode = $workspaceMode
  sourceWorkingDirectory = [string]$metadata.sourceWorkingDirectory
  prompt = if ($metadata.PSObject.Properties.Name -contains "promptPath") {
    $pp = [string]$metadata.promptPath
    if ($pp -and (Test-Path -LiteralPath $pp)) {
      $raw = Get-Content -LiteralPath $pp -Raw -ErrorAction SilentlyContinue
      if ($raw.Length -gt 200) { $raw.Substring(0, 200) + "..." } else { $raw }
    } else { "" }
  } else { "" }
}

Add-Content -LiteralPath $dispatchLogPath -Value ($logEntry | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8

if (Test-Path -LiteralPath $StateDirectory) {
  Remove-Item -LiteralPath $StateDirectory -Recurse -Force
}

[ordered]@{
  runId = $metadata.runId
  removed = -not (Test-Path -LiteralPath $StateDirectory)
  stateDirectory = $StateDirectory
  workspaceDirectory = $metadata.workspaceDirectory
  sourceWorkingDirectory = $metadata.sourceWorkingDirectory
  workspaceMode = $workspaceMode
  mirrorSlot = $metadata.mirrorSlot
  mirrorSlotDirectory = $metadata.mirrorSlotDirectory
  mirrorSlotRemoved = if ($metadata.mirrorSlotDirectory) { -not (Test-Path -LiteralPath $metadata.mirrorSlotDirectory) } else { $false }
} | ConvertTo-Json -Depth 6
