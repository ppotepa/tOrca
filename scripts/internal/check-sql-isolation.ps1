[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
$codeRoots = @(
    (Join-Path $RepoRoot 'server\torchat-server\src'),
    (Join-Path $RepoRoot 'desktop\src'),
    (Join-Path $RepoRoot 'mobile\android\app\src\main\kotlin')
)
$pattern = '(?i)(?:"{1,3}|''{1,3})\s*(SELECT|INSERT|UPDATE|DELETE|CREATE\s+TABLE|ALTER\s+TABLE|DROP\s+TABLE|PRAGMA|CREATE\s+INDEX)\b'
$violations = @()

foreach ($root in $codeRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $violations += @(Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.Extension -in @('.rs', '.kt') } |
        Select-String -Pattern $pattern)
}

if ($violations.Count -gt 0) {
    $details = $violations | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }
    throw "SQL must live in versioned SQL files, not Rust/Kotlin source:`n$($details -join "`n")"
}

Write-Host '[torchat] SQL isolation check passed.'
