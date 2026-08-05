[CmdletBinding()]
param(
    [string]$WorkflowPath = (Join-Path $PSScriptRoot '..\..\.github\workflows\release-0-1-validation.yml'),
    [string]$DenyPath = (Join-Path $PSScriptRoot '..\..\deny.toml'),
    [string]$MlsFixturePath = (Join-Path $PSScriptRoot '..\..\tests\fixtures\protocol\android-peer.json')
)

$ErrorActionPreference = 'Stop'
$workflow = Get-Content -LiteralPath (Resolve-Path $WorkflowPath) -Raw
$deny = Get-Content -LiteralPath (Resolve-Path $DenyPath) -Raw
$fixture = Get-Content -LiteralPath (Resolve-Path $MlsFixturePath) -Raw

$uses = [regex]::Matches($workflow, '(?m)^\s*-?\s*uses:\s*([^\s#]+)') |
    ForEach-Object { $_.Groups[1].Value }
$unpinned = $uses | Where-Object {
    $_ -match '@(?:v\d+(?:\.\d+)*|stable|main|master|latest)$'
}
if ($unpinned) {
    throw "Release workflow contains unpinned actions: $($unpinned -join ', ')"
}

if ($uses.Count -eq 0) { throw 'Release workflow contains no actions to validate' }
if ($workflow -notmatch 'cargo deny check bans licenses sources') {
    throw 'Release workflow is missing cargo-deny policy gate'
}
if ($workflow -notmatch 'cargo audit') {
    throw 'Release workflow is missing cargo-audit policy gate'
}
if ($workflow -notmatch 'cargo-cyclonedx') {
    throw 'Release workflow is missing CycloneDX SBOM generation'
}
if ($workflow -notmatch 'attest-build-provenance') {
    throw 'Release workflow is missing provenance attestation'
}
if ($deny -notmatch 'unknown-registry\s*=\s*"deny"' -or
    $deny -notmatch 'unknown-git\s*=\s*"deny"') {
    throw 'deny.toml must reject unknown registry and git sources'
}
if ($fixture -notmatch '"android_snapshot"\s*:\s*"VENNTFMxAAE' -or
    $fixture -notmatch '"peer_snapshot"\s*:\s*"VENNTFMxAAE') {
    throw 'release fixture must contain current TCMLS1 snapshots'
}

Write-Output "Release policy passed: $($uses.Count) actions pinned; audit/deny/SBOM/provenance/current MLS fixture gates present."
