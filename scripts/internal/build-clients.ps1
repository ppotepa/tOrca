[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('local','staging','production')][string]$Environment,
    [ValidateSet('android','windows','all')][string]$Target = 'all',
    [switch]$Release,
    [switch]$Smart
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$mobileRoot = Join-Path $repoRoot 'mobile'
. (Join-Path $PSScriptRoot 'environment.ps1')
. (Join-Path $PSScriptRoot 'build-cache.ps1')
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
        & (Join-Path $PSScriptRoot 'build-desktop-runtime.ps1') -Release:$Release -SkipIfFresh:$Smart
        if (-not $?) { throw 'Desktop Rust engine client build failed.' }
    }
    if ($Target -in @('android','all')) {
        & (Join-Path $PSScriptRoot 'build-android-core.ps1') -SkipIfFresh:$Smart
        if (-not $?) { throw 'Android Rust engine build failed.' }
    }
    $variant = if ($Release) { 'release' } else { 'debug' }
    $windowsVariant = if ($Release) { '--release' } else { '--debug' }
    $windowsBuildVariant = if ($Release) { 'Release' } else { 'Debug' }
    $androidApk = Join-Path $mobileRoot "build\app\outputs\flutter-apk\app-$variant.apk"
    $windowsExe = Join-Path $mobileRoot "build\windows\x64\runner\$windowsBuildVariant\torchat_mobile.exe"
    $androidFlutterHash = $null
    $windowsFlutterHash = $null
    $androidFlutterFresh = $false
    $windowsFlutterFresh = $false
    if ($Smart -and $Target -in @('android','all')) {
        $androidFlutterHash = Get-TorChatInputHash -RepoRoot $repoRoot -Roots @(
            'common\client-engine-contract.json',
            'mobile\pubspec.yaml',
            'mobile\pubspec.lock',
            'mobile\lib',
            'mobile\assets',
            'mobile\android\app\build.gradle.kts',
            'mobile\android\app\src\main',
            'mobile\android\gradle',
            'mobile\android\build.gradle.kts',
            'mobile\android\settings.gradle.kts'
        ) -ExtraValues @(
            "environment=$Environment",
            "config=$($environmentState.Paths.RuntimeEnvironment)",
            "onion=$($env:TORCHAT_ONION_URL)",
            "variant=$variant"
        )
        $androidFlutterFresh = Test-TorChatBuildFresh -RepoRoot $repoRoot -Key "flutter-android-$variant" -Hash $androidFlutterHash -Artifacts @($androidApk)
    }
    if ($Smart -and $Target -in @('windows','all')) {
        $windowsFlutterHash = Get-TorChatInputHash -RepoRoot $repoRoot -Roots @(
            'common\client-engine-contract.json',
            'mobile\pubspec.yaml',
            'mobile\pubspec.lock',
            'mobile\lib',
            'mobile\assets',
            'mobile\windows'
        ) -ExtraValues @(
            "environment=$Environment",
            "config=$($environmentState.Paths.RuntimeEnvironment)",
            "onion=$($env:TORCHAT_ONION_URL)",
            "variant=$windowsBuildVariant"
        )
        $windowsFlutterFresh = Test-TorChatBuildFresh -RepoRoot $repoRoot -Key "flutter-windows-$windowsBuildVariant" -Hash $windowsFlutterHash -Artifacts @($windowsExe)
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
        if (-not ($Smart -and (($Target -eq 'android' -and $androidFlutterFresh) -or ($Target -eq 'windows' -and $windowsFlutterFresh) -or ($Target -eq 'all' -and $androidFlutterFresh -and $windowsFlutterFresh)))) {
            flutter pub get
            if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
        }
        if ($Target -in @('android','all')) {
            if ($androidFlutterFresh) {
                Write-Host "[torchat] Flutter Android APK unchanged; using $androidApk"
            } else {
                flutter build apk "--$variant"
                if ($LASTEXITCODE -ne 0) { throw "Flutter Android $variant build failed." }
                if ($Smart) {
                    Set-TorChatBuildFresh -RepoRoot $repoRoot -Key "flutter-android-$variant" -Hash $androidFlutterHash -Artifacts @($androidApk)
                }
            }
        }
        if ($Target -in @('windows','all')) {
            Stop-TorChatFlutterWindows
            if ($windowsFlutterFresh) {
                Write-Host "[torchat] Flutter Windows client unchanged; using $windowsExe"
            } else {
                Build-WindowsFlutterOnNtfs $windowsVariant
                if ($Smart) {
                    Set-TorChatBuildFresh -RepoRoot $repoRoot -Key "flutter-windows-$windowsBuildVariant" -Hash $windowsFlutterHash -Artifacts @($windowsExe)
                }
            }
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
