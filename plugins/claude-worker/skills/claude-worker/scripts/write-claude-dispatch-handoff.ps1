param(
  [Parameter(Mandatory = $true)]
  [string]$HandoffDirectory,
  [Parameter(Mandatory = $true)]
  [string]$FromRunId,
  [string]$ToRunId = "",
  [Parameter(Mandatory = $true)]
  [string]$Summary,
  [Parameter(Mandatory = $true)]
  [string]$Message,
  [string[]]$RelatedPaths = @(),
  [string]$NextStep = ""
)

$ErrorActionPreference = "Stop"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory "claude-dispatch-common.ps1")

Ensure-Directory -Path $HandoffDirectory | Out-Null
$resolvedToRunId = if ($ToRunId) { $ToRunId } else { Split-Path -Leaf $HandoffDirectory }
$fileName = ("{0}-{1}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $FromRunId)
$path = Join-Path $HandoffDirectory $fileName

$payload = [ordered]@{
  schemaVersion = "claude-dispatch-handoff/v0.2"
  fromRunId = $FromRunId
  toRunId = $resolvedToRunId
  summary = $Summary
  message = $Message
  relatedPaths = (Normalize-PathsArray -Paths $RelatedPaths)
  nextStep = $NextStep
  createdAt = Get-DispatchTimestamp
}

Write-JsonFile -Path $path -Value $payload

[ordered]@{
  path = $path
  handoff = $payload
} | ConvertTo-Json -Depth 6
