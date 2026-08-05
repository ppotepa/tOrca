[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$release = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'release/version.json') -Raw |
    ConvertFrom-Json
$matrix = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/release/torca-release-matrix.json') -Raw |
    ConvertFrom-Json
$commit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
    throw 'Unable to resolve the manual-evidence commit.'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $RepositoryRoot ".torca/release/$($release.version)/manual-evidence.json"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

$tests = @(
    foreach ($test in $matrix.manual) {
        [ordered]@{
            id = $test.id
            status = 'pending'
            platforms = @($test.platforms)
            requiredRuns = if ($null -ne $test.requiredRuns) { [int]$test.requiredRuns } else { 1 }
            actualRuns = 0
            requiredHours = if ($null -ne $test.requiredHours) { [double]$test.requiredHours } else { 0 }
            actualHours = 0
            tester = ''
            startedAtUtc = $null
            completedAtUtc = $null
            evidence = @()
            notes = ''
        }
    }
)
$document = [ordered]@{
    schema = 1
    product = 'Torca'
    version = $release.version
    build = [int]$release.build
    commit = $commit
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    tests = $tests
}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($OutputPath, ($document | ConvertTo-Json -Depth 10), $utf8)
Write-Host "Torca manual evidence template: $OutputPath"
