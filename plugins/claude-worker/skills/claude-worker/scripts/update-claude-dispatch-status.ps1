param(
  [string]$StatusPath,
  [string]$RunId,
  [string]$StateRoot,
  [string]$StateDirectory,
  [string]$WorkspaceDirectory,
  [Parameter(Mandatory = $true)]
  [ValidateSet("starting", "running", "blocked", "completed", "failed", "stopped", "unknown")]
  [string]$Phase,
  [string]$Summary,
  [string]$LastCompletedStep,
  [string]$NextStep,
  [string[]]$BlockedOn = @(),
  [Nullable[int]]$Progress
)

$ErrorActionPreference = "Stop"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory "claude-dispatch-common.ps1")

$resolvedStatusPath = Resolve-DispatchStatusPath `
  -StatusPath $StatusPath `
  -RunId $RunId `
  -StateRoot $StateRoot `
  -StateDirectory $StateDirectory `
  -WorkspaceDirectory $WorkspaceDirectory `
  -WorkingDirectory (Get-Location).Path

$updateArguments = @{
  StatusPath = $resolvedStatusPath
  Phase = $Phase
}

if ($PSBoundParameters.ContainsKey("Summary")) {
  $updateArguments["Summary"] = $Summary
}
if ($PSBoundParameters.ContainsKey("LastCompletedStep")) {
  $updateArguments["LastCompletedStep"] = $LastCompletedStep
}
if ($PSBoundParameters.ContainsKey("NextStep")) {
  $updateArguments["NextStep"] = $NextStep
}
if ($PSBoundParameters.ContainsKey("BlockedOn")) {
  $updateArguments["BlockedOn"] = $BlockedOn
}
if ($PSBoundParameters.ContainsKey("Progress")) {
  $updateArguments["Progress"] = $Progress
}

Update-DispatchStatusFile @updateArguments
(Read-JsonFile -Path $resolvedStatusPath) | ConvertTo-Json -Depth 6
