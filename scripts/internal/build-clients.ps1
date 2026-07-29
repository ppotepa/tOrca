[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('local','staging','production')][string]$Environment,
    [ValidateSet('android','windows','all')][string]$Target = 'all',
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$mobileRoot = Join-Path $repoRoot 'mobile'
. (Join-Path $PSScriptRoot 'environment.ps1')
$environmentState = Ensure-TorChatEnvironment $repoRoot $Environment
Import-TorChatEnvironment $environmentState -RequireOnion

function Stop-TorChatFlutterWindows {
    if ($env:OS -ne 'Windows_NT') { return }
    $windowsRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'mobile\build\windows'))
    $running = @(Get-CimInstance Win32_Process -Filter "Name='torchat_mobile.exe'" |
        Where-Object {
            $_.ExecutablePath -and
            [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($windowsRoot, [StringComparison]::OrdinalIgnoreCase)
        })
    foreach ($process in $running) {
        Write-Host "[torchat] Stopping Flutter Windows client PID $($process.ProcessId) before rebuild."
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 1000 }
}

function Build-WindowsFlutterOnNtfs([string]$Variant) {
    $stagingParent = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($stagingParent)) {
        $stagingParent = $env:TEMP
    }
    $stagingRoot = Join-Path $stagingParent ("TorChat\flutter-windows-" + [guid]::NewGuid().ToString('N'))
    $stagingMobile = Join-Path $stagingRoot 'mobile'
    $stagingBuild = Join-Path $stagingMobile 'build\windows'
    $destinationBuild = Join-Path $mobileRoot 'build\windows'
    $repoDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($repoRoot))
    $stagingDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($stagingRoot))
    if ($repoDrive -eq $stagingDrive) {
        throw "Windows Flutter staging must use a different filesystem from the repository ($repoDrive)."
    }

    New-Item -ItemType Directory -Force -Path $stagingMobile | Out-Null
    & robocopy $mobileRoot $stagingMobile /E /NFL /NDL /NJH /NJS /NP `
        /XD (Join-Path $mobileRoot 'build') `
            (Join-Path $mobileRoot '.dart_tool') `
            (Join-Path $mobileRoot 'windows\flutter\ephemeral') `
            (Join-Path $mobileRoot 'android\.gradle') `
        /XF '*.apk' '*.aab' '*.log' | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Could not stage Flutter Windows project (robocopy exit $LASTEXITCODE)." }

    Push-Location $stagingMobile
    try {
        flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'Flutter staging pub get failed.' }
        flutter build windows $Variant
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows staging build failed.' }
    } finally {
        Pop-Location
    }

    New-Item -ItemType Directory -Force -Path $destinationBuild | Out-Null
    & robocopy $stagingBuild $destinationBuild /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Could not copy Flutter Windows build (robocopy exit $LASTEXITCODE)." }
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Push-Location $repoRoot
try {
    if ($Target -in @('windows','all')) {
        & (Join-Path $PSScriptRoot 'build-desktop-runtime.ps1') -Release:$Release
        if (-not $?) { throw 'Desktop Rust runtime build failed.' }
    }
    if ($Target -in @('android','all')) {
        & (Join-Path $PSScriptRoot 'build-android-core.ps1')
        if (-not $?) { throw 'Android Rust core build failed.' }
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
        if ($Target -in @('android','all')) {
            $variant = if ($Release) { 'release' } else { 'debug' }
            flutter build apk "--$variant"
            if ($LASTEXITCODE -ne 0) { throw "Flutter Android $variant build failed." }
        }
        if ($Target -in @('windows','all')) {
            Stop-TorChatFlutterWindows
            $windowsVariant = if ($Release) { '--release' } else { '--debug' }
            Build-WindowsFlutterOnNtfs $windowsVariant
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
