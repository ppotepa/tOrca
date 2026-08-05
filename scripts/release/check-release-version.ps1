[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path

$versionPath = Join-Path $RepositoryRoot 'release/version.json'
if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    throw "Release version source is missing: $versionPath"
}
$release = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
if ($release.product -ne 'Torca') {
    throw "release/version.json product must be Torca, found '$($release.product)'."
}
if ($release.version -notmatch '^0\.2\.0-(alpha|beta|rc)\.[1-9][0-9]*$|^0\.2\.0$') {
    throw "Unsupported Torca 0.2 version: '$($release.version)'."
}
if ([int]$release.build -lt 1) {
    throw 'Release build number must be positive.'
}
if ($release.channel -notin @('alpha', 'beta', 'stable')) {
    throw "Unsupported release channel: '$($release.channel)'."
}

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $content = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($content, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $match.Success) {
        throw "Unable to read $Description from $Path."
    }
    if ($match.Groups[1].Value -ne $Expected) {
        throw "$Description mismatch in $Path: expected '$Expected', found '$($match.Groups[1].Value)'."
    }
}

Assert-Match `
    -Path (Join-Path $RepositoryRoot 'Cargo.toml') `
    -Pattern '(?ms)^\[workspace\.package\].*?^version\s*=\s*"([^"]+)"' `
    -Expected $release.version `
    -Description 'Rust workspace version'

$flutterVersion = "$($release.version)+$($release.build)"
foreach ($pubspec in @(
    'apps/mobile/flutter/pubspec.yaml',
    'apps/desktop/flutter/pubspec.yaml'
)) {
    Assert-Match `
        -Path (Join-Path $RepositoryRoot $pubspec) `
        -Pattern '(?m)^version:\s*([^\s]+)\s*$' `
        -Expected $flutterVersion `
        -Description 'Flutter version'
}

$readme = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'README.md') -Raw
if ($readme -notmatch '(?m)^# Torca\s*$') {
    throw 'README product heading must be Torca.'
}

Write-Host "[torca] release version is consistent: $($release.version)+$($release.build) ($($release.channel))."
