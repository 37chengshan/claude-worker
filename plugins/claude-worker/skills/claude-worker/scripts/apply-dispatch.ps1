param(
  [Parameter(Mandatory = $true)]
  [string]$RunId,
  [string]$StateRoot = "",
  [string]$StateDirectory = "",
  [switch]$DryRun
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
if (-not $metadata) {
  throw "Run metadata not found in: $StateDirectory"
}

$sourceDir = [string]$metadata.sourceWorkingDirectory
$workspaceDir = [string]$metadata.workspaceDirectory
$workspaceMode = if ($metadata.PSObject.Properties.Name -contains "workspaceMode") { [string]$metadata.workspaceMode } else { "worktree" }

if (-not $sourceDir -or -not (Test-Path -LiteralPath $sourceDir)) {
  throw "Source working directory not found: $sourceDir"
}

# Determine the diff source (slot repo for mirrorPool, workspace for worktree)
$diffSource = $workspaceDir
if ($workspaceMode -eq "mirrorPool" -and $metadata.mirrorSlotDirectory) {
  $slotRepoDir = Get-MirrorSlotRepoDirectory -MirrorSlotDirectory ([string]$metadata.mirrorSlotDirectory)
  if (Test-Path -LiteralPath $slotRepoDir) {
    $diffSource = $slotRepoDir
  }
}

# Generate patch from the diff
Push-Location $diffSource
try {
  $diffOutput = & git diff HEAD 2>&1 | Out-String
  $changedFiles = & git diff --name-only HEAD 2>&1 | Out-String
  $untrackedFiles = & git ls-files --others --exclude-standard 2>&1 | Out-String
  # Note: stagedDiff intentionally omitted — apply only targets working tree changes
} finally {
  Pop-Location
}

$allChangedFiles = @()
if ($changedFiles) { $allChangedFiles += ($changedFiles -split "`n" | Where-Object { $_.Trim() }) }
if ($untrackedFiles) { $allChangedFiles += ($untrackedFiles -split "`n" | Where-Object { $_.Trim() }) }

# Load validation results from final-report.md if available
$validationSummary = ""
$finalReportPath = [string]$metadata.finalReportPath
if ($finalReportPath -and (Test-Path -LiteralPath $finalReportPath)) {
  $reportContent = Get-Content -LiteralPath $finalReportPath -Raw -ErrorAction SilentlyContinue
  if ($reportContent) {
    $validationLines = $reportContent -split "`n" | Where-Object { $_ -match '(test|valid|pass|fail|check)' }
    $validationSummary = ($validationLines | Select-Object -First 5) -join "; "
  }
}

# Build commit message
$changedFilesList = if ($allChangedFiles.Count -gt 0) { $allChangedFiles -join ", " } else { "(no changes)" }
$commitMessage = @"
dispatch($RunId): apply worker changes

Dispatch run: $RunId
Worker completed: $(Get-DispatchTimestamp)
Changed files: $changedFilesList
Validation: $(if ($validationSummary) { $validationSummary } else { "(none recorded)" })
"@

if ($DryRun) {
  Write-Host "=== DRY RUN: Dispatch Apply ==="
  Write-Host ""
  Write-Host "Source: $sourceDir"
  Write-Host "Diff from: $diffSource"
  Write-Host "Workspace mode: $workspaceMode"
  Write-Host ""
  Write-Host "=== Changed Files ==="
  Write-Host $changedFilesList
  Write-Host ""
  Write-Host "=== Commit Message Preview ==="
  Write-Host $commitMessage
  Write-Host ""
  Write-Host "=== Diff Preview (first 200 lines) ==="
  $diffLines = $diffOutput -split "`n" | Select-Object -First 200
  Write-Host ($diffLines -join "`n")
  if ($allChangedFiles.Count -gt 200) {
    Write-Host "... (truncated)"
  }
  Write-Host ""
  Write-Host "Run without -DryRun to apply changes."

  [ordered]@{
    dryRun = $true
    runId = $RunId
    sourceDirectory = $sourceDir
    diffSource = $diffSource
    changedFiles = $allChangedFiles
    commitMessage = $commitMessage
  } | ConvertTo-Json -Depth 6
  exit 0
}

# Apply the patch to source repository
Push-Location $sourceDir
try {
  if ($diffOutput -and -not [string]::IsNullOrWhiteSpace($diffOutput)) {
    $patchFile = Join-Path ([System.IO.Path]::GetTempPath()) ("dispatch-apply-" + [guid]::NewGuid().ToString("N") + ".patch")
    try {
      Set-Content -LiteralPath $patchFile -Value $diffOutput -Encoding utf8
      & git apply $patchFile 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        # Try with --3way for better merge handling
        & git apply --3way $patchFile 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          throw "git apply failed. Resolve conflicts manually."
        }
      }
    } finally {
      if (Test-Path -LiteralPath $patchFile) {
        Remove-Item -LiteralPath $patchFile -Force
      }
    }
  }

  # Stage and commit
  & git add -A 2>&1 | Out-Null
  & git commit -m $commitMessage 2>&1 | Out-String
} finally {
  Pop-Location
}

Write-Host "Dispatch $RunId applied successfully."
Write-Host "Changed files: $changedFilesList"

[ordered]@{
  runId = $RunId
  applied = $true
  sourceDirectory = $sourceDir
  changedFiles = $allChangedFiles
  commitMessage = $commitMessage
} | ConvertTo-Json -Depth 6
