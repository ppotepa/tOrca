[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('local','staging','production')][string]$Environment,
    [ValidateSet('android','windows','all')][string]$Target = 'all',
    [switch]$Release,
    [switch]$SkipChecks
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$mobileRoot = Join-Path $repoRoot 'mobile'
. (Join-Path $PSScriptRoot 'environment.ps1')
$environmentState = Ensure-TorChatEnvironment $repoRoot $Environment
Import-TorChatEnvironment $environmentState -RequireOnion

Push-Location $repoRoot
try {
    if (-not $SkipChecks) {
        cargo fmt --all -- --check
        if ($LASTEXITCODE -ne 0) { throw 'cargo fmt check failed.' }
        cargo test --workspace
        if ($LASTEXITCODE -ne 0) { throw 'Rust workspace tests failed.' }
    }
    if ($Target -in @('windows','all')) {
        & (Join-Path $PSScriptRoot 'build-desktop-runtime.ps1') -Release:$Release
        if ($LASTEXITCODE -ne 0) { throw 'Desktop Rust runtime build failed.' }
    }
    if ($Target -in @('android','all')) {
        & (Join-Path $PSScriptRoot 'build-android-core.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Android Rust core build failed.' }
    }
    Push-Location $mobileRoot
    try {
        $previousConfigFile = $env:TORCHAT_CONFIG_FILE
        $previousProfile = $env:TORCHAT_DEV_PROFILE
        $previousPair = $env:TORCHAT_DEV_PAIR
        $env:TORCHAT_CONFIG_FILE = $environmentState.Paths.RuntimeEnvironment
        # Fixtures are opt-in; normal developer builds exercise real onboarding.
        $env:TORCHAT_DEV_PROFILE = ''
        $env:TORCHAT_DEV_PAIR = 'false'
        flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
        if (-not $SkipChecks) {
            flutter analyze
            if ($LASTEXITCODE -ne 0) { throw 'flutter analyze failed.' }
            flutter test
            if ($LASTEXITCODE -ne 0) { throw 'flutter test failed.' }
        }
        if ($Target -in @('android','all')) {
            $variant = if ($Release) { 'release' } else { 'debug' }
            flutter build apk "--$variant"
            if ($LASTEXITCODE -ne 0) { throw "Flutter Android $variant build failed." }
        }
        if ($Target -in @('windows','all')) {
            flutter build windows
            if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed.' }
        }
    } finally {
        $env:TORCHAT_CONFIG_FILE = $previousConfigFile
        $env:TORCHAT_DEV_PROFILE = $previousProfile
        $env:TORCHAT_DEV_PAIR = $previousPair
        Pop-Location
    }
} finally {
    Pop-Location
}
