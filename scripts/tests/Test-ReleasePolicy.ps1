[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$checker = Join-Path $repoRoot 'scripts/internal/check-release-policy.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("torca-policy-" + [guid]::NewGuid().ToString('N'))

$files = @(
    'release/version.json',
    'Cargo.toml',
    'README.md',
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
    'apps/mobile/flutter/pubspec.yaml',
    'apps/desktop/flutter/pubspec.yaml',
    'apps/mobile/flutter/android/app/build.gradle.kts',
    'apps/mobile/flutter/android/app/src/main/AndroidManifest.xml',
    'apps/mobile/flutter/android/app/src/main/res/xml/data_extraction_rules.xml'
)

try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    foreach ($relative in $files) {
        $source = Join-Path $repoRoot $relative
        $destination = Join-Path $tempRoot $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    & $checker -RepositoryRoot $tempRoot | Out-Null

    $manifest = Join-Path $tempRoot 'apps/mobile/flutter/android/app/src/main/AndroidManifest.xml'
    (Get-Content -LiteralPath $manifest -Raw).Replace(
        'android:allowBackup="false"',
        'android:allowBackup="true"'
    ) | Set-Content -LiteralPath $manifest -Encoding UTF8

    $failedAsExpected = $false
    try {
        & $checker -RepositoryRoot $tempRoot | Out-Null
    } catch {
        $failedAsExpected = $_.Exception.Message -match 'allowBackup'
    }
    if (-not $failedAsExpected) {
        throw 'Release policy did not reject Android backup being enabled.'
    }
    Write-Output 'Torca release policy positive and negative tests passed.'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
