[CmdletBinding()]
param(
    [ValidateSet('all', 'core', 'android', 'windows')]
    [string]$Target = 'all',
    [string]$Device = '',
    [string]$ReportPath,
    [string]$ArtifactRoot,
    [string]$MetadataDirectory,
    [switch]$BuildAndroidBundle
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$repositoryRoot = (Resolve-Path -LiteralPath $repositoryRoot).Path

& (Join-Path $PSScriptRoot 'validate-torca-release.ps1') `
    -Target $Target `
    -Device $Device `
    -OutputPath $ReportPath `
    -RequirePlatforms `
    -BuildAndroidBundle:$BuildAndroidBundle
if ($LASTEXITCODE -notin @(0, $null)) {
    throw "Torca release validation failed with code $LASTEXITCODE."
}

& (Join-Path $PSScriptRoot 'generate-release-metadata.ps1') `
    -RepositoryRoot $repositoryRoot `
    -ArtifactRoot $ArtifactRoot `
    -OutputDirectory $MetadataDirectory
if ($LASTEXITCODE -notin @(0, $null)) {
    throw "Torca release metadata generation failed with code $LASTEXITCODE."
}

Write-Host '[torca] release validation and metadata generation completed.'
