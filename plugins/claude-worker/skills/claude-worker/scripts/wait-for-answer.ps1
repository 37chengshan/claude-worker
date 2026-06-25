param(
  [Parameter(Mandatory = $true)]
  [string]$QuestionPath,
  [Parameter(Mandatory = $true)]
  [string]$AnswerPath,
  [int]$TimeoutSeconds = 300,
  [int]$PollIntervalSeconds = 2
)

$ErrorActionPreference = "Stop"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory "claude-dispatch-common.ps1")

if (-not (Test-Path -LiteralPath $QuestionPath)) {
  throw "Question file not found: $QuestionPath"
}

$question = Read-JsonFile -Path $QuestionPath
if (-not $question) {
  throw "Failed to read question file: $QuestionPath"
}

$questionId = [string]$question.questionId
if (-not $questionId) {
  throw "Question file missing questionId field."
}

Write-Host "Waiting for answer to question: $questionId"
Write-Host "Question: $([string]$question.question)"
if ($question.options) {
  Write-Host "Options: $(($question.options | ForEach-Object { [string]$_ }) -join ', ')"
}
Write-Host "Timeout: ${TimeoutSeconds}s"
Write-Host ""

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

while ((Get-Date) -lt $deadline) {
  if (Test-Path -LiteralPath $AnswerPath) {
    $answer = Read-JsonFile -Path $AnswerPath
    if ($answer) {
      $answerText = [string]$answer.answer
      if ($answerText) {
        Write-Host "Answer received for $questionId : $answerText"
        [ordered]@{
          questionId = $questionId
          answer = $answerText
          answeredAt = [string]$answer.answeredAt
          answeredBy = if ($answer.answeredBy) { [string]$answer.answeredBy } else { "unknown" }
        } | ConvertTo-Json -Depth 8
        exit 0
      }
    }
  }

  Start-Sleep -Seconds $PollIntervalSeconds
}

Write-Warning "Timed out waiting for answer to question $questionId after ${TimeoutSeconds}s."
[ordered]@{
  questionId = $questionId
  timedOut = $true
  timeoutSeconds = $TimeoutSeconds
} | ConvertTo-Json -Depth 8
exit 1
