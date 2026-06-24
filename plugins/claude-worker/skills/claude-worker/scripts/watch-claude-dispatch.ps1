param(
  [string]$RunId,
  [string]$StateRoot = "",
  [int]$IntervalSeconds = 600,
  [int]$MaxChecks = 0,
  [int]$TailLines = 20
)

$ErrorActionPreference = "Stop"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$checkScript = Join-Path $scriptDirectory "check-claude-dispatch.ps1"
if (-not $RunId) { throw "Provide -RunId." }

$checks = 0
while ($true) {
  $checks += 1
  $check = & $checkScript -RunId $RunId -StateRoot $StateRoot -WaitSeconds 0 -TailLines $TailLines | ConvertFrom-Json
  $summaryPath = Join-Path $check.stateDirectory "monitor-summary.ndjson"
  $entry = [ordered]@{
    timestamp = (Get-Date).ToString("o")
    checkNumber = $checks
    runId = $check.runId
    status = $check.status
    phase = $check.phase
    processAlive = $check.processAlive
    changedFileCount = $check.changedFileCount
    touchedFileCount = $check.touchedFileCount
    summary = if ($check.PSObject.Properties.Name -contains "summary") { $check.summary } else { $null }
    finalReportPath = $check.finalReportPath
  }
  Add-Content -LiteralPath $summaryPath -Value ($entry | ConvertTo-Json -Compress -Depth 8) -Encoding utf8
  $check | ConvertTo-Json -Depth 8
  if ($check.status -notin @("starting", "running") -or -not $check.processAlive) { break }
  if ($MaxChecks -gt 0 -and $checks -ge $MaxChecks) { break }
  Start-Sleep -Seconds $IntervalSeconds
}
