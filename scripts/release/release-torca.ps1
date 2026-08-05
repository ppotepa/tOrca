[CmdletBinding()]
param(
    [ValidateSet('all', 'core', 'android', 'windows')]
    [string]$Target = 'all',
    [string]$Device = '',
    [string]$ReportPath,
    [string]$ArtifactRoot,
    [string]$MetadataDirectory,
    [switch]$BuildAndroidBundle,
    [string]$ArtifactBaseUrl,
    [string]$SigningPrivateKey,
    [string]$SigningKeyId,
    [string]$UpdatePublicKey,
    [string]$ReleaseNotesUrl,
    [switch]$MandatoryUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).Path
$release = Get-Content -LiteralPath (Join-Path $repositoryRoot 'release/version.json') -Raw |
    ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $repositoryRoot ".torca/artifacts/$($release.version)"
}
if ([string]::IsNullOrWhiteSpace($MetadataDirectory)) {
    $MetadataDirectory = Join-Path $repositoryRoot ".torca/release/$($release.version)"
}
$buildsArtifacts = $Target -ne 'core'
if ($buildsArtifacts) {
    foreach ($required in [ordered]@{
        ArtifactBaseUrl = $ArtifactBaseUrl
        SigningPrivateKey = $SigningPrivateKey
        SigningKeyId = $SigningKeyId
        UpdatePublicKey = $UpdatePublicKey
    }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($required.Value)) {
            throw "$($required.Key) is required for a Torca platform release."
        }
    }
}

& (Join-Path $repositoryRoot 'scripts/internal/check-release-policy.ps1') `
    -RepositoryRoot $repositoryRoot
if ($LASTEXITCODE -notin @(0, $null)) {
    throw "Torca release policy failed with code $LASTEXITCODE."
}

& (Join-Path $PSScriptRoot 'validate-torca-release.ps1') `
    -Target $Target `
    -Device $Device `
    -OutputPath $ReportPath `
    -RequirePlatforms `
    -BuildAndroidBundle:$BuildAndroidBundle `
    -UpdateKeyId $SigningKeyId `
    -UpdatePublicKey $UpdatePublicKey
if ($LASTEXITCODE -notin @(0, $null)) {
    throw "Torca release validation failed with code $LASTEXITCODE."
}

if ($buildsArtifacts) {
    $collectTarget = if ($Target -eq 'all') { 'all' } else { $Target }
    & (Join-Path $PSScriptRoot 'collect-release-artifacts.ps1') `
        -RepositoryRoot $repositoryRoot `
        -Target $collectTarget `
        -OutputDirectory $ArtifactRoot
    if ($LASTEXITCODE -notin @(0, $null)) {
        throw "Torca artifact collection failed with code $LASTEXITCODE."
    }
}

& (Join-Path $PSScriptRoot 'generate-release-metadata.ps1') `
    -RepositoryRoot $repositoryRoot `
    -ArtifactRoot $ArtifactRoot `
    -OutputDirectory $MetadataDirectory
if ($LASTEXITCODE -notin @(0, $null)) {
    throw "Torca release metadata generation failed with code $LASTEXITCODE."
}

if ($buildsArtifacts) {
    & (Join-Path $PSScriptRoot 'generate-update-manifest.ps1') `
        -RepositoryRoot $repositoryRoot `
        -ArtifactDirectory $ArtifactRoot `
        -ArtifactBaseUrl $ArtifactBaseUrl `
        -SigningPrivateKey $SigningPrivateKey `
        -SigningKeyId $SigningKeyId `
        -ReleaseNotesUrl $ReleaseNotesUrl `
        -Mandatory:$MandatoryUpdate
    if ($LASTEXITCODE -notin @(0, $null)) {
        throw "Torca update manifest generation failed with code $LASTEXITCODE."
    }
}

Write-Host '[torca] release policy, validation, artifacts, metadata and update manifest completed.'
