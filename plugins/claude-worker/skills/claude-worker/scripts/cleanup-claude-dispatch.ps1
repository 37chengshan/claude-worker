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
