param(
  [string]$Prompt,
  [string]$PromptFile,
  [string]$WorkingDirectory,
  [ValidateSet("acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan")]
  [string]$PermissionMode = "acceptEdits",
  [int]$TimeoutSeconds = 7200,
  [int]$RetryCount = 1
)

$ErrorActionPreference = "Stop"

if ($WorkingDirectory) {
  Set-Location -LiteralPath $WorkingDirectory
}

if ($PromptFile) {
  $Prompt = Get-Content -LiteralPath $PromptFile -Raw
}

if (-not $Prompt) {
  throw "Provide -Prompt or -PromptFile."
}

if ($TimeoutSeconds -lt 1800) {
  throw "TimeoutSeconds must be at least 1800 seconds."
}

if ($PermissionMode -eq "bypassPermissions") {
  Write-Warning "bypassPermissions should only be used inside an isolated VM/container/sandbox. The safer default is acceptEdits."
}

$claude = Get-Command claude -ErrorAction Stop
$attemptLimit = [Math]::Max(1, $RetryCount + 1)
$lastOutput = $null

for ($attempt = 1; $attempt -le $attemptLimit; $attempt++) {
  Write-Host "[dispatch-claude] attempt $attempt/$attemptLimit, timeout=${TimeoutSeconds}s, permission=$PermissionMode"

  $job = Start-Job -ScriptBlock {
    param($ClaudePath, $Mode, $TaskPrompt, $TargetDirectory)

    if ($TargetDirectory) {
      Set-Location -LiteralPath $TargetDirectory
    }

    $TaskPrompt | & $ClaudePath --permission-mode $Mode -p
    if ($LASTEXITCODE -ne 0) {
      throw "claude exited with code $LASTEXITCODE"
    }
  } -ArgumentList $claude.Source, $PermissionMode, $Prompt, (Get-Location).Path

  $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
  if ($completed) {
    $lastOutput = Receive-Job -Job $job
    Remove-Job -Job $job
    $lastOutput
    exit 0
  }

  Stop-Job -Job $job
  $lastOutput = Receive-Job -Job $job -ErrorAction SilentlyContinue
  Remove-Job -Job $job

  if ($lastOutput) {
    $lastOutput
  }

  Write-Warning "[dispatch-claude] Claude Code timed out on attempt $attempt."
}

throw "Claude Code did not finish after $attemptLimit attempt(s)."
