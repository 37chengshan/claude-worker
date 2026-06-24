param(
  [string]$PermissionMode,
  [string]$p
)

$promptLines = @()
foreach ($item in $input) {
  if ($null -ne $item) {
    $promptLines += [string]$item
  }
}

$behavior = $env:FAKE_CLAUDE_BEHAVIOR
$positionalPrompt = ($args | Where-Object { $_ -and ($_ -notmatch "^--") } | Select-Object -Last 1)
if ($positionalPrompt) { $promptLines += [string]$positionalPrompt }
$prompt = ($promptLines -join [Environment]::NewLine)
$reportedArguments = @()
if ($PermissionMode) {
  $reportedArguments += ("PermissionMode=" + $PermissionMode)
}
if ($p) {
  $reportedArguments += ("p=" + $p)
}
if ($args.Count -gt 0) {
  $reportedArguments += ("args=" + ($args -join ","))
}
if ($env:CLAUDE_DISPATCH_FINAL_REPORT_PATH) {
  Set-Content -LiteralPath $env:CLAUDE_DISPATCH_FINAL_REPORT_PATH -Value "# Fake final report`n`nCompleted by fake Claude." -Encoding utf8
}

$preSleepSeconds = 0
if ($env:FAKE_CLAUDE_PRE_SLEEP_SECONDS) {
  $preSleepSeconds = [int]$env:FAKE_CLAUDE_PRE_SLEEP_SECONDS
}

if ($preSleepSeconds -gt 0) {
  Write-Output "pre-sleeping for $preSleepSeconds seconds"
  Start-Sleep -Seconds $preSleepSeconds
}

switch ($behavior) {
  "touch-and-complete" {
    if (-not $env:FAKE_CLAUDE_TOUCH_FILE) {
      throw "FAKE_CLAUDE_TOUCH_FILE is required for touch-and-complete."
    }

    $targetDirectory = Split-Path -Parent $env:FAKE_CLAUDE_TOUCH_FILE
    if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory)) {
      New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }

    Set-Content -LiteralPath $env:FAKE_CLAUDE_TOUCH_FILE -Value ($prompt + [Environment]::NewLine + ($reportedArguments -join [Environment]::NewLine)) -Encoding utf8
    Write-Output "created $($env:FAKE_CLAUDE_TOUCH_FILE)"
    exit 0
  }
  "sleep" {
    $seconds = [int]$env:FAKE_CLAUDE_SLEEP_SECONDS
    if ($seconds -lt 1) {
      $seconds = 30
    }

    Write-Output "sleeping for $seconds seconds"
    Start-Sleep -Seconds $seconds
    exit 0
  }
  "complete-and-hang" {
    if (-not $env:CLAUDE_DISPATCH_STATUS_PATH) {
      throw "CLAUDE_DISPATCH_STATUS_PATH is required for complete-and-hang."
    }

    $status = Get-Content -LiteralPath $env:CLAUDE_DISPATCH_STATUS_PATH -Raw | ConvertFrom-Json
    $status.phase = "completed"
    $status.summary = "Fake Claude completed but stayed interactive."
    $status.lastCompletedStep = "Wrote final report."
    $status.nextStep = $null
    $status.finalReportWritten = $true
    $status.updatedAt = (Get-Date).ToString("o")
    $status.heartbeatAt = (Get-Date).ToString("o")
    $status | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $env:CLAUDE_DISPATCH_STATUS_PATH -Encoding utf8

    $seconds = [int]$env:FAKE_CLAUDE_SLEEP_SECONDS
    if ($seconds -lt 1) {
      $seconds = 30
    }

    Write-Output "completed dispatch control files, then hanging for $seconds seconds"
    Start-Sleep -Seconds $seconds
    exit 0
  }
  "fail" {
    Write-Error "fake claude failure"
    exit 7
  }
  default {
    Write-Output ("fake claude completed" + ($(if ($reportedArguments.Count -gt 0) { " | " + ($reportedArguments -join " | ") } else { "" })))
    exit 0
  }
}
