[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [ValidateSet('all', 'android', 'windows')]
    [string]$Target = 'all',
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$release = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'release/version.json') -Raw |
    ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot ".torca/artifacts/$($release.version)"
}
if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Copy-RequiredArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$DestinationName
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required Torca release artifact is missing: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $OutputDirectory $DestinationName) -Force
}

if ($Target -in @('all', 'android')) {
    Copy-RequiredArtifact `
        -Source (Join-Path $RepositoryRoot 'apps/mobile/flutter/build/app/outputs/flutter-apk/app-release.apk') `
        -DestinationName "torca-$($release.version)-android.apk"
    $bundle = Join-Path $RepositoryRoot 'apps/mobile/flutter/build/app/outputs/bundle/release/app-release.aab'
    if (Test-Path -LiteralPath $bundle -PathType Leaf) {
        Copy-Item -LiteralPath $bundle `
            -Destination (Join-Path $OutputDirectory "torca-$($release.version)-android.aab") `
            -Force
    }
}

if ($Target -in @('all', 'windows')) {
    if ($env:OS -ne 'Windows_NT') {
        throw 'Collecting the Windows release bundle requires a Windows host.'
    }
    $bundleRoot = Join-Path $RepositoryRoot 'apps/desktop/flutter/build/windows/x64/runner/Release'
    if (-not (Test-Path -LiteralPath $bundleRoot -PathType Container)) {
        throw "Windows release bundle is missing: $bundleRoot"
    }
    $archive = Join-Path $OutputDirectory "torca-$($release.version)-windows-x64.zip"
    Compress-Archive -Path (Join-Path $bundleRoot '*') -DestinationPath $archive -CompressionLevel Optimal
}

$legalDirectory = Join-Path $OutputDirectory 'legal'
New-Item -ItemType Directory -Force -Path $legalDirectory | Out-Null
foreach ($relative in @('LICENSE', 'PRIVACY.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md')) {
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot $relative) `
        -Destination (Join-Path $legalDirectory $relative) -Force
}

Write-Host "Torca release artifacts: $OutputDirectory"
Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse | ForEach-Object {
    Write-Host " - $([IO.Path]::GetRelativePath($OutputDirectory, $_.FullName))"
}
