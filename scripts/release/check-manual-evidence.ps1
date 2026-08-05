[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$EvidencePath,
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$EvidencePath = (Resolve-Path -LiteralPath $EvidencePath).Path
$release = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'release/version.json') -Raw |
    ConvertFrom-Json
$matrix = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/release/torca-release-matrix.json') -Raw |
    ConvertFrom-Json
$evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
$commit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
    throw 'Unable to resolve the manual-evidence commit.'
}

if ($evidence.product -ne 'Torca' -or
    $evidence.version -ne $release.version -or
    [int]$evidence.build -ne [int]$release.build -or
    $evidence.commit -ne $commit) {
    throw 'Manual evidence does not match the current Torca version, build and commit.'
}

$failures = [System.Collections.Generic.List[string]]::new()
$indexed = @{}
foreach ($test in $evidence.tests) {
    if ($indexed.ContainsKey($test.id)) {
        $failures.Add("Duplicate manual evidence id: $($test.id)")
    } else {
        $indexed[$test.id] = $test
    }
}
foreach ($required in $matrix.manual) {
    if (-not $indexed.ContainsKey($required.id)) {
        $failures.Add("Missing manual evidence: $($required.id)")
        continue
    }
    $actual = $indexed[$required.id]
    if ($actual.status -ne 'passed') {
        $failures.Add("Manual evidence is not passed: $($required.id)")
    }
    $requiredRuns = if ($null -ne $required.requiredRuns) { [int]$required.requiredRuns } else { 1 }
    if ([int]$actual.actualRuns -lt $requiredRuns) {
        $failures.Add("Insufficient runs for $($required.id): $($actual.actualRuns)/$requiredRuns")
    }
    $requiredHours = if ($null -ne $required.requiredHours) { [double]$required.requiredHours } else { 0 }
    if ([double]$actual.actualHours -lt $requiredHours) {
        $failures.Add("Insufficient soak hours for $($required.id): $($actual.actualHours)/$requiredHours")
    }
    if ([string]::IsNullOrWhiteSpace($actual.tester)) {
        $failures.Add("Tester identity is missing for $($required.id)")
    }
    if ([string]::IsNullOrWhiteSpace($actual.completedAtUtc)) {
        $failures.Add("Completion timestamp is missing for $($required.id)")
    } else {
        try { [void][DateTimeOffset]::Parse($actual.completedAtUtc) }
        catch { $failures.Add("Completion timestamp is invalid for $($required.id)") }
    }
    if (@($actual.evidence).Count -eq 0) {
        $failures.Add("Evidence references are missing for $($required.id)")
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host "ERROR: $failure" -ForegroundColor Red
    }
    throw "Torca manual evidence failed with $($failures.Count) issue(s)."
}

if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $ReceiptPath = Join-Path (Split-Path -Parent $EvidencePath) 'manual-evidence-receipt.json'
}
$receipt = [ordered]@{
    schema = 1
    product = 'Torca'
    version = $release.version
    build = [int]$release.build
    commit = $commit
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    evidenceFile = [IO.Path]::GetFileName($EvidencePath)
    evidenceSha256 = (Get-FileHash -LiteralPath $EvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    tests = @($matrix.manual).Count
    passed = $true
}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($ReceiptPath, ($receipt | ConvertTo-Json -Depth 6), $utf8)
Write-Host "[torca] manual evidence passed: $ReceiptPath"
