param(
  [Parameter(Mandatory = $true)]
  [string]$EventsPath,
  [int]$TimeoutSeconds = 0
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $EventsPath)) {
  throw "Events file not found: $EventsPath"
}

$directory = Split-Path -Parent $EventsPath
$fileName = Split-Path -Leaf $EventsPath

# Read existing content baseline
$lastPosition = 0
if (Test-Path -LiteralPath $EventsPath) {
  $lastPosition = (Get-Item -LiteralPath $EventsPath).Length
}

Write-Host "Subscribing to dispatch events: $EventsPath"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $directory
$watcher.Filter = $fileName
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size
$watcher.EnableRaisingEvents = $false

$deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { [datetime]::MaxValue }

try {
  while ((Get-Date) -lt $deadline) {
    $result = $watcher.WaitForChanged(
      [System.IO.WatcherChangeTypes]::Changed,
      1000
    )

    if (-not $result.TimedOut -and (Test-Path -LiteralPath $EventsPath)) {
      $currentLength = (Get-Item -LiteralPath $EventsPath).Length
      if ($currentLength -gt $lastPosition) {
        $stream = [System.IO.FileStream]::new(
          $EventsPath,
          [System.IO.FileMode]::Open,
          [System.IO.FileAccess]::Read,
          [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
        try {
          $stream.Seek($lastPosition, [System.IO.SeekOrigin]::Begin) | Out-Null
          $reader = New-Object System.IO.StreamReader($stream)
          while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line -and -not [string]::IsNullOrWhiteSpace($line)) {
              Write-Host $line
            }
          }
          $lastPosition = $stream.Position
        } finally {
          $reader.Dispose()
          $stream.Dispose()
        }
      }
    }
  }
} finally {
  $watcher.Dispose()
}
