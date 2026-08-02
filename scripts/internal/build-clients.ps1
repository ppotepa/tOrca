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
    $windowsRootLower = $windowsRoot.ToLowerInvariant()
    $mobileRootLower = [IO.Path]::GetFullPath($mobileRoot).ToLowerInvariant()

    $toolNames = @(
        'torchat_mobile.exe',
        'flutter.exe',
        'dart.exe',
        'clang.exe',
        'clang-cl.exe',
        'lld-link.exe',
        'link.exe',
        'ninja.exe',
        'cmake.exe',
        'msbuild.exe',
        'cc1.exe'
    ) | ForEach-Object { $_.ToLowerInvariant() }

    $allBuildProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        $name = if ($_.Name) { $_.Name.ToLowerInvariant() } else { '' }
        $path = if ($_.ExecutablePath) { [IO.Path]::GetFullPath($_.ExecutablePath).ToLowerInvariant() } else { '' }
        $commandLine = if ($_.CommandLine) { $_.CommandLine.ToLowerInvariant() } else { '' }
        ($toolNames -contains $name) -and (
            ($path.StartsWith($windowsRootLower, [StringComparison]::OrdinalIgnoreCase)) -or
            ($path.StartsWith($mobileRootLower, [StringComparison]::OrdinalIgnoreCase)) -or
            ($commandLine.Contains($windowsRootLower)) -or
            ($commandLine.Contains($mobileRootLower)) -or
            ($commandLine.Contains($windowsRootLower.Replace('\','/'))) -or
            ($commandLine.Contains($mobileRootLower.Replace('\','/')))
        )
    })

    # The Flutter runner can keep the Debug directory open even after its
    # parent process has disappeared from the normal toolchain query. Always
    # include the app runner and terminate its child tree before cleanup.
    $runnerProcesses = @(Get-CimInstance Win32_Process -Filter "Name='torchat_mobile.exe'" |
        Where-Object {
            $commandLine = if ($_.CommandLine) { $_.CommandLine.ToLowerInvariant() } else { '' }
            $path = if ($_.ExecutablePath) { [IO.Path]::GetFullPath($_.ExecutablePath).ToLowerInvariant() } else { '' }
            $path.StartsWith($windowsRootLower, [StringComparison]::OrdinalIgnoreCase) -or
            $commandLine.Contains($windowsRootLower.Replace('\','/')) -or
            $commandLine.Contains($mobileRootLower.Replace('\','/'))
        })
    $allBuildProcesses = @($allBuildProcesses + $runnerProcesses | Sort-Object ProcessId -Unique)

    if ($allBuildProcesses.Count -gt 0) {
        Write-Host "[torchat] Stopping Windows Flutter toolchain processes before rebuild: $($allBuildProcesses.Count)"
        foreach ($process in $allBuildProcesses) {
            Write-Host "[torchat] Stopping process PID $($process.ProcessId) ($($process.Name))"
            try { & taskkill.exe /PID ([int]$process.ProcessId) /T /F 2>$null | Out-Null } catch { }
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 2500
    }

    $running = @(Get-CimInstance Win32_Process -Filter "Name='torchat_mobile.exe'" |
        Where-Object {
            $_.ExecutablePath -and
            [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($windowsRoot, [StringComparison]::OrdinalIgnoreCase)
        })
    foreach ($process in $running) {
        Write-Host "[torchat] Stopping Flutter Windows client PID $($process.ProcessId) before rebuild."
        try { & taskkill.exe /PID ([int]$process.ProcessId) /T /F 2>$null | Out-Null } catch { }
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 1000 }
}

function Remove-TorChatDirectoryRobust {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            Remove-Item -LiteralPath $resolvedPath -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if (($attempt % 2) -eq 1) {
                Stop-TorChatFlutterWindows
            }
            if ($attempt -eq 6) { break }
            Write-Warning "$Description removal attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }

    if ($env:OS -ne 'Windows_NT' -or -not (Get-Command robocopy -ErrorAction SilentlyContinue)) {
        try {
            Remove-Item -LiteralPath $resolvedPath -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "$Description cannot be removed now; continuing with in-place synchronization: $($_.Exception.Message)"
        }
        return
    }

    $emptyRoot = Join-Path ([IO.Path]::GetTempPath()) "torchat-empty-$PID-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $emptyRoot | Out-Null
    try {
        & robocopy $emptyRoot $resolvedPath /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -gt 7) {
            throw "$Description cleanup mirror failed (robocopy exit $LASTEXITCODE)."
        }
    } catch {
        Write-Warning $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $emptyRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    try {
        Remove-Item -LiteralPath $resolvedPath -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "$Description final cleanup failed: $($_.Exception.Message). Continuing."
    }
}

function Build-WindowsFlutterOnNtfs([string]$Variant) {
    $stagingParent = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($stagingParent)) {
        $stagingParent = $env:TEMP
    }
    $repoBytes = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($repoRoot).ToLowerInvariant())
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $repoHash = ([BitConverter]::ToString($sha256.ComputeHash($repoBytes)) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
    $stagingRoot = Join-Path $stagingParent "TorChat\flutter-windows\$repoHash"
    $stagingMobile = Join-Path $stagingRoot 'mobile'
    $stagingBuild = Join-Path $stagingMobile 'build\windows'
    $destinationBuild = Join-Path $mobileRoot 'build\windows'
    $repoDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($repoRoot))
    $stagingDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($stagingRoot))
    if ($repoDrive -eq $stagingDrive) {
        throw "Windows Flutter staging must use a different filesystem from the repository ($repoDrive)."
    }

    Stop-TorChatFlutterWindows
    if (Test-Path -LiteralPath $stagingMobile) {
        Write-Host "[torchat] Removing stale Windows Flutter staging directory: $stagingMobile"
        Remove-TorChatDirectoryRobust -Path $stagingMobile -Description 'Windows Flutter staging directory'
    }
    New-Item -ItemType Directory -Force -Path $stagingMobile | Out-Null
    & robocopy $mobileRoot $stagingMobile /E /NFL /NDL /NJH /NJS /NP `
        /XD (Join-Path $mobileRoot 'build') `
            (Join-Path $mobileRoot '.dart_tool') `
            (Join-Path $mobileRoot 'windows\flutter\ephemeral') `
            (Join-Path $mobileRoot 'android') `
        /XF '*.apk' '*.aab' '*.log' | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Could not stage Flutter Windows project (robocopy exit $LASTEXITCODE)." }

    Push-Location $stagingMobile
    try {
        flutter build windows $Variant
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows staging build failed.' }
    } finally {
        Pop-Location
    }

    Stop-TorChatFlutterWindows
    if (Test-Path -LiteralPath $destinationBuild) {
        Write-Host "[torchat] Removing stale Windows Flutter output directory: $destinationBuild"
        Remove-TorChatDirectoryRobust -Path $destinationBuild -Description 'Windows Flutter output directory'
    }
    New-Item -ItemType Directory -Force -Path $destinationBuild | Out-Null
    $copyExit = 16
    for ($copyAttempt = 1; $copyAttempt -le 6; $copyAttempt++) {
        & robocopy $stagingBuild $destinationBuild /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
        $copyExit = $LASTEXITCODE
        if ($copyExit -le 7) { break }
        Write-Warning "Windows Flutter build synchronization attempt $copyAttempt failed (robocopy exit $copyExit)."
        Stop-TorChatFlutterWindows
        Start-Sleep -Milliseconds (500 * $copyAttempt)
    }
    if ($copyExit -gt 7) { throw "Could not copy Flutter Windows build (robocopy exit $copyExit)." }
}

function Build-AndroidFlutterOnNtfs([string]$Variant) {
    # Flutter resolves every declared plugin (including desktop plugins) during
    # pub get and creates plugin symlinks.  The repository may live on a drive
    # that does not support those symlinks, even though Android itself does not
    # need the Windows plugin tree. Build from a local NTFS staging copy so the
    # Android build is deterministic and never mutates the checkout.
    if ($env:OS -ne 'Windows_NT') {
        Push-Location $mobileRoot
        try {
            flutter pub get
            if ($LASTEXITCODE -ne 0) { throw 'Flutter pub get failed.' }
            flutter build apk "--$Variant"
            if ($LASTEXITCODE -ne 0) { throw "Flutter Android $Variant staging build failed." }
        } finally { Pop-Location }
        return
    }

    $stagingParent = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($stagingParent)) { $stagingParent = $env:TEMP }
    $stagingRoot = Join-Path $stagingParent "TorChat\flutter-android\$([Guid]::NewGuid().ToString('N'))"
    $stagingMobile = Join-Path $stagingRoot 'mobile'
    $stagingApk = Join-Path $stagingMobile "build\app\outputs\flutter-apk\app-$Variant.apk"
    $destinationApk = Join-Path $mobileRoot "build\app\outputs\flutter-apk\app-$Variant.apk"
    New-Item -ItemType Directory -Force -Path $stagingMobile | Out-Null
    try {
        & robocopy $mobileRoot $stagingMobile /E /NFL /NDL /NJH /NJS /NP `
            /XD (Join-Path $mobileRoot 'build') `
                (Join-Path $mobileRoot '.dart_tool') `
                (Join-Path $mobileRoot 'windows\flutter\ephemeral') | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "Could not stage Flutter Android project (robocopy exit $LASTEXITCODE)." }

        Push-Location $stagingMobile
        try {
            flutter pub get
            if ($LASTEXITCODE -ne 0) { throw 'Flutter Android staging pub get failed.' }
            flutter build apk "--$Variant"
            if ($LASTEXITCODE -ne 0) { throw "Flutter Android $Variant staging build failed." }
        } finally { Pop-Location }

        if (-not (Test-Path -LiteralPath $stagingApk)) {
            throw "Flutter Android artifact missing: $stagingApk"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationApk) | Out-Null
        Copy-Item -LiteralPath $stagingApk -Destination $destinationApk -Force
    } finally {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
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
            'mobile\android\app\src\main\AndroidManifest.xml',
            'mobile\android\app\src\main\assets',
            'mobile\android\app\src\main\java',
            'mobile\android\app\src\main\kotlin',
            'mobile\android\app\src\main\res',
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
        if ($Target -in @('android','all')) {
            if ($androidFlutterFresh) {
                Write-Host "[torchat] Flutter Android APK unchanged; using $androidApk"
            } else {
                Build-AndroidFlutterOnNtfs $variant
                if ($Smart) {
                    Set-TorChatBuildFresh -RepoRoot $repoRoot -Key "flutter-android-$variant" -Hash $androidFlutterHash -Artifacts @($androidApk)
                }
            }
        }
        if ($Target -in @('windows','all')) {
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
