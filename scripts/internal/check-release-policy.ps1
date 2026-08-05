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
    'release/update-manifest.schema.json',
    'LICENSE',
    'SECURITY.md',
    'PRIVACY.md',
    'THIRD_PARTY_NOTICES.md',
    'docs/security/threat-model.md',
    'deny.toml',
    'scripts/release/check-release-version.ps1',
    'scripts/release/torca-release-matrix.json',
    'scripts/release/validate-torca-release.ps1',
    'scripts/release/collect-release-artifacts.ps1',
    'scripts/release/generate-release-metadata.ps1',
    'scripts/release/generate-update-manifest.ps1',
    'scripts/release/release-torca.ps1',
    'apps/mobile/flutter/android/app/src/main/res/xml/data_extraction_rules.xml',
    'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/mobile/EngineMethodDispatcher.kt',
    'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/mobile/ProfileReset.kt',
    'apps/mobile/flutter/lib/core/release/release_info.dart',
    'apps/mobile/flutter/lib/core/release/update_manifest.dart',
    'apps/mobile/flutter/lib/platform/update_check_service.dart',
    'apps/mobile/flutter/lib/platform/diagnostics_export_service.dart',
    'apps/mobile/flutter/lib/platform/profile_reset_service.dart',
    'apps/mobile/flutter/lib/core/attachments/image_attachment_policy.dart',
    'apps/mobile/flutter/lib/core/attachments/image_message_codec.dart',
    'apps/desktop/flutter/lib/platform/desktop/desktop_profile_reset.dart'
)
foreach ($relative in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $relative) -PathType Leaf)) {
        throw "Release policy file is missing: $relative"
    }
}

foreach ($obsolete in @(
    'scripts/release/torchat-0-1-matrix.json',
    'scripts/release/validate-torchat-0-1.ps1',
    '.github/workflows/release-0-1-validation.yml',
    'apps/desktop/native/src/secret_migration.rs'
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
    'TORCA_UPDATE_KEY_ID',
    'TORCA_UPDATE_PUBLIC_KEY',
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
foreach ($needle in @(
    'check-release-policy.ps1',
    'validate-torca-release.ps1',
    '-RequirePlatforms',
    'collect-release-artifacts.ps1',
    'generate-release-metadata.ps1',
    'generate-update-manifest.ps1'
)) {
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
$updateGenerator = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/release/generate-update-manifest.ps1') -Raw
foreach ($needle in @('ed25519', 'openssl', 'pkeyutl', '-sign', '-rawin', 'Get-FileHash', 'SHA256')) {
    if (-not $updateGenerator.Contains($needle)) {
        throw "Update manifest generator is missing: $needle"
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

$diagnostics = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/lib/platform/diagnostics_export_service.dart') -Raw
foreach ($needle in @(
    "'sanitized': true",
    "'automaticUpload': false",
    "'messagePlaintextIncluded': false",
    "'privateKeysIncluded': false",
    'GZipCodec'
)) {
    if (-not $diagnostics.Contains($needle)) {
        throw "Diagnostic export is missing privacy control: $needle"
    }
}
foreach ($forbidden in @('HttpClient', 'WebSocket', 'Socket.connect', 'MultipartRequest', 'upload(')) {
    if ($diagnostics.Contains($forbidden)) {
        throw "Diagnostic export must remain local; forbidden network API: $forbidden"
    }
}

$androidActivity = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/mobile/MainActivity.kt') -Raw
$androidDispatcher = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/mobile/EngineMethodDispatcher.kt') -Raw
$androidReset = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/mobile/ProfileReset.kt') -Raw
if (-not $androidActivity.Contains('EngineMethodDispatcher')) {
    throw 'MainActivity must delegate engine method routing.'
}
foreach ($needle in @('"resetLocalProfile"', 'ProfileReset.clear')) {
    if (-not $androidDispatcher.Contains($needle)) {
        throw "Android reset dispatch is missing: $needle"
    }
}
foreach ($needle in @('clearApplicationUserData()', 'stopService(')) {
    if (-not $androidReset.Contains($needle)) {
        throw "Android profile reset is missing: $needle"
    }
}

$desktopReset = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/desktop/flutter/lib/platform/desktop/desktop_profile_reset.dart') -Raw
foreach ($needle in @('stopRuntime()', "'--reset-profile'", 'SharedPreferences.getInstance()', 'preferences.clear()')) {
    if (-not $desktopReset.Contains($needle)) {
        throw "Desktop profile reset is missing: $needle"
    }
}
$desktopIdentity = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/desktop/native/src/identity_store.rs') -Raw
foreach ($needle in @('pub fn reset_profile(', 'remove_profile_files(', 'remove_managed_tor_data(')) {
    if (-not $desktopIdentity.Contains($needle)) {
        throw "Native desktop profile reset is missing: $needle"
    }
}

$attachmentPolicy = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/lib/core/attachments/image_attachment_policy.dart') -Raw
$attachmentCodec = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/lib/core/attachments/image_message_codec.dart') -Raw
foreach ($needle in @(
    'maximumSourceBytes',
    'maximumEncodedBytes',
    'maximumPixels',
    'maximumFrames = 1',
    'maximumMessageBodyCharacters'
)) {
    if (-not $attachmentPolicy.Contains($needle)) {
        throw "Attachment policy is missing: $needle"
    }
}
foreach ($needle in @('findDecoderForData', 'startDecode', 'decodeFrame(0)', 'info.numFrames != 1')) {
    if (-not $attachmentCodec.Contains($needle)) {
        throw "Attachment codec preflight is missing: $needle"
    }
}

$updateClient = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/lib/core/release/update_manifest.dart') -Raw
$updateService = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'apps/mobile/flutter/lib/platform/update_check_service.dart') -Raw
foreach ($needle in @('Ed25519().verify', 'expectedKeyId', 'sha256', 'isNewerThan')) {
    if (-not $updateClient.Contains($needle)) {
        throw "Update verification is missing: $needle"
    }
}
foreach ($forbidden in @('HttpClient', 'WebSocket', 'Socket.connect')) {
    if ($updateService.Contains($forbidden)) {
        throw "Update checking must remain offline; forbidden API: $forbidden"
    }
}

& (Join-Path $RepositoryRoot 'scripts/release/check-release-version.ps1') -RepositoryRoot $RepositoryRoot
Write-Host '[torca] release policy check passed.'
