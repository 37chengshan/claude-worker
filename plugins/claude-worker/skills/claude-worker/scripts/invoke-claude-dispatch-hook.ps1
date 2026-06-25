param(
  [string]$EventName,
  [string]$StateDirectory,
  [string]$StatusPath,
  [string]$EventsPath,
  [string]$TaskPath,
  [string]$FinalReportPath,
  [string]$WorkspaceDirectory,
  [string]$OwnedPathsJson = "[]",
  [string]$SourceWorkingDirectory = "",
  [string]$MirrorPoolRoot = "",
  [string]$MirrorSlotDirectory = "",
  [ValidateSet("visible", "hidden")]
  [string]$DisplayMode = "hidden",
  [string]$CommonPath = ""
)

$ErrorActionPreference = "Stop"

if ($CommonPath -and (Test-Path -LiteralPath $CommonPath)) {
  . $CommonPath
}

function Write-VisibleProgress {
  param([string]$Message)
  if ($DisplayMode -ne "visible" -or [string]::IsNullOrWhiteSpace($Message)) { return }
  Write-Host ("[Claude Dispatch] " + $Message)
}
function Get-LeafLabel {
  param([string]$PathValue)
  if (-not $PathValue) { return "" }
  $normalized = Normalize-RelativePath -PathValue $PathValue
  if ($normalized) { return $normalized }
  return (Split-Path -Leaf $PathValue)
}
function Get-ToolSummary {
  param($InputObject)
  if (-not $InputObject) { return $null }
  $toolName = [string]$InputObject.tool_name
  $toolInput = $InputObject.tool_input

  switch ($toolName) {
    "Read" { return ("Read: " + (Get-LeafLabel -PathValue ([string]$toolInput.file_path))) }
    "Write" { return ("Write: " + (Get-LeafLabel -PathValue ([string]$toolInput.file_path))) }
    "Edit" { return ("Edit: " + (Get-LeafLabel -PathValue ([string]$toolInput.file_path))) }
    "MultiEdit" { return ("Edit: " + (Get-LeafLabel -PathValue ([string]$toolInput.file_path))) }
    "Bash" {
      $command = [string]$toolInput.command
      if (-not $command) { return "Bash: running command" }
      $compact = (($command -replace '\s+', ' ').Trim())
      if ($compact.Length -gt 80) {
        $compact = $compact.Substring(0, 80) + "..."
      }
      return ("Bash: " + $compact)
    }
    default { return $null }
  }
}
function Normalize-RelativePath {
  param([string]$PathValue)
  if (-not $PathValue) { return "" }
  $p = $PathValue -replace "\\", "/"
  $workspace = $WorkspaceDirectory -replace "\\", "/"
  if ($workspace -and $p.StartsWith($workspace)) {
    $p = $p.Substring($workspace.Length).TrimStart("/")
  }
  return $p.TrimStart("./")
}
function Is-SensitivePath {
  param([string]$PathValue)
  $p = (Normalize-RelativePath -PathValue $PathValue).ToLowerInvariant()
  return ($p -match '(^|/)\.env(\.|$|/)' -or $p -match '(^|/)(secrets?|credentials?)(/|$)' -or $p -match '(secret|credential|private[_-]?key|id_rsa)')
}
function Is-OwnedPath {
  param([string]$PathValue)
  $owned = @()
  try { $owned = @($OwnedPathsJson | ConvertFrom-Json) } catch { $owned = @() }
  if (-not $owned -or $owned.Count -eq 0) { return $true }
  $p = Normalize-RelativePath -PathValue $PathValue
  foreach ($item in $owned) {
    $o = ([string]$item -replace "\\", "/").TrimStart("./").TrimEnd("/")
    if (-not $o) { continue }
    if ($p -eq $o -or $p.StartsWith($o + "/")) { return $true }
  }
  return $false
}
function Convert-ToFullPath {
  param([string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
  try {
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
      return [System.IO.Path]::GetFullPath($PathValue)
    }
    if ($WorkspaceDirectory) {
      return [System.IO.Path]::GetFullPath((Join-Path $WorkspaceDirectory $PathValue))
    }
    return [System.IO.Path]::GetFullPath($PathValue)
  } catch {
    return $PathValue
  }
}
function Test-PathInside {
  param([string]$ChildPath, [string]$ParentPath)
  if ([string]::IsNullOrWhiteSpace($ChildPath) -or [string]::IsNullOrWhiteSpace($ParentPath)) { return $false }
  $child = (Convert-ToFullPath -PathValue $ChildPath).TrimEnd("\", "/")
  $parent = (Convert-ToFullPath -PathValue $ParentPath).TrimEnd("\", "/")
  $comparison = if ($IsWindows -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
  return ($child.Equals($parent, $comparison) -or $child.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, $comparison) -or $child.StartsWith($parent + [System.IO.Path]::AltDirectorySeparatorChar, $comparison))
}
function Get-WriteBoundaryViolation {
  param([string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
  $fullPath = Convert-ToFullPath -PathValue $PathValue
  if ($SourceWorkingDirectory -and (Test-PathInside -ChildPath $fullPath -ParentPath $SourceWorkingDirectory) -and -not (Test-PathInside -ChildPath $fullPath -ParentPath $WorkspaceDirectory)) {
    return "Dispatch mirrorPool policy blocks writing to the source repository. Write only inside the current slot repo."
  }
  if ($MirrorPoolRoot -and (Test-PathInside -ChildPath $fullPath -ParentPath $MirrorPoolRoot) -and $MirrorSlotDirectory -and -not (Test-PathInside -ChildPath $fullPath -ParentPath $MirrorSlotDirectory)) {
    return "Dispatch mirrorPool policy blocks writing to another mirror slot. Write only inside the current slot repo."
  }
  if ([System.IO.Path]::IsPathRooted($PathValue) -and $WorkspaceDirectory -and -not (Test-PathInside -ChildPath $fullPath -ParentPath $WorkspaceDirectory)) {
    return "Dispatch workspace policy blocks writing outside the assigned workspace."
  }
  return $null
}
function Deny-PreToolUse {
  param([string]$Reason)
  [ordered]@{
    hookSpecificOutput = [ordered]@{
      hookEventName = "PreToolUse"
      permissionDecision = "deny"
      permissionDecisionReason = $Reason
    }
  } | ConvertTo-Json -Depth 8
}

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) {
  $pipelineInput = @($input | ForEach-Object { [string]$_ })
  if ($pipelineInput.Count -gt 0) {
    $raw = [string]::Join([Environment]::NewLine, $pipelineInput)
  }
}
$inputObject = $null
if ($raw) {
  try { $inputObject = $raw | ConvertFrom-Json } catch { $inputObject = $null }
}
$event = if ($inputObject -and $inputObject.hook_event_name) { [string]$inputObject.hook_event_name } elseif ($EventName) { $EventName } else { "Unknown" }
if (Get-Command Append-DispatchEvent -ErrorAction SilentlyContinue) {
  Append-DispatchEvent -EventsPath $EventsPath -EventName $event -Data ([ordered]@{ toolName = if ($inputObject) { $inputObject.tool_name } else { $null }; input = $inputObject })
}

if ($event -eq "UserPromptSubmit") {
  Write-VisibleProgress -Message "Claude accepted the task and is starting work."
  [ordered]@{
    hookSpecificOutput = [ordered]@{
      hookEventName = "UserPromptSubmit"
      additionalContext = "Dispatch contract active. Read task file: $TaskPath. Update status file: $StatusPath. Write final report before stopping: $FinalReportPath."
    }
  } | ConvertTo-Json -Depth 8
  exit 0
}

if ($event -eq "PreToolUse") {
  $toolName = if ($inputObject) { [string]$inputObject.tool_name } else { "" }
  $toolInput = if ($inputObject) { $inputObject.tool_input } else { $null }

  if ($toolName -eq "Bash") {
    $cmd = [string]$toolInput.command
    if ($cmd -match '(?i)(^|[;&|]\s*)(git\s+push|npm\s+publish|pnpm\s+publish|yarn\s+publish|docker\s+push|kubectl\s+apply|terraform\s+apply)\b') {
      Deny-PreToolUse -Reason "Dispatch safety policy blocks push/publish/deploy commands."
      exit 0
    }
    if ($cmd -match '(?i)\brm\s+-(rf|fr)\b|\bsudo\s+rm\b|\bdel\s+/[sq]\b') {
      Deny-PreToolUse -Reason "Dispatch safety policy blocks destructive delete commands."
      exit 0
    }
    if ($cmd -match '(?i)(start-claude-dispatch|dispatch-claude)' -and $cmd -match '-DisplayMode\s+hidden') {
      Deny-PreToolUse -Reason "Visible terminal principle: dispatch with -DisplayMode hidden is blocked by policy. Use -DisplayMode visible (the default) unless running in a test scenario."
      exit 0
    }
  }

  $pathFields = @("file_path", "path")
  foreach ($field in $pathFields) {
    if ($toolInput -and ($toolInput.PSObject.Properties.Name -contains $field)) {
      $pathValue = [string]$toolInput.$field
      if ($pathValue -and (Is-SensitivePath -PathValue $pathValue)) {
        Deny-PreToolUse -Reason "Dispatch safety policy blocks access to secrets or credential-like files."
        exit 0
      }
      if ($toolName -in @("Write", "Edit", "MultiEdit")) {
        $boundaryViolation = Get-WriteBoundaryViolation -PathValue $pathValue
        if ($boundaryViolation) {
          Deny-PreToolUse -Reason $boundaryViolation
          exit 0
        }
      }
      if ($toolName -in @("Write", "Edit", "MultiEdit") -and $pathValue -and -not (Is-OwnedPath -PathValue $pathValue)) {
        Deny-PreToolUse -Reason "Dispatch owned-path policy blocks editing outside assigned owned paths."
        exit 0
      }
    }
  }

  $toolSummary = Get-ToolSummary -InputObject $inputObject
  if ($toolSummary) {
    Write-VisibleProgress -Message $toolSummary
  }
  exit 0
}

if ($event -eq "PostToolUse") {
  exit 0
}

if ($event -eq "Stop") {
  # Track stop-block count to prevent infinite loops when Claude cannot produce output.
  $stopBlockCountPath = if ($StateDirectory) { Join-Path $StateDirectory "stop-block-count.json" } else { $null }
  $stopBlockCount = 0
  if ($stopBlockCountPath) {
    $countData = Read-JsonFile -Path $stopBlockCountPath
    if ($countData -and $countData.count) {
      $stopBlockCount = [int]$countData.count
    }
  }
  $maxStopBlocks = 3

  $status = Read-JsonFile -Path $StatusPath
  $hasFinal = Test-DispatchFileHasContent -Path $FinalReportPath
  if (-not $hasFinal) {
    if ($stopBlockCount -ge $maxStopBlocks) {
      # Graceful degradation: allow stop after repeated blocks.
      Write-VisibleProgress -Message "Stop hook allowed exit after $maxStopBlocks blocked attempts (final-report still empty)."
    } else {
      if ($stopBlockCountPath) {
        Write-JsonFile -Path $stopBlockCountPath -Value ([ordered]@{ count = ($stopBlockCount + 1); lastBlockedAt = (Get-Date).ToString("o") })
      }
      [ordered]@{
        decision = "block"
        reason = "A non-empty final-report.md is required before this dispatch run can stop."
        hookSpecificOutput = [ordered]@{
          hookEventName = "Stop"
          additionalContext = "Write final-report.md at $FinalReportPath. Include summary, changed files, validation commands/results, risks, and remaining work. Then update status.json."
        }
      } | ConvertTo-Json -Depth 8
      exit 0
    }
  }
  if ($status -and (-not $status.summary -or -not $status.lastCompletedStep)) {
    if ($stopBlockCount -ge $maxStopBlocks) {
      Write-VisibleProgress -Message "Stop hook allowed exit after $maxStopBlocks blocked attempts (status.json incomplete)."
    } else {
      if ($stopBlockCountPath) {
        Write-JsonFile -Path $stopBlockCountPath -Value ([ordered]@{ count = ($stopBlockCount + 1); lastBlockedAt = (Get-Date).ToString("o") })
      }
      [ordered]@{
        decision = "block"
        reason = "status.json summary and lastCompletedStep must be filled before stopping."
        hookSpecificOutput = [ordered]@{
          hookEventName = "Stop"
          additionalContext = "Update $StatusPath with a concrete summary and lastCompletedStep before stopping."
        }
      } | ConvertTo-Json -Depth 8
      exit 0
    }
  }
  # Quality gate: run configured validation commands
  $settingsPath = if ($StateDirectory) { Join-Path $StateDirectory "claude-settings.json" } else { $null }
  if ($settingsPath -and (Test-Path -LiteralPath $settingsPath)) {
    $hookSettings = Read-JsonFile -Path $settingsPath
    if ($hookSettings -and $hookSettings.qualityGate -and $hookSettings.qualityGate.commands) {
      $gateCommands = @($hookSettings.qualityGate.commands)
      $gateTimeout = if ($hookSettings.qualityGate.timeoutSeconds) { [int]$hookSettings.qualityGate.timeoutSeconds } else { 300 }
      $gateFailed = $false
      $gateResults = @()

      foreach ($gateCmd in $gateCommands) {
        Write-VisibleProgress -Message "Quality gate: running $gateCmd"
        try {
          $gateOutput = ""
          if ($CommonPath -and (Test-Path -LiteralPath $CommonPath)) {
            $captureResult = Invoke-DispatchCommandCapture -CommandPath "cmd.exe" -ArgumentList @("/c", $gateCmd) -WorkingDirectory $WorkspaceDirectory -TimeoutSeconds $gateTimeout
            $gateOutput = $captureResult.StandardOutput + "`n" + $captureResult.StandardError
            if ($captureResult.ExitCode -ne 0) {
              $gateFailed = $true
              $gateResults += [ordered]@{ command = $gateCmd; exitCode = $captureResult.ExitCode; output = $gateOutput.Trim() }
            } else {
              $gateResults += [ordered]@{ command = $gateCmd; exitCode = 0; output = "(passed)" }
            }
          }
        } catch {
          $gateFailed = $true
          $gateResults += [ordered]@{ command = $gateCmd; exitCode = -1; output = $_.Exception.Message }
        }
      }

      if ($gateFailed) {
        $gateReport = ($gateResults | ForEach-Object { "- $($_.command): exit $($_.output)" }) -join "`n"
        if ($FinalReportPath -and (Test-Path -LiteralPath $FinalReportPath)) {
          $existingReport = Get-Content -LiteralPath $FinalReportPath -Raw -ErrorAction SilentlyContinue
          $gateSection = "`n`n## Quality Gate Failures`n`n$gateReport`n"
          Set-Content -LiteralPath $FinalReportPath -Value ($existingReport + $gateSection) -Encoding utf8
        }
        if ($StatusPath) {
          $gateStatus = Read-JsonFile -Path $StatusPath
          if ($gateStatus) {
            $gateStatus.phase = "failed"
            $gateStatus.summary = "Quality gate failed: " + (($gateResults | Where-Object { $_.exitCode -ne 0 } | ForEach-Object { $_.command }) -join ", ")
            Write-JsonFile -Path $StatusPath -Value $gateStatus
          }
        }
        if ($stopBlockCountPath) {
          Write-JsonFile -Path $stopBlockCountPath -Value ([ordered]@{ count = ($stopBlockCount + 1); lastBlockedAt = (Get-Date).ToString("o") })
        }
        [ordered]@{
          decision = "block"
          reason = "Quality gate failed. Fix the issues and update final-report.md with resolution."
          hookSpecificOutput = [ordered]@{
            hookEventName = "Stop"
            additionalContext = "Quality gate failures:`n$gateReport`nFix these issues and re-validate before stopping."
          }
        } | ConvertTo-Json -Depth 8
        exit 0
      }
      Write-VisibleProgress -Message "Quality gate: all commands passed."
    }
  }

  Write-VisibleProgress -Message "Claude finished and wrote the final report."
  exit 0
}

# MessageDisplay and all other side-effect-only events: log and allow.
if ($event -eq "MessageDisplay" -and $inputObject -and $inputObject.message) {
  $messageText = [string]$inputObject.message
  if ($messageText) {
    $singleLine = (($messageText -replace '\s+', ' ').Trim())
    if ($singleLine.Length -gt 120) {
      $singleLine = $singleLine.Substring(0, 120) + "..."
    }
    Write-VisibleProgress -Message $singleLine
  }
}
exit 0
