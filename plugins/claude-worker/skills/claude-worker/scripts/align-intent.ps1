param(
  [Parameter(Mandatory = $true)]
  [string]$WorkingDirectory,
  [string]$SessionId = "",
  [string]$StateRoot = ""
)

$ErrorActionPreference = "Stop"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory "claude-dispatch-common.ps1")

$resolvedStateRoot = Get-StateRoot -StateRoot $StateRoot
$stateDir = Join-Path $resolvedStateRoot "state"
Ensure-Directory -Path $stateDir | Out-Null

$alignmentPath = Join-Path $stateDir "alignment.json"

# Load existing alignment or create new
$alignment = $null
if (Test-Path -LiteralPath $alignmentPath) {
  $alignment = Read-JsonFile -Path $alignmentPath
}

if (-not $alignment) {
  $alignment = [ordered]@{
    status = "in-progress"
    goal = ""
    successCriteria = ""
    constraints = ""
    nonGoals = ""
    confirmedAt = $null
    sessionId = if ($SessionId) { $SessionId } else { [guid]::NewGuid().ToString("N") }
    workingDirectory = $WorkingDirectory
  }
  Write-JsonFile -Path $alignmentPath -Value $alignment
}

# Structured interview questions
Write-Host ""
Write-Host "========================================="
Write-Host "  Dispatch Intent Alignment Interview"
Write-Host "========================================="
Write-Host ""
Write-Host "Current alignment status: $($alignment.status)"
Write-Host ""

$fields = @(
  @{ Key = "goal"; Prompt = "1. GOAL: What is the objective of this dispatch? (Describe the desired outcome clearly.)" },
  @{ Key = "successCriteria"; Prompt = "2. SUCCESS CRITERIA: How will you know the task is done? (Specific, measurable conditions.)" },
  @{ Key = "constraints"; Prompt = "3. CONSTRAINTS: What limitations or requirements must be respected? (File scope, tech stack, conventions.)" },
  @{ Key = "nonGoals"; Prompt = "4. NON-GOALS: What is explicitly out of scope? (Things that should NOT be changed.)" }
)

foreach ($field in $fields) {
  $currentValue = [string]$alignment.($field.Key)
  if ($currentValue) {
    Write-Host "$($field.Prompt)"
    Write-Host "  Current value: $currentValue"
    Write-Host "  Press Enter to keep, or type a new value:"
  } else {
    Write-Host $field.Prompt
    Write-Host "  (Enter your answer)"
  }
  
  $answer = Read-Host
  if ($answer -or -not $currentValue) {
    if ($answer) {
      $alignment.($field.Key) = $answer
    } elseif (-not $currentValue) {
      Write-Warning "Field '$($field.Key)' is required. Please provide a value."
      # Re-prompt once
      $answer = Read-Host "  Please enter a value for $($field.Key)"
      if ($answer) {
        $alignment.($field.Key) = $answer
      }
    }
  }
}

# Validate all fields are filled
$requiredFields = @("goal", "successCriteria", "constraints", "nonGoals")
$missingFields = @()
foreach ($f in $requiredFields) {
  if (-not [string]$alignment.$f) {
    $missingFields += $f
  }
}

if ($missingFields.Count -gt 0) {
  Write-Warning "Alignment incomplete. Missing fields: $($missingFields -join ', ')"
  $alignment.status = "in-progress"
  Write-JsonFile -Path $alignmentPath -Value $alignment
  Write-Host "Alignment saved as in-progress. Re-run to complete."
  exit 1
}

$alignment.status = "confirmed"
$alignment.confirmedAt = (Get-Date).ToString("o")
Write-JsonFile -Path $alignmentPath -Value $alignment

Write-Host ""
Write-Host "========================================="
Write-Host "  Alignment CONFIRMED"
Write-Host "========================================="
Write-Host ""
Write-Host "Goal: $($alignment.goal)"
Write-Host "Success Criteria: $($alignment.successCriteria)"
Write-Host "Constraints: $($alignment.constraints)"
Write-Host "Non-Goals: $($alignment.nonGoals)"
Write-Host ""
Write-Host "Alignment saved to: $alignmentPath"
