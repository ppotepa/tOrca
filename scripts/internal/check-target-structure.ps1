[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Assert-Path([string]$relativePath, [bool]$directory = $true) {
    $path = Join-Path $repoRoot $relativePath
    if ($directory -and -not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Missing target directory: $relativePath"
    }
    if (-not $directory -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing target file: $relativePath"
    }
}

@(
    'apps/desktop/native',
    'apps/desktop/flutter/windows',
    'apps/desktop/flutter/lib/platform/desktop',
    'apps/mobile/flutter/android',
    'packages/torchat-client-engine-ffi',
    'packages/torchat-client-engine',
    'packages/torchat-crypto',
    'packages/torchat-domain',
    'packages/torchat-flutter-ui',
    'packages/torchat-peer',
    'packages/torchat-protocol',
    'packages/torchat-relay-protocol',
    'packages/torchat-rendezvous-client',
    'packages/torchat-runtime',
    'packages/torchat-storage',
    'services/torchat-relay',
    'tests/fixtures/protocol'
) | ForEach-Object { Assert-Path $_ }

@(
    'Cargo.toml',
    'scripts/torchat.ps1',
    'docs/architecture/dependency-rules.md'
) | ForEach-Object { Assert-Path $_ $false }

@(
    'desktop',
    'mobile',
    'server',
    'protocol/dev-fixtures',
    'common/torchat-client-runtime',
    'common/torchat-client-engine',
    'common/torchat-client-engine-ffi',
    'common/torchat-client-engine/src/storage',
    'common/torchat-client-engine/src/peer',
    'common/torchat-client-engine/sql',
    'common/torchat-core/src/mls.rs'
) | ForEach-Object {
    $path = Join-Path $repoRoot $_
    if (Test-Path -LiteralPath $path) { throw "Retired path still exists: $_" }
}

$windowsWorkflow = Get-Content -Raw (Join-Path $repoRoot '.github/workflows/release-0-1-validation.yml')
if ($windowsWorkflow -notmatch '(?ms)windows:.*?working-directory:\s*apps/desktop/flutter') {
    throw 'Windows CI job must run from apps/desktop/flutter'
}
if ($windowsWorkflow -match '(?ms)windows:.*?apps/mobile/flutter/build/windows') {
    throw 'Windows CI job still references the retired mobile Windows build path'
}

$releaseValidator = Get-Content -Raw (Join-Path $repoRoot 'scripts/release/validate-torchat-0-1.ps1')
if ($releaseValidator -match "windows-desktop.*?apps\\mobile\\flutter|apps\\mobile\\flutter.*?build.*?windows") {
    throw 'Release validator still builds Windows from the mobile runner'
}

$iconPath = Join-Path $repoRoot 'apps/desktop/flutter/windows/runner/resources/app_icon.ico'
$iconBytes = [IO.File]::ReadAllBytes($iconPath)
if ($iconBytes.Length -lt 22 -or $iconBytes[0] -ne 0 -or $iconBytes[1] -ne 0 -or
    $iconBytes[2] -ne 1 -or $iconBytes[3] -ne 0) {
    throw 'Desktop Windows app_icon.ico is missing or is not a valid ICO file'
}

Write-Host '[torchat] target structure check passed'
