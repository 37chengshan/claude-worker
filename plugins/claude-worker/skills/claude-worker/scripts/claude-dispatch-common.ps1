Set-StrictMode -Version Latest

function Get-DispatchTimestamp {
  return (Get-Date).ToString("o")
}

function Get-DispatchPlatform {
  param(
    [string]$PlatformOverride
  )

  if ($PlatformOverride) {
    return $PlatformOverride
  }

  $platform = [System.Environment]::OSVersion.Platform
  if ($platform -eq [System.PlatformID]::MacOSX) {
    return "MacOS"
  }

  if ([System.IO.File]::Exists("/System/Library/CoreServices/SystemVersion.plist")) {
    return "MacOS"
  }

  if ($platform -eq [System.PlatformID]::Unix) {
    return "Linux"
  }

  return "Windows"
}

function ConvertTo-JsonText {
  param(
    [Parameter(Mandatory = $true)]
    $Value
  )

  return ($Value | ConvertTo-Json -Depth 8 -Compress)
}

function Join-ProcessArgumentList {
  param(
    [AllowNull()]
    [object[]]$Arguments
  )

  $parts = @()
  foreach ($argument in @($Arguments)) {
    if ($null -eq $argument) {
      $parts += '""'
      continue
    }

    $text = [string]$argument
    if ($text -eq "") {
      $parts += '""'
      continue
    }

    if ($text -match '[\s"]') {
      $escaped = $text -replace '(\\*)"', '$1$1\"'
      $escaped = $escaped -replace '(\\+)$', '$1$1'
      $parts += '"' + $escaped + '"'
    } else {
      $parts += $text
    }
  }

  return [string]::Join(" ", $parts)
}

function Start-DispatchProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [AllowNull()]
    [object[]]$ArgumentList = @(),
    [string]$WindowStyle
  )

  $startProcessSplat = @{
    FilePath = $FilePath
    PassThru = $true
  }

  if ($PSBoundParameters.ContainsKey("ArgumentList")) {
    $startProcessSplat["ArgumentList"] = (Join-ProcessArgumentList -Arguments $ArgumentList)
  }

  if ($WindowStyle) {
    $startProcessSplat["WindowStyle"] = $WindowStyle
  }

  return (Start-Process @startProcessSplat)
}

function Invoke-NativeProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [AllowNull()]
    [object[]]$ArgumentList = @(),
    [string]$WorkingDirectory,
    [int]$TimeoutSeconds = 0
  )

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = Join-ProcessArgumentList -Arguments $ArgumentList
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

  if ($WorkingDirectory) {
    $startInfo.WorkingDirectory = $WorkingDirectory
  }

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  $null = $process.Start()

  if ($TimeoutSeconds -gt 0) {
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
      try {
        $process.Kill()
      } catch {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
      }
      [void]$process.WaitForExit(5000)

      $standardOutput = $process.StandardOutput.ReadToEnd()
      $standardError = $process.StandardError.ReadToEnd()
      if ($standardError) {
        $standardError += [Environment]::NewLine
      }
      $standardError += "Process timed out after $TimeoutSeconds second(s)."

      return [ordered]@{
        ExitCode = -408
        StandardOutput = $standardOutput
        StandardError = $standardError
        TimedOut = $true
      }
    }

    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()

    return [ordered]@{
      ExitCode = $process.ExitCode
      StandardOutput = $standardOutput
      StandardError = $standardError
      TimedOut = $false
    }
  }

  # Read streams before WaitForExit to prevent deadlock when child output
  # exceeds OS pipe buffer (~64KB). The timeout branch above already handles
  # stuck processes; for unbounded calls, ReadToEnd drains the pipe while the
  # child writes, then WaitForExit returns immediately.
  $standardOutput = $process.StandardOutput.ReadToEnd()
  $standardError = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

  return [ordered]@{
    ExitCode = $process.ExitCode
    StandardOutput = $standardOutput
    StandardError = $standardError
    TimedOut = $false
  }
}

function Invoke-DispatchCommandCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommandPath,
    [AllowNull()]
    [object[]]$ArgumentList = @(),
    [string]$WorkingDirectory,
    [string]$PowerShellPath,
    [int]$TimeoutSeconds = 0
  )

  if ($CommandPath -match '\.ps1$') {
    $resolvedPowerShellPath = if ($PowerShellPath) {
      $PowerShellPath
    } else {
      Get-DispatchPowerShellPath -Platform (Get-DispatchPlatform)
    }

    return Invoke-NativeProcess `
      -FilePath $resolvedPowerShellPath `
      -ArgumentList (@("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $CommandPath) + $ArgumentList) `
      -WorkingDirectory $WorkingDirectory `
      -TimeoutSeconds $TimeoutSeconds
  }

  return Invoke-NativeProcess -FilePath $CommandPath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
}

function Get-StateRoot {
  param(
    [string]$StateRoot
  )

  if ($StateRoot) {
    $resolvedStateRoot = Resolve-Path -LiteralPath $StateRoot -ErrorAction SilentlyContinue
    if ($resolvedStateRoot) {
      return $resolvedStateRoot.Path
    }

    return $StateRoot
  }

  return (Join-Path ([System.IO.Path]::GetTempPath()) "codex-claude-dispatch")
}

function Ensure-Directory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  return $Path
}

function Read-JsonFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    $Value
  )

  $directory = Split-Path -Parent $Path
  if ($directory) {
    Ensure-Directory -Path $directory | Out-Null
  }

  $tempPath = "{0}.tmp-{1}" -f $Path, ([guid]::NewGuid().ToString("N"))
  $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tempPath -Encoding utf8
  Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Append-DispatchEvent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$EventsPath,
    [Parameter(Mandatory = $true)]
    [string]$EventName,
    [AllowNull()]
    $Data
  )

  $directory = Split-Path -Parent $EventsPath
  if ($directory) {
    Ensure-Directory -Path $directory | Out-Null
  }

  $event = [ordered]@{
    timestamp = Get-DispatchTimestamp
    event = $EventName
    data = $Data
  }
  Add-Content -LiteralPath $EventsPath -Value (ConvertTo-JsonText -Value $event) -Encoding utf8
}

function Get-RunStateDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateRoot,
    [Parameter(Mandatory = $true)]
    [string]$RunId
  )

  return (Join-Path (Join-Path $StateRoot "runs") $RunId)
}

function Get-WorkspacesRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateRoot
  )

  return (Join-Path $StateRoot "workspaces")
}

function Get-MirrorWorkspacesRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateRoot
  )

  return (Join-Path (Get-WorkspacesRoot -StateRoot $StateRoot) "_mirror")
}

function Get-MirrorPoolRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateRoot,
    [Parameter(Mandatory = $true)]
    [string]$SourceWorkingDirectory
  )

  $sourceKey = Get-DispatchStableWorkspaceKey -SourceWorkingDirectory $SourceWorkingDirectory
  return (Join-Path (Get-MirrorWorkspacesRoot -StateRoot $StateRoot) $sourceKey)
}

function Get-WorkspaceDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateRoot,
    [Parameter(Mandatory = $true)]
    [string]$RunId
  )

  return (Join-Path (Get-WorkspacesRoot -StateRoot $StateRoot) $RunId)
}

function Get-DispatchStableWorkspaceKey {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceWorkingDirectory
  )

  $normalizedSourcePath = Normalize-DispatchProjectPath -Path $SourceWorkingDirectory
  $pathLeaf = Split-Path -Leaf $SourceWorkingDirectory
  if ([string]::IsNullOrWhiteSpace($pathLeaf)) {
    $pathLeaf = "workspace"
  }

  $safeLeaf = (($pathLeaf -replace '[^A-Za-z0-9._-]', '-') -replace '-{2,}', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeLeaf)) {
    $safeLeaf = "workspace"
  }

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedSourcePath))
  } finally {
    $sha256.Dispose()
  }

  $hashText = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant().Substring(0, 12)
  return ($safeLeaf + "-" + $hashText)
}

function Get-MirrorWorkspaceDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateRoot,
    [Parameter(Mandatory = $true)]
    [string]$SourceWorkingDirectory
  )

  $workspaceKey = Get-DispatchStableWorkspaceKey -SourceWorkingDirectory $SourceWorkingDirectory
  return (Join-Path (Get-MirrorWorkspacesRoot -StateRoot $StateRoot) $workspaceKey)
}

function Resolve-MirrorSlotName {
  param(
    [string]$MirrorSlot
  )

  if ([string]::IsNullOrWhiteSpace($MirrorSlot)) {
    return $null
  }

  $trimmed = $MirrorSlot.Trim()
  if ($trimmed -match '^\d+$') {
    return ("slot-" + $trimmed)
  }

  if ($trimmed -match '^slot-\d+$') {
    return $trimmed
  }

  throw "MirrorSlot must be a number or a slot name like slot-1."
}

function Get-MirrorSlotDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$MirrorPoolRoot,
    [Parameter(Mandatory = $true)]
    [string]$MirrorSlot
  )

  $slotName = Resolve-MirrorSlotName -MirrorSlot $MirrorSlot
  return (Join-Path (Join-Path $MirrorPoolRoot "slots") $slotName)
}

function Get-MirrorSlotRepoDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$MirrorSlotDirectory
  )

  return (Join-Path $MirrorSlotDirectory "repo")
}

function Get-MirrorSlotLockPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$MirrorSlotDirectory
  )

  return (Join-Path (Join-Path $MirrorSlotDirectory ".slot") "lock.json")
}

function Test-MirrorSlotActive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$MirrorSlotDirectory
  )

  $lockPath = Get-MirrorSlotLockPath -MirrorSlotDirectory $MirrorSlotDirectory
  $lock = Read-JsonFile -Path $lockPath
  if (-not $lock) {
    return $false
  }

  if ($lock.pid) {
    $process = Get-Process -Id ([int]$lock.pid) -ErrorAction SilentlyContinue
    if (-not $process) {
      Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
      return $false
    }
  }

  return $true
}

function Acquire-MirrorSlot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateRoot,
    [Parameter(Mandatory = $true)]
    [string]$SourceWorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [int]$MirrorPoolSize = 4,
    [string]$MirrorSlot
  )

  if ($MirrorPoolSize -lt 1) {
    throw "MirrorPoolSize must be at least 1."
  }

  $sourceKey = Get-DispatchStableWorkspaceKey -SourceWorkingDirectory $SourceWorkingDirectory
  $poolRoot = Get-MirrorPoolRoot -StateRoot $StateRoot -SourceWorkingDirectory $SourceWorkingDirectory
  Ensure-Directory -Path (Join-Path $poolRoot "slots") | Out-Null

  $candidateSlots = @()
  $requestedSlot = Resolve-MirrorSlotName -MirrorSlot $MirrorSlot
  if ($requestedSlot) {
    $slotNumber = [int]($requestedSlot -replace '^slot-', '')
    if ($slotNumber -lt 1 -or $slotNumber -gt $MirrorPoolSize) {
      throw ("MirrorSlot '{0}' is outside MirrorPoolSize {1}." -f $requestedSlot, $MirrorPoolSize)
    }
    $candidateSlots = @($requestedSlot)
  } else {
    for ($i = 1; $i -le $MirrorPoolSize; $i++) {
      $candidateSlots += ("slot-" + $i)
    }
  }

  foreach ($slotName in $candidateSlots) {
    $slotDirectory = Get-MirrorSlotDirectory -MirrorPoolRoot $poolRoot -MirrorSlot $slotName

    Ensure-Directory -Path (Join-Path $slotDirectory ".slot") | Out-Null
    $lockPath = Get-MirrorSlotLockPath -MirrorSlotDirectory $slotDirectory

    # Use exclusive file I/O to atomically check-and-acquire, preventing
    # two concurrent dispatches from claiming the same slot.
    try {
      $lockStream = [System.IO.FileStream]::new(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
      )
    } catch [System.IO.IOException] {
      # Another process holds the exclusive lock on this slot — skip it.
      continue
    }

    try {
      # Read existing lock content (if any) while holding exclusive access.
      $lockContent = $null
      if ($lockStream.Length -gt 0) {
        $reader = New-Object System.IO.StreamReader($lockStream)
        $raw = $reader.ReadToEnd()
        $reader.Dispose()
        if ($raw) {
          try { $lockContent = $raw | ConvertFrom-Json } catch { $lockContent = $null }
        }
      }

      # Check if slot is actively held by a live process.
      if ($lockContent) {
        if ([string]$lockContent.runId -and [string]$lockContent.runId -ne $RunId) {
          if (-not $lockContent.pid) {
            # No PID recorded yet (runner hasn't started), treat as active.
            continue
          }
          $existingProcess = Get-Process -Id ([int]$lockContent.pid) -ErrorAction SilentlyContinue
          if ($existingProcess) {
            continue
          }
          # Stale lock from dead process — safe to reclaim.
        }
      }

      # Slot is available. Write our lock while still holding exclusive access.
      $lockStream.SetLength(0)
      $lockValue = [ordered]@{
        runId = $RunId
        pid = $null
        startedAt = Get-DispatchTimestamp
      }
      $bytes = [System.Text.Encoding]::UTF8.GetBytes(($lockValue | ConvertTo-Json -Depth 12))
      $lockStream.Write($bytes, 0, $bytes.Length)
      $lockStream.Flush()
    } finally {
      $lockStream.Dispose()
    }

    return [ordered]@{
      sourceKey = $sourceKey
      mirrorPoolRoot = $poolRoot
      mirrorSlot = $slotName
      mirrorSlotDirectory = $slotDirectory
      repoDirectory = (Get-MirrorSlotRepoDirectory -MirrorSlotDirectory $slotDirectory)
      lockPath = $lockPath
    }
  }

  if ($requestedSlot) {
    throw ("Mirror slot '{0}' is already active for source '{1}'." -f $requestedSlot, $SourceWorkingDirectory)
  }

  throw ("Mirror pool is full for source '{0}'. Active slots reached MirrorPoolSize={1}. Stop a run or increase -MirrorPoolSize." -f $SourceWorkingDirectory, $MirrorPoolSize)
}

function Release-MirrorSlot {
  param(
    $Metadata,
    [string]$MirrorSlotDirectory,
    [string]$RunId,
    [switch]$RemoveMirrorSlot
  )

  if ($Metadata) {
    if (-not $MirrorSlotDirectory -and ($Metadata.PSObject.Properties.Name -contains "mirrorSlotDirectory")) {
      $MirrorSlotDirectory = [string]$Metadata.mirrorSlotDirectory
    }
    if (-not $RunId -and ($Metadata.PSObject.Properties.Name -contains "runId")) {
      $RunId = [string]$Metadata.runId
    }
  }

  if (-not $MirrorSlotDirectory) {
    return
  }

  $lockPath = Get-MirrorSlotLockPath -MirrorSlotDirectory $MirrorSlotDirectory
  $lock = Read-JsonFile -Path $lockPath
  if ($lock -and $RunId -and ([string]$lock.runId -ne $RunId)) {
    return
  }

  if (Test-Path -LiteralPath $lockPath) {
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }

  if ($RemoveMirrorSlot -and (Test-Path -LiteralPath $MirrorSlotDirectory)) {
    Remove-Item -LiteralPath $MirrorSlotDirectory -Recurse -Force
  }
}

function Get-DispatchControlDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory
  )

  return (Join-Path $WorkspaceDirectory ".claude-dispatch")
}

function Get-DispatchWorkspaceControlPaths {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory
  )

  $controlDirectory = Get-DispatchControlDirectory -WorkspaceDirectory $WorkspaceDirectory
  return [ordered]@{
    controlDirectory = $controlDirectory
    taskPath = (Join-Path $controlDirectory "TASK.md")
    statusPath = (Join-Path $controlDirectory "status.json")
    finalReportPath = (Join-Path $controlDirectory "final-report.md")
  }
}

function Get-BatchRunsRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BatchRoot
  )

  return (Join-Path $BatchRoot "runs")
}

function Get-BatchRunDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BatchRoot,
    [Parameter(Mandatory = $true)]
    [string]$RunId
  )

  return (Join-Path (Get-BatchRunsRoot -BatchRoot $BatchRoot) $RunId)
}

function Get-BatchRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateRoot,
    [string]$BatchId
  )

  if (-not $BatchId) {
    return $null
  }

  return (Join-Path (Join-Path $StateRoot "batches") $BatchId)
}

function New-DispatchRunId {
  return ("{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([guid]::NewGuid().ToString("N").Substring(0, 8)))
}

function Get-DispatchGitBranchName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RunId
  )

  return ("claude-dispatch/{0}" -f $RunId)
}

function Normalize-PathsArray {
  param(
    [AllowNull()]
    [string[]]$Paths
  )

  if (-not $Paths) {
    return @()
  }

  $result = @()
  foreach ($path in $Paths) {
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }

    $result += $path.Trim()
  }

  return $result
}

function Normalize-DispatchProjectPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return (($Path -replace "\\", "/").TrimEnd("/"))
}

function Test-DispatchFileHasContent {
  param(
    [string]$Path
  )

  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
    return $false
  }

  $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
  return (-not [string]::IsNullOrWhiteSpace($content))
}

function Get-UniquePathsArray {
  param(
    [AllowNull()]
    [object[]]$Values
  )

  $seen = @{}
  $result = @()

  foreach ($value in @($Values)) {
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
      continue
    }

    $key = [string]$value
    if (-not $seen.ContainsKey($key)) {
      $seen[$key] = $true
      $result += $key
    }
  }

  return $result
}

function Initialize-DispatchBatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateRoot,
    [Parameter(Mandatory = $true)]
    [string]$BatchId,
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [string]$RunLabel,
    [string[]]$OwnedPaths,
    [string[]]$DependencyRunIds,
    [string]$BatchGoal,
    [Parameter(Mandatory = $true)]
    [string]$StatusPath
  )

  $batchRoot = Get-BatchRoot -StateRoot $StateRoot -BatchId $BatchId
  Ensure-Directory -Path $batchRoot | Out-Null
  Ensure-Directory -Path (Get-BatchRunsRoot -BatchRoot $batchRoot) | Out-Null
  Ensure-Directory -Path (Join-Path $batchRoot "handoffs") | Out-Null
  Ensure-Directory -Path (Get-BatchRunDirectory -BatchRoot $batchRoot -RunId $RunId) | Out-Null
  Ensure-Directory -Path (Join-Path (Join-Path $batchRoot "handoffs") $RunId) | Out-Null

  $batchPath = Join-Path $batchRoot "batch.json"
  $batch = Read-JsonFile -Path $batchPath
  if (-not $batch) {
    $batch = [ordered]@{
      schemaVersion = "claude-dispatch-batch/v0.2"
      batchId = $BatchId
      goal = $BatchGoal
      createdAt = Get-DispatchTimestamp
      updatedAt = Get-DispatchTimestamp
      ownedPaths = @()
      dependencyGraph = @()
      runs = @()
    }
  } elseif ($BatchGoal) {
    $batch.goal = $BatchGoal
  }

  $runEntry = [ordered]@{
    runId = $RunId
    runLabel = $RunLabel
    dependsOnRunIds = @((Normalize-PathsArray -Paths $DependencyRunIds))
    ownedPaths = (Normalize-PathsArray -Paths $OwnedPaths)
    statusPath = $StatusPath
    updatedAt = Get-DispatchTimestamp
  }

  $updatedRuns = @()
  $found = $false
  foreach ($existing in @($batch.runs)) {
    if ($existing.runId -eq $RunId) {
      $updatedRuns += $runEntry
      $found = $true
    } else {
      $updatedRuns += $existing
    }
  }

  if (-not $found) {
    $updatedRuns += $runEntry
  }

  $batch.runs = $updatedRuns
  $batch.ownedPaths = Get-UniquePathsArray -Values (@($updatedRuns | ForEach-Object { @($_.ownedPaths) }))

  $dependencyGraph = @()
  foreach ($entry in @($updatedRuns)) {
    $dependencyGraph += [ordered]@{
      runId = $entry.runId
      dependsOnRunIds = @($entry.dependsOnRunIds)
    }
  }

  $batch.dependencyGraph = $dependencyGraph
  $batch.updatedAt = Get-DispatchTimestamp
  Write-JsonFile -Path $batchPath -Value $batch
  return $batchRoot
}

function New-DispatchStatus {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [string]$RunLabel,
    [string]$BatchId,
    [string[]]$OwnedPaths,
    [string[]]$DependencyRunIds
  )

  return [ordered]@{
    schemaVersion = "claude-dispatch-status/v0.3"
    runId = $RunId
    runLabel = $RunLabel
    batchId = $BatchId
    phase = "starting"
    summary = "Queued for Claude Code execution."
    lastCompletedStep = $null
    nextStep = "Read prompt, inspect context, and begin work."
    blockedOn = @()
    progress = 0
    heartbeatAt = Get-DispatchTimestamp
    validation = [ordered]@{ attempted = $false; commands = @(); result = $null }
    finalReportWritten = $false
    ownedPaths = (Normalize-PathsArray -Paths $OwnedPaths)
    dependencyRunIds = @((Normalize-PathsArray -Paths $DependencyRunIds))
    updatedAt = Get-DispatchTimestamp
  }
}

function Update-DispatchStatusFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StatusPath,
    [Parameter(Mandatory = $true)]
    [string]$Phase,
    [string]$Summary,
    [string]$LastCompletedStep,
    [string]$NextStep,
    [AllowNull()]
    [string[]]$BlockedOn,
    [Nullable[int]]$Progress
  )

  $status = Read-JsonFile -Path $StatusPath
  if (-not $status) {
    throw "Status file not found: $StatusPath"
  }

  $status.phase = $Phase
  if ($PSBoundParameters.ContainsKey("Summary")) {
    $status.summary = $Summary
  }
  if ($PSBoundParameters.ContainsKey("LastCompletedStep")) {
    $status.lastCompletedStep = $LastCompletedStep
  }
  if ($PSBoundParameters.ContainsKey("NextStep")) {
    $status.nextStep = $NextStep
  }
  if ($PSBoundParameters.ContainsKey("BlockedOn")) {
    $status.blockedOn = @($BlockedOn)
  }
  if ($PSBoundParameters.ContainsKey("Progress")) {
    $status.progress = $Progress
  }

  $status.updatedAt = Get-DispatchTimestamp
  $status.heartbeatAt = Get-DispatchTimestamp
  Write-JsonFile -Path $StatusPath -Value $status

  $statusDirectory = Split-Path -Parent $StatusPath
  $runDirectory = if ($statusDirectory) { Split-Path -Parent $statusDirectory } else { $null }
  $runsDirectory = if ($runDirectory) { Split-Path -Parent $runDirectory } else { $null }
  $batchDirectory = if ($runsDirectory) { Split-Path -Parent $runsDirectory } else { $null }

  if ($runsDirectory -and $batchDirectory -and ((Split-Path -Leaf $runsDirectory) -eq "runs") -and (Test-Path -LiteralPath $batchDirectory)) {
    $runId = Split-Path -Leaf $runDirectory
    $batchRunStatusPath = Join-Path (Get-BatchRunDirectory -BatchRoot $batchDirectory -RunId $runId) "status.json"
    Write-JsonFile -Path $batchRunStatusPath -Value $status
  }
}

function Resolve-DispatchStatusPath {
  param(
    [string]$StatusPath,
    [string]$RunId,
    [string]$StateRoot,
    [string]$StateDirectory,
    [string]$WorkspaceDirectory,
    [string]$WorkingDirectory
  )

  if ($StatusPath) {
    $resolvedStatusPath = Resolve-Path -LiteralPath $StatusPath -ErrorAction SilentlyContinue
    if ($resolvedStatusPath) {
      return $resolvedStatusPath.Path
    }

    return $StatusPath
  }

  $candidates = New-Object System.Collections.Generic.List[string]

  function Add-StatusCandidate {
    param([string]$CandidatePath)

    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
      return
    }

    if (-not $candidates.Contains($CandidatePath)) {
      $candidates.Add($CandidatePath)
    }
  }

  function Add-CandidatesFromDirectory {
    param([string]$DirectoryPath)

    if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
      return
    }

    Add-StatusCandidate -CandidatePath (Join-Path $DirectoryPath ".claude-dispatch\status.json")
    if ((Split-Path -Leaf $DirectoryPath) -eq ".claude-dispatch") {
      Add-StatusCandidate -CandidatePath (Join-Path $DirectoryPath "status.json")
    }
  }

  function Add-CandidatesFromStateDirectory {
    param([string]$DirectoryPath)

    if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
      return
    }

    $runMetaPath = Join-Path $DirectoryPath "run.json"
    $runMeta = Read-JsonFile -Path $runMetaPath
    if ($runMeta) {
      Add-StatusCandidate -CandidatePath ([string]$runMeta.statusPath)
      Add-CandidatesFromDirectory -DirectoryPath ([string]$runMeta.workspaceDirectory)
    }

    Add-StatusCandidate -CandidatePath (Join-Path $DirectoryPath "status.json")
  }

  Add-CandidatesFromDirectory -DirectoryPath $WorkspaceDirectory
  Add-CandidatesFromDirectory -DirectoryPath $WorkingDirectory
  Add-CandidatesFromStateDirectory -DirectoryPath $StateDirectory

  if ($StateRoot -and $RunId) {
    $resolvedStateRoot = Get-StateRoot -StateRoot $StateRoot
    Add-CandidatesFromStateDirectory -DirectoryPath (Get-RunStateDirectory -StateRoot $resolvedStateRoot -RunId $RunId)
    Add-CandidatesFromDirectory -DirectoryPath (Get-WorkspaceDirectory -StateRoot $resolvedStateRoot -RunId $RunId)
  }

  foreach ($candidate in $candidates) {
    if (-not (Test-Path -LiteralPath $candidate)) {
      continue
    }

    $candidateStatus = Read-JsonFile -Path $candidate
    if (-not $candidateStatus) {
      continue
    }

    if (-not $RunId -or ([string]$candidateStatus.runId -eq $RunId)) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  if ($RunId) {
    throw "Unable to resolve status.json for run '$RunId'. Run the helper from the dispatch workspace root or pass -StatusPath explicitly."
  }

  throw "Unable to resolve status.json. Pass -StatusPath explicitly."
}

function Get-DispatchClaudeConfigPath {
  param(
    [string]$ClaudeConfigPath
  )

  if ($ClaudeConfigPath) {
    return $ClaudeConfigPath
  }

  $userProfile = $env:USERPROFILE
  if (-not $userProfile) {
    throw "USERPROFILE is required to locate Claude project state."
  }

  return (Join-Path $userProfile ".claude.json")
}

function Ensure-DispatchWorkspaceTrust {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory,
    [string]$ClaudeConfigPath
  )

  $resolvedConfigPath = Get-DispatchClaudeConfigPath -ClaudeConfigPath $ClaudeConfigPath
  $projectKey = Normalize-DispatchProjectPath -Path $WorkspaceDirectory
  $configDirectory = Split-Path -Parent $resolvedConfigPath
  if ($configDirectory) {
    Ensure-Directory -Path $configDirectory | Out-Null
  }

  if (Test-Path -LiteralPath $resolvedConfigPath) {
    $config = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
  } else {
    $config = [pscustomobject]@{}
  }

  if (-not ($config.PSObject.Properties.Name -contains "projects")) {
    Add-Member -InputObject $config -NotePropertyName "projects" -NotePropertyValue ([pscustomobject]@{})
  }

  $projectEntry = @($config.projects.PSObject.Properties | Where-Object { $_.Name -eq $projectKey } | Select-Object -First 1)
  if (-not $projectEntry) {
    Add-Member -InputObject $config.projects -NotePropertyName $projectKey -NotePropertyValue ([pscustomobject]@{})
    $projectEntry = @($config.projects.PSObject.Properties | Where-Object { $_.Name -eq $projectKey } | Select-Object -First 1)
  }

  $projectValue = $projectEntry.Value
  $changed = $false
  $propertyNames = @($projectValue.PSObject.Properties | ForEach-Object { $_.Name })
  if (-not ($propertyNames -contains "hasTrustDialogAccepted") -or -not $projectValue.hasTrustDialogAccepted) {
    $projectValue | Add-Member -NotePropertyName "hasTrustDialogAccepted" -NotePropertyValue $true -Force
    $changed = $true
  }

  if ($changed) {
    $tmpPath = "{0}.tmp-{1}" -f $resolvedConfigPath, ([guid]::NewGuid().ToString("N"))
    $config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmpPath -Encoding utf8
    Move-Item -LiteralPath $tmpPath -Destination $resolvedConfigPath -Force
  }

  return [ordered]@{
    projectKey = $projectKey
    configPath = $resolvedConfigPath
    changed = $changed
  }
}

function New-DispatchMetadata {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [Parameter(Mandatory = $true)]
    [string]$StateRoot,
    [Parameter(Mandatory = $true)]
    [string]$SourceWorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory,
    [Parameter(Mandatory = $true)]
    [string]$PromptPath,
    [Parameter(Mandatory = $true)]
    [string]$TaskPath,
    [Parameter(Mandatory = $true)]
    [string]$LogPath,
    [Parameter(Mandatory = $true)]
    [string]$EventsPath,
    [Parameter(Mandatory = $true)]
    [string]$FinalReportPath,
    [Parameter(Mandatory = $true)]
    [string]$SettingsPath,
    [Parameter(Mandatory = $true)]
    [string]$SystemPromptPath,
    [Parameter(Mandatory = $true)]
    [string]$StatusPath,
    [Parameter(Mandatory = $true)]
    [string]$RunnerPath,
    [string]$RunLabel,
    [string]$BatchId,
    [string[]]$OwnedPaths,
    [string[]]$DependencyRunIds,
    [string]$PermissionMode,
    [string]$ClaudeRunMode,
    [string]$DisplayMode,
    [string]$TerminalApp,
    [string]$HoldOnExit,
    [string]$WindowTitle,
    [string]$WindowName,
    [string]$BatchRoot,
    [string]$HandoffDirectory,
    [string]$WorkspaceMode,
    [string]$WorkspaceKey,
    [string]$MirrorPoolRoot,
    [string]$MirrorSlot,
    [string]$MirrorSlotDirectory,
    [string]$MirrorRefresh,
    [string]$MergeMode,
    [string]$WorktreeBranch,
    [string]$StatusHelperPath,
    [string]$HandoffHelperPath
  )

  $stateDirectory = Get-RunStateDirectory -StateRoot $StateRoot -RunId $RunId

  return [ordered]@{
    schemaVersion = "claude-dispatch-run/v0.4"
    runId = $RunId
    runLabel = $RunLabel
    batchId = $BatchId
    status = "starting"
    sourceWorkingDirectory = $SourceWorkingDirectory
    workspaceDirectory = $WorkspaceDirectory
    workspaceMode = $WorkspaceMode
    workspaceKey = $WorkspaceKey
    mirrorPoolRoot = $MirrorPoolRoot
    mirrorSlot = $MirrorSlot
    mirrorSlotDirectory = $MirrorSlotDirectory
    mirrorRefresh = $MirrorRefresh
    mergeMode = $MergeMode
    permissionMode = $PermissionMode
    claudeRunMode = $ClaudeRunMode
    displayMode = $DisplayMode
    terminalApp = $TerminalApp
    holdOnExit = $HoldOnExit
    windowTitle = $WindowTitle
    windowName = $WindowName
    startedAt = Get-DispatchTimestamp
    lastActivityAt = Get-DispatchTimestamp
    finishedAt = $null
    ownedPaths = (Normalize-PathsArray -Paths $OwnedPaths)
    dependencyRunIds = @((Normalize-PathsArray -Paths $DependencyRunIds))
    promptPath = $PromptPath
    taskPath = $TaskPath
    logPath = $LogPath
    eventsPath = $EventsPath
    finalReportPath = $FinalReportPath
    settingsPath = $SettingsPath
    systemPromptPath = $SystemPromptPath
    statusPath = $StatusPath
    stateDirectory = $stateDirectory
    batchRoot = $BatchRoot
    handoffDirectory = $HandoffDirectory
    statusHelperPath = $StatusHelperPath
    handoffHelperPath = $HandoffHelperPath
    runnerPath = $RunnerPath
    runnerPid = $null
    claudePid = $null
    launcherPid = $null
    exitCode = $null
    error = $null
    worktreeBranch = $WorktreeBranch
  }
}

function Get-DispatchTerminalApp {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Platform,
    [Parameter(Mandatory = $true)]
    [string]$DisplayMode,
    [string]$WindowsTerminalPath
  )

  if ($DisplayMode -eq "hidden") {
    return "hidden"
  }

  if ($Platform -eq "MacOS") {
    return "Terminal.app"
  }

  if ($Platform -eq "Windows" -and $WindowsTerminalPath) {
    return "wt"
  }

  if ($Platform -eq "Windows") {
    return "powershell.exe"
  }

  return "pwsh"
}

function Get-DispatchPowerShellPath {
  param(
    [string]$Platform
  )

  if (-not $Platform) {
    $Platform = Get-DispatchPlatform
  }

  if ($Platform -eq "Windows") {
    $windowsDirectory = $env:WINDIR
    if ($windowsDirectory) {
      $windowsPowerShellPath = Join-Path $windowsDirectory "System32\WindowsPowerShell\v1.0\powershell.exe"
      if (Test-Path -LiteralPath $windowsPowerShellPath) {
        return $windowsPowerShellPath
      }
    }

    $windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($windowsPowerShell) {
      return $windowsPowerShell.Source
    }
  }

  $currentProcess = Get-Process -Id $PID -ErrorAction SilentlyContinue
  if ($currentProcess -and $currentProcess.Path) {
    return $currentProcess.Path
  }

  foreach ($candidate in @("powershell.exe", "pwsh", "powershell")) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($command) {
      return $command.Source
    }
  }

  throw "Unable to locate a PowerShell host for Claude dispatch."
}

function Resolve-DispatchClaudePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ClaudePath,
    [string]$Platform
  )

  if (-not $Platform) {
    $Platform = Get-DispatchPlatform
  }

  $resolvedPath = Resolve-Path -LiteralPath $ClaudePath -ErrorAction SilentlyContinue
  if ($resolvedPath) {
    $ClaudePath = $resolvedPath.Path
  }

  if ($Platform -ne "Windows") {
    return $ClaudePath
  }

  if ([System.IO.Path]::GetExtension($ClaudePath).ToLowerInvariant() -ne ".ps1") {
    return $ClaudePath
  }

  $directory = Split-Path -Parent $ClaudePath
  $commandName = [System.IO.Path]::GetFileNameWithoutExtension($ClaudePath)
  if (-not $directory -or -not $commandName) {
    return $ClaudePath
  }

  # Prefer a native or batch launcher on Windows so a wrapper script that ends
  # with `exit` cannot terminate the foreground runner's PowerShell session.
  $candidatePaths = @(
    (Join-Path $directory "node_modules\@anthropic-ai\claude-code\bin\claude.exe"),
    (Join-Path $directory ($commandName + ".cmd")),
    (Join-Path $directory $commandName)
  )

  foreach ($candidatePath in $candidatePaths) {
    $candidateResolvedPath = Resolve-Path -LiteralPath $candidatePath -ErrorAction SilentlyContinue
    if ($candidateResolvedPath) {
      return $candidateResolvedPath.Path
    }
  }

  return $ClaudePath
}

function Get-DispatchPowerShellArguments {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Windows", "MacOS", "Linux")]
    [string]$Platform,
    [Parameter(Mandatory = $true)]
    [string[]]$RunnerArguments
  )

  $arguments = @("-NoLogo", "-NoProfile")
  if ($Platform -eq "Windows") {
    $arguments += @("-ExecutionPolicy", "Bypass")
  }

  return $arguments + $RunnerArguments
}

function Get-DispatchClaudeArguments {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PermissionMode,
    [Parameter(Mandatory = $true)]
    [string]$SettingsPath,
    [Parameter(Mandatory = $true)]
    [string]$SystemPromptPath,
    [Parameter(Mandatory = $true)]
    [ValidateSet("interactive", "print")]
    [string]$ClaudeRunMode,
    [Parameter(Mandatory = $true)]
    [string]$InitialPrompt
  )

  $commonArguments = @(
    "--permission-mode", $PermissionMode,
    "--settings", $SettingsPath,
    "--append-system-prompt-file", $SystemPromptPath
  )

  if ($ClaudeRunMode -eq "print") {
    return $commonArguments + @("-p", $InitialPrompt)
  }

  # Claude Code interactive mode is sensitive to prompt placement for some
  # flag combinations, so keep the initial prompt first.
  return @($InitialPrompt) + $commonArguments
}

function ConvertTo-PosixShellArgument {
  param(
    [AllowNull()]
    [string]$Value
  )

  if ($null -eq $Value) {
    return "''"
  }

  return "'" + $Value.Replace("'", "'""'""'") + "'"
}

function New-DispatchLauncherSpec {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Windows", "MacOS", "Linux")]
    [string]$Platform,
    [Parameter(Mandatory = $true)]
    [ValidateSet("visible", "hidden")]
    [string]$DisplayMode,
    [Parameter(Mandatory = $true)]
    [string]$PowerShellPath,
    [Parameter(Mandatory = $true)]
    [string[]]$RunnerArguments,
    [Parameter(Mandatory = $true)]
    [string]$WindowTitle,
    [string]$WindowName,
    [string]$StartingDirectory,
    [ValidateSet("onFailure", "always", "never")]
    [string]$HoldOnExit = "onFailure",
    [string]$WindowsTerminalPath,
    [string]$LauncherScriptPath
  )

  $powerShellArguments = Get-DispatchPowerShellArguments -Platform $Platform -RunnerArguments $RunnerArguments
  $powerShellExecutableName = [System.IO.Path]::GetFileName($PowerShellPath)
  if (-not $WindowName) {
    $WindowName = $WindowTitle
  }

  if ($Platform -eq "Windows") {
    if ($DisplayMode -eq "visible" -and $WindowsTerminalPath) {
      $windowsTerminalArguments = @(
        "-w",
        $WindowName,
        "nt",
        "--title",
        $WindowTitle
      )

      if ($StartingDirectory) {
        $windowsTerminalArguments += @("--startingDirectory", $StartingDirectory)
      }

      $windowsTerminalArguments += "--suppressApplicationTitle"
      $windowsTerminalArguments += $powerShellExecutableName
      $windowsTerminalArguments += $powerShellArguments

      return [ordered]@{
        Platform = $Platform
        DisplayMode = $DisplayMode
        FilePath = $WindowsTerminalPath
        ArgumentList = $windowsTerminalArguments
        WindowStyle = $null
      }
    }

    return [ordered]@{
      Platform = $Platform
      DisplayMode = $DisplayMode
      FilePath = $PowerShellPath
      ArgumentList = $powerShellArguments
      WindowStyle = if ($DisplayMode -eq "hidden") { "Hidden" } else { "Normal" }
    }
  }

  if ($Platform -eq "MacOS") {
    if ($DisplayMode -eq "visible") {
      if (-not $LauncherScriptPath) {
        $LauncherScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-dispatch-launch-" + [guid]::NewGuid().ToString("N") + ".sh")
      }

      $shellParts = @()
      if ($StartingDirectory) {
        $shellParts += "cd " + (ConvertTo-PosixShellArgument -Value $StartingDirectory)
      }
      $runnerParts = @()
      foreach ($part in (@($PowerShellPath) + $powerShellArguments)) {
        $runnerParts += (ConvertTo-PosixShellArgument -Value $part)
      }
      $shellParts += "exec " + ([string]::Join(" ", $runnerParts))
      $launchScript = "#!/bin/sh" + [Environment]::NewLine + ([string]::Join([Environment]::NewLine, $shellParts)) + [Environment]::NewLine
      Set-Content -LiteralPath $LauncherScriptPath -Value $launchScript -Encoding utf8

      $terminalCommand = "exec /bin/sh " + (ConvertTo-PosixShellArgument -Value $LauncherScriptPath)
      $escapedCommand = $terminalCommand.Replace("\\", "\\\\").Replace('"', '\\"')
      $appleScript = @"
tell application "Terminal"
  activate
  do script "$escapedCommand"
end tell
"@
      return [ordered]@{
        Platform = $Platform
        DisplayMode = $DisplayMode
        FilePath = "osascript"
        ArgumentList = @("-e", $appleScript)
        WindowStyle = $null
      }
    }

    return [ordered]@{
      Platform = $Platform
      DisplayMode = $DisplayMode
      FilePath = $PowerShellPath
      ArgumentList = $powerShellArguments
      WindowStyle = $null
    }
  }

  return [ordered]@{
    Platform = $Platform
    DisplayMode = $DisplayMode
    FilePath = $PowerShellPath
    ArgumentList = $powerShellArguments
    WindowStyle = $null
  }
}

function Save-DispatchMetadata {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    $Metadata
  )

  Write-JsonFile -Path $Path -Value $Metadata
}

function Load-DispatchMetadata {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StateDirectory
  )

  $metaPath = Join-Path $StateDirectory "run.json"
  $meta = Read-JsonFile -Path $metaPath
  if (-not $meta) {
    throw "Run metadata not found: $metaPath"
  }

  return $meta
}

function Update-DispatchMetadata {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [scriptblock]$Mutator
  )

  $metadata = Read-JsonFile -Path $Path
  if (-not $metadata) {
    throw "Run metadata not found: $Path"
  }

  & $Mutator $metadata
  $metadata.lastActivityAt = Get-DispatchTimestamp
  Write-JsonFile -Path $Path -Value $metadata
  return $metadata
}

function Get-DispatchProcessAlive {
  param(
    $Metadata,
    [string]$PropertyName = "runnerPid"
  )

  if (-not $Metadata -or -not ($Metadata.PSObject.Properties.Name -contains $PropertyName)) {
    return $false
  }

  $processId = $Metadata.$PropertyName
  if (-not $processId) {
    return $false
  }

  return ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue))
}

function Get-DispatchGitStatus {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory
  )

  $changedFiles = @()
  $diffStat = @()

  if (-not (Test-Path -LiteralPath $WorkspaceDirectory)) {
    return [ordered]@{
      changedFiles = @()
      diffStat = @()
    }
  }

  $insideWorkTree = Invoke-NativeProcess -FilePath "git" -ArgumentList @("-C", $WorkspaceDirectory, "rev-parse", "--is-inside-work-tree") -WorkingDirectory $WorkspaceDirectory
  if ($insideWorkTree.ExitCode -ne 0 -or ([string]$insideWorkTree.StandardOutput).Trim() -ne "true") {
    return [ordered]@{
      changedFiles = @()
      diffStat = @()
    }
  }

  $gitStatus = Invoke-NativeProcess -FilePath "git" -ArgumentList @("-C", $WorkspaceDirectory, "status", "--short") -WorkingDirectory $WorkspaceDirectory
  if ($gitStatus.ExitCode -eq 0) {
    foreach ($line in @($gitStatus.StandardOutput -split "\r?\n")) {
      if (-not $line) {
        continue
      }

      $status = $line.Substring(0, [Math]::Min(2, $line.Length)).Trim()
      $path = if ($line.Length -gt 3) { $line.Substring(3).Trim() } else { "" }
      $changedFiles += [ordered]@{
        status = $status
        path = $path
      }
    }

    $diffStatResult = Invoke-NativeProcess -FilePath "git" -ArgumentList @("-C", $WorkspaceDirectory, "diff", "--stat") -WorkingDirectory $WorkspaceDirectory
    if ($diffStatResult.ExitCode -eq 0) {
      $diffStat = @($diffStatResult.StandardOutput -split "\r?\n" | Where-Object { $_ })
    }
  }

  return [ordered]@{
    changedFiles = $changedFiles
    diffStat = $diffStat
  }
}

function Clear-DispatchWorkspaceDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory
  )

  if (-not (Test-Path -LiteralPath $WorkspaceDirectory)) {
    return
  }

  foreach ($item in @(Get-ChildItem -LiteralPath $WorkspaceDirectory -Force)) {
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
  }
}

function Copy-DispatchDirectoryContents {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDirectory,
    [Parameter(Mandatory = $true)]
    [string]$DestinationDirectory
  )

  Ensure-Directory -Path $DestinationDirectory | Out-Null

  foreach ($item in @(Get-ChildItem -LiteralPath $SourceDirectory -Force)) {
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $DestinationDirectory $item.Name) -Recurse -Force
  }
}

function Ensure-DispatchMirrorWorkspace {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceWorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory
  )

  Ensure-Directory -Path (Split-Path -Parent $WorkspaceDirectory) | Out-Null
  Ensure-Directory -Path $WorkspaceDirectory | Out-Null
  Clear-DispatchWorkspaceDirectory -WorkspaceDirectory $WorkspaceDirectory
  Copy-DispatchDirectoryContents -SourceDirectory $SourceWorkingDirectory -DestinationDirectory $WorkspaceDirectory
}

function Sync-MirrorSlotFromSource {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceWorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$MirrorSlotDirectory,
    [ValidateSet("clean", "incremental")]
    [string]$MirrorRefresh = "clean"
  )

  $repoDirectory = Get-MirrorSlotRepoDirectory -MirrorSlotDirectory $MirrorSlotDirectory
  Ensure-Directory -Path $MirrorSlotDirectory | Out-Null
  Ensure-Directory -Path (Join-Path $MirrorSlotDirectory ".slot") | Out-Null
  Ensure-Directory -Path $repoDirectory | Out-Null

  if ($MirrorRefresh -eq "clean") {
    Clear-DispatchWorkspaceDirectory -WorkspaceDirectory $repoDirectory
  }

  Copy-DispatchDirectoryContents -SourceDirectory $SourceWorkingDirectory -DestinationDirectory $repoDirectory

  $sourcePath = Join-Path (Join-Path $MirrorSlotDirectory ".slot") "source.json"
  Write-JsonFile -Path $sourcePath -Value ([ordered]@{
    sourceWorkingDirectory = $SourceWorkingDirectory
    sourceKey = (Get-DispatchStableWorkspaceKey -SourceWorkingDirectory $SourceWorkingDirectory)
    lastSyncedAt = Get-DispatchTimestamp
    mirrorRefresh = $MirrorRefresh
  })

  return $repoDirectory
}

function Ensure-DispatchWorktree {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceWorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory,
    [Parameter(Mandatory = $true)]
    [string]$BranchName
  )

  Ensure-Directory -Path (Split-Path -Parent $WorkspaceDirectory) | Out-Null

  if (Test-Path -LiteralPath $WorkspaceDirectory) {
    Remove-Item -LiteralPath $WorkspaceDirectory -Recurse -Force
  }

  $result = Invoke-NativeProcess -FilePath "git" -ArgumentList @("-C", $SourceWorkingDirectory, "worktree", "add", $WorkspaceDirectory, "-b", $BranchName, "HEAD") -WorkingDirectory $SourceWorkingDirectory
  if ($result.ExitCode -ne 0) {
    $details = @()
    if ($result.StandardOutput) {
      $details += $result.StandardOutput.Trim()
    }
    if ($result.StandardError) {
      $details += $result.StandardError.Trim()
    }

    throw ("git worktree add failed for {0}: {1}" -f $WorkspaceDirectory, ([string]::Join([Environment]::NewLine, $details)))
  }
}

function Add-DispatchWorktreeIgnorePattern {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory,
    [Parameter(Mandatory = $true)]
    [string[]]$Patterns
  )

  $gitPathResult = Invoke-NativeProcess -FilePath "git" -ArgumentList @("-C", $WorkspaceDirectory, "rev-parse", "--git-path", "info/exclude") -WorkingDirectory $WorkspaceDirectory
  if ($gitPathResult.ExitCode -ne 0) {
    return
  }

  $excludePath = ($gitPathResult.StandardOutput | Out-String).Trim()
  if (-not $excludePath) {
    return
  }

  if (-not [System.IO.Path]::IsPathRooted($excludePath)) {
    $excludePath = Join-Path $WorkspaceDirectory $excludePath
  }

  $excludeDirectory = Split-Path -Parent $excludePath
  if ($excludeDirectory) {
    Ensure-Directory -Path $excludeDirectory | Out-Null
  }

  $existingLines = @()
  if (Test-Path -LiteralPath $excludePath) {
    $existingLines = @(Get-Content -LiteralPath $excludePath)
  }

  $toAppend = @()
  foreach ($pattern in @($Patterns)) {
    if ([string]::IsNullOrWhiteSpace($pattern)) {
      continue
    }

    if (-not ($existingLines -contains $pattern) -and -not ($toAppend -contains $pattern)) {
      $toAppend += $pattern
    }
  }

  if ($toAppend.Count -gt 0) {
    Add-Content -LiteralPath $excludePath -Value $toAppend -Encoding utf8
  }
}

function New-DispatchFileMirror {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [Parameter(Mandatory = $true)]
    [string]$MirrorPath
  )

  $sourceDirectory = Split-Path -Parent $SourcePath
  if ($sourceDirectory) {
    Ensure-Directory -Path $sourceDirectory | Out-Null
  }

  if (-not (Test-Path -LiteralPath $SourcePath)) {
    Set-Content -LiteralPath $SourcePath -Value "" -Encoding utf8
  }

  $mirrorDirectory = Split-Path -Parent $MirrorPath
  if ($mirrorDirectory) {
    Ensure-Directory -Path $mirrorDirectory | Out-Null
  }

  if (Test-Path -LiteralPath $MirrorPath) {
    Remove-Item -LiteralPath $MirrorPath -Force
  }

  try {
    New-Item -ItemType HardLink -Path $MirrorPath -Target $SourcePath -ErrorAction Stop | Out-Null
  } catch {
    throw ("Failed to mirror dispatch control file '{0}' into workspace path '{1}'. {2}" -f $SourcePath, $MirrorPath, $_.Exception.Message)
  }
}

function Initialize-DispatchWorkspaceControlFiles {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDirectory,
    [Parameter(Mandatory = $true)]
    [string]$TaskPath,
    [Parameter(Mandatory = $true)]
    [string]$StatusPath,
    [Parameter(Mandatory = $true)]
    [string]$FinalReportPath
  )

  $controlPaths = Get-DispatchWorkspaceControlPaths -WorkspaceDirectory $WorkspaceDirectory
  Ensure-Directory -Path $controlPaths.controlDirectory | Out-Null
  Add-DispatchWorktreeIgnorePattern -WorkspaceDirectory $WorkspaceDirectory -Patterns @(".claude-dispatch/")

  New-DispatchFileMirror -SourcePath $TaskPath -MirrorPath $controlPaths.taskPath
  New-DispatchFileMirror -SourcePath $StatusPath -MirrorPath $controlPaths.statusPath
  New-DispatchFileMirror -SourcePath $FinalReportPath -MirrorPath $controlPaths.finalReportPath

  return $controlPaths
}

function Remove-DispatchWorkspaceDirectory {
  param(
    [string]$WorkspaceDirectory
  )

  if ($WorkspaceDirectory -and (Test-Path -LiteralPath $WorkspaceDirectory)) {
    Remove-Item -LiteralPath $WorkspaceDirectory -Recurse -Force
  }
}

function Remove-DispatchWorktree {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceWorkingDirectory,
    [string]$WorkspaceDirectory,
    [string]$BranchName,
    [switch]$Force
  )

  if ($WorkspaceDirectory -and (Test-Path -LiteralPath $WorkspaceDirectory)) {
    $arguments = @("-C", $SourceWorkingDirectory, "worktree", "remove")
    if ($Force) {
      $arguments += "--force"
    }
    $arguments += $WorkspaceDirectory
    & git @arguments 2>$null | Out-Null
  }

  if ($BranchName) {
    & git -C $SourceWorkingDirectory branch -D $BranchName 2>$null | Out-Null
  }
}

function Remove-DispatchWorkspace {
  param(
    [Parameter(Mandatory = $true)]
    $Metadata,
    [switch]$Force
  )

  $workspaceMode = if ($Metadata.PSObject.Properties.Name -contains "workspaceMode") { [string]$Metadata.workspaceMode } else { "worktree" }

  if ($workspaceMode -eq "mirror") {
    Remove-DispatchWorkspaceDirectory -WorkspaceDirectory $Metadata.workspaceDirectory
    return
  }

  if ($workspaceMode -eq "mirrorPool") {
    Release-MirrorSlot -Metadata $Metadata -RemoveMirrorSlot:$Force
    return
  }

  Remove-DispatchWorktree -SourceWorkingDirectory $Metadata.sourceWorkingDirectory -WorkspaceDirectory $Metadata.workspaceDirectory -BranchName $Metadata.worktreeBranch -Force:$Force
}

function Remove-DispatchBatchArtifacts {
  param(
    $Metadata
  )

  if (-not $Metadata -or -not $Metadata.batchRoot) {
    return
  }

  $batchRoot = $Metadata.batchRoot
  if (-not (Test-Path -LiteralPath $batchRoot)) {
    return
  }

  $batchRunDirectory = Get-BatchRunDirectory -BatchRoot $batchRoot -RunId $Metadata.runId
  if (Test-Path -LiteralPath $batchRunDirectory) {
    Remove-Item -LiteralPath $batchRunDirectory -Recurse -Force
  }

  if ($Metadata.handoffDirectory -and (Test-Path -LiteralPath $Metadata.handoffDirectory)) {
    Remove-Item -LiteralPath $Metadata.handoffDirectory -Recurse -Force
  }

  $batchPath = Join-Path $batchRoot "batch.json"
  $batch = Read-JsonFile -Path $batchPath
  if ($batch) {
    $remainingRuns = @()
    foreach ($entry in @($batch.runs)) {
      if ($entry.runId -ne $Metadata.runId) {
        $remainingRuns += $entry
      }
    }

    $batch.runs = $remainingRuns
    $batch.ownedPaths = Get-UniquePathsArray -Values (@($remainingRuns | ForEach-Object { @($_.ownedPaths) }))

    $dependencyGraph = @()
    foreach ($entry in @($remainingRuns)) {
      $dependencyGraph += [ordered]@{
        runId = $entry.runId
        dependsOnRunIds = @($entry.dependsOnRunIds)
      }
    }

    $batch.dependencyGraph = $dependencyGraph
    $batch.updatedAt = Get-DispatchTimestamp
    Write-JsonFile -Path $batchPath -Value $batch
  }

  $runsRoot = Join-Path $batchRoot "runs"
  $handoffsRoot = Join-Path $batchRoot "handoffs"
  $remainingRunDirectories = @(if (Test-Path -LiteralPath $runsRoot) { Get-ChildItem -LiteralPath $runsRoot -Directory })
  $remainingHandoffDirectories = @(if (Test-Path -LiteralPath $handoffsRoot) { Get-ChildItem -LiteralPath $handoffsRoot -Directory })
  $remainingRunCount = if ($batch -and $batch.runs) { (@($batch.runs)).Count } else { 0 }

  if ($remainingRunCount -eq 0 -and $remainingRunDirectories.Count -eq 0 -and $remainingHandoffDirectories.Count -eq 0) {
    Remove-Item -LiteralPath $batchRoot -Recurse -Force
  }
}

function Stop-DispatchProcesses {
  param(
    $Metadata
  )

  foreach ($property in @("claudePid", "runnerPid", "launcherPid")) {
    $processId = $Metadata.$property
    if ($processId) {
      $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
      if ($process) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        try {
          [void]$process.WaitForExit(5000)
        } catch {
          Start-Sleep -Milliseconds 250
        }
      }
    }
  }
}
