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

$requiredFiles = @(
    'release/version.json',
    'LICENSE',
    'SECURITY.md',
    'PRIVACY.md',
    'THIRD_PARTY_NOTICES.md',
    'docs/security/threat-model.md',
    'deny.toml',
    'scripts/release/check-release-version.ps1',
    'scripts/release/torca-release-matrix.json',
    'scripts/release/validate-torca-release.ps1',
    'scripts/release/generate-release-metadata.ps1',
    'scripts/release/release-torca.ps1',
    'apps/mobile/flutter/android/app/src/main/res/xml/data_extraction_rules.xml'
)
foreach ($relative in $requiredFiles) {
    $path = Join-Path $RepositoryRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Release policy file is missing: $relative"
    }
}

foreach ($obsolete in @(
    'scripts/release/torchat-0-1-matrix.json',
    'scripts/release/validate-torchat-0-1.ps1',
    '.github/workflows/release-0-1-validation.yml'
)) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $obsolete)) {
        throw "Obsolete release path is forbidden: $obsolete"
    }
}

$release = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'release/version.json') -Raw |
    ConvertFrom-Json
$matrix = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/release/torca-release-matrix.json') -Raw |
    ConvertFrom-Json
if ($release.product -ne 'Torca' -or $matrix.product -ne 'Torca') {
    throw 'Release version and matrix must use the Torca product name.'
}
if ([int]$matrix.schema -lt 2) {
    throw 'Torca release matrix must use schema 2 or newer.'
}

$validator = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/release/validate-torca-release.ps1') -Raw
foreach ($needle in @(
    "'clippy'",
    "'deny', 'check'",
    "'build', 'apk', '--release'",
    "'build', 'windows', '--release'",
    'Get-FileHash',
    'SHA256',
    'RequirePlatforms',
    'TORCA_VERSION',
    'TORCA_COMMIT',
    'diagnostic-sanitization'
)) {
    if (-not $validator.Contains($needle)) {
        throw "Release validator is missing required gate: $needle"
    }
}
if ($validator -match "'build',\s*'apk',\s*'--debug'") {
    throw 'Official Torca release validator must not build a debug APK.'
}

$wrapper = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/release/release-torca.ps1') -Raw
foreach ($needle in @('validate-torca-release.ps1', '-RequirePlatforms', 'generate-release-metadata.ps1')) {
    if (-not $wrapper.Contains($needle)) {
        throw "Canonical release command is missing: $needle"
    }
}

$metadata = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/release/generate-release-metadata.ps1') -Raw
foreach ($needle in @('CycloneDX', 'cargo', 'metadata', 'flutter', 'pub', 'deps', 'Get-FileHash', 'SHA256')) {
    if (-not $metadata.Contains($needle)) {
        throw "Release metadata generator is missing: $needle"
    }
}

$deny = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'deny.toml') -Raw
if ($deny -notmatch 'unknown-registry\s*=\s*"deny"' -or
    $deny -notmatch 'unknown-git\s*=\s*"deny"') {
    throw 'deny.toml must reject unknown registry and git sources.'
}

$license = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'LICENSE') -Raw
if ($license -notmatch 'AGPL-3\.0-or-later') {
    throw 'LICENSE must declare AGPL-3.0-or-later.'
}

$gradle = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/android/app/build.gradle.kts') -Raw
foreach ($needle in @(
    'TORCHAT_RELEASE_STORE_FILE',
    'TORCHAT_RELEASE_STORE_PASSWORD',
    'TORCHAT_RELEASE_KEY_ALIAS',
    'TORCHAT_RELEASE_KEY_PASSWORD',
    'isMinifyEnabled = true',
    'isShrinkResources = true'
)) {
    if (-not $gradle.Contains($needle)) {
        throw "Android release configuration is missing: $needle"
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/android/app/src/main/AndroidManifest.xml') -Raw
foreach ($needle in @(
    'android:allowBackup="false"',
    'android:fullBackupContent="false"',
    'android:dataExtractionRules="@xml/data_extraction_rules"'
)) {
    if (-not $manifest.Contains($needle)) {
        throw "Android privacy configuration is missing: $needle"
    }
}

$backupRules = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/android/app/src/main/res/xml/data_extraction_rules.xml') -Raw
if ($backupRules -notmatch '<cloud-backup' -or $backupRules -notmatch '<device-transfer>') {
    throw 'Android backup rules must cover cloud backup and device transfer.'
}

& (Join-Path $RepositoryRoot 'scripts/release/check-release-version.ps1') -RepositoryRoot $RepositoryRoot
Write-Host '[torca] release policy check passed.'
