Set-StrictMode -Version Latest

function Get-TorChatBuildStatePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $safeKey = $Key -replace '[^A-Za-z0-9_.-]', '_'
    $root = Join-Path $RepositoryRoot '.torchat\build-state'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Join-Path $root "$safeKey.json"
}

function Get-TorChatRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $base = [IO.Path]::GetFullPath($BasePath).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $baseUri = New-Object Uri($base)
    $pathUri = New-Object Uri([IO.Path]::GetFullPath($Path))
    [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()) -replace '/', '\'
}

function Get-TorChatInputHash {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Roots,
        [string[]]$ExtraValues = @()
    )
    $excluded = @('.git','.codegraph','.torchat','target','build','.gradle','.kotlin','.dart_tool','ephemeral')
    $records = New-Object Collections.Generic.List[string]
    foreach ($root in $Roots) {
        $path = if ([IO.Path]::IsPathRooted($root)) { $root } else { Join-Path $RepositoryRoot $root }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $files = if (Test-Path -LiteralPath $path -PathType Leaf) {
            @(Get-Item -LiteralPath $path)
        } else {
            @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
                $relative = Get-TorChatRelativePath -BasePath $RepositoryRoot -Path $_.FullName
                $parts = $relative -split '[\\/]'
                @($parts | Where-Object { $excluded -contains $_ }).Count -eq 0
            })
        }
        foreach ($file in $files) {
            $relativePath = (Get-TorChatRelativePath -BasePath $RepositoryRoot -Path $file.FullName) -replace '\\', '/'
            $fileHash = (Get-TorChatFileSha256 -Path $file.FullName).ToLowerInvariant()
            $records.Add("$relativePath=$fileHash")
        }
    }
    foreach ($value in $ExtraValues) { $records.Add("env=$value") }
    $payload = [Text.Encoding]::UTF8.GetBytes((@($records | Sort-Object) -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        (($sha.ComputeHash($payload) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function Test-TorChatBuildFresh {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string[]]$Artifacts
    )
    foreach ($artifact in $Artifacts) {
        if (-not (Test-Path -LiteralPath $artifact)) { return $false }
    }
    $statePath = Get-TorChatBuildStatePath -RepositoryRoot $RepositoryRoot -Key $Key
    if (-not (Test-Path -LiteralPath $statePath)) { return $false }
    try {
        return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).hash -eq $Hash
    } catch {
        return $false
    }
}

function Set-TorChatBuildFresh {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string[]]$Artifacts
    )
    [pscustomobject]@{
        key = $Key
        hash = $Hash
        artifacts = $Artifacts
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-TorChatBuildStatePath -RepositoryRoot $RepositoryRoot -Key $Key) -Encoding UTF8
}

function Get-TorChatFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Remove-TorChatDirectoryRobust {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolved = [IO.Path]::GetFullPath($Path)
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            # Interrupted native builds can leave a generated directory with
            # a broken inherited ACL on Windows. Reset only this exact build
            # path before removal; never broaden the cleanup scope.
            if ($env:OS -eq 'Windows_NT') {
                & icacls $resolved /reset /T /C *> $null
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq 4) { break }
            Write-TorChatWarning "$Description removal attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
    # Cleanup is best-effort. The destination is synchronized below and must
    # not make an otherwise valid Flutter build fail only because Windows,
    # Defender, or an indexer still owns the directory handle.
    Write-TorChatWarning "$Description remains locked; continuing with in-place synchronization."
}

function Stop-TorChatBuildProcesses {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    if ($env:OS -ne 'Windows_NT') { return }
    $repoPath = [IO.Path]::GetFullPath($RepositoryRoot).ToLowerInvariant()
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $name = if ($_.Name) { $_.Name.ToLowerInvariant() } else { '' }
        $path = if ($_.ExecutablePath) { [IO.Path]::GetFullPath($_.ExecutablePath).ToLowerInvariant() } else { '' }
        $command = if ($_.CommandLine) { $_.CommandLine.ToLowerInvariant() } else { '' }
        # The Flutter runner can keep a DLL open while its command line has
        # already disappeared (and its executable may come from a staging
        # directory). Always stop TorChat-owned binaries by name; retain the
        # repository guard for generic build tools.
        (($name -in @('torchat_desktop.exe','torchat-desktop.exe')) -or
          ($name -in @('flutter.exe','dart.exe','cmake.exe','msbuild.exe','ninja.exe') -and
            ($path.StartsWith($repoPath) -or $command.Contains($repoPath) -or $command.Contains($repoPath.Replace('\','/')))))
    } | Sort-Object ProcessId -Unique)
    foreach ($process in $processes) {
        # The WMI snapshot can race normal process shutdown. A PID which has
        # already exited is success for this cleanup step and must not abort
        # the entire build under PSNativeCommandUseErrorActionPreference.
        try { & taskkill.exe /PID ([int]$process.ProcessId) /T /F 2>$null | Out-Null } catch { }
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    if ($processes.Count -gt 0) { Start-Sleep -Milliseconds 1500 }
}

function Resolve-TorChatAndroidNdk {
    param([string]$AndroidNdk)
    if (-not [string]::IsNullOrWhiteSpace($AndroidNdk) -and (Test-Path -LiteralPath $AndroidNdk)) {
        return $AndroidNdk
    }
    $sdk = $env:ANDROID_SDK_ROOT
    if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = $env:ANDROID_HOME }
    if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $resolved = Get-ChildItem (Join-Path $sdk 'ndk') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($resolved) -or -not (Test-Path -LiteralPath $resolved)) {
        throw 'Android NDK not found. Install it through Android Studio or set ANDROID_NDK_HOME.'
    }
    $resolved
}

function Initialize-TorChatAndroidToolchain {
    param(
        [Parameter(Mandatory = $true)][string]$AndroidNdk,
        [Parameter(Mandatory = $true)][string]$RustTarget,
        [Parameter(Mandatory = $true)][string]$ToolPrefix
    )
    foreach ($candidate in @('C:\msys64\usr\bin','C:\Program Files\Git\usr\bin','C:\Strawberry\perl\bin')) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'perl.exe')) {
            $env:PATH = "$candidate;$env:PATH"
            break
        }
    }
    $env:ANDROID_NDK_HOME = $AndroidNdk -replace '\\', '/'
    $targetEnv = $RustTarget.ToUpperInvariant().Replace('-','_')
    $targetUnderscore = $RustTarget.Replace('-','_')
    $llvmBin = "$env:ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/bin"
    $clang = "$llvmBin/$($ToolPrefix)21-clang.cmd"
    $clangExe = "$llvmBin/clang.exe"
    $ar = "$llvmBin/llvm-ar.exe"
    $ranlib = "$llvmBin/llvm-ranlib.exe"
    if (-not (Test-Path -LiteralPath $clang) -or -not (Test-Path -LiteralPath $clangExe)) {
        throw "Android NDK clang not found for $RustTarget in $llvmBin."
    }
    [Environment]::SetEnvironmentVariable("CARGO_TARGET_$($targetEnv)_LINKER", $clang, 'Process')
    foreach ($name in @("CC_$RustTarget","CC_$targetUnderscore")) {
        [Environment]::SetEnvironmentVariable($name, $clangExe, 'Process')
    }
    foreach ($name in @("AR_$RustTarget","AR_$targetUnderscore")) {
        [Environment]::SetEnvironmentVariable($name, $ar, 'Process')
    }
    foreach ($name in @("RANLIB_$RustTarget","RANLIB_$targetUnderscore")) {
        [Environment]::SetEnvironmentVariable($name, $ranlib, 'Process')
    }
    foreach ($name in @("CFLAGS_$RustTarget","CFLAGS_$targetUnderscore")) {
        [Environment]::SetEnvironmentVariable($name, "--target=$($RustTarget)21", 'Process')
    }
}

function Build-TorChatDesktopEngine {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [ValidateSet('smart','rebuild')][string]$Policy = 'smart'
    )
    Assert-TorChatTool -Name cargo
    Import-TorChatEnvironmentState -EnvironmentState $EnvironmentState -RequireOnion
    $profile = if ($Context.Configuration -eq 'release') { 'release' } else { 'debug' }
    $binaryName = if ($env:OS -eq 'Windows_NT') { 'torchat-desktop.exe' } else { 'torchat-desktop' }
    $artifact = Join-Path $Context.RepositoryRoot "target\$profile\$binaryName"
    $hash = Get-TorChatInputHash -RepositoryRoot $Context.RepositoryRoot -Roots @(
        'Cargo.toml','Cargo.lock','common\client-engine-contract.json','common\torchat-core',
        'packages\torchat-runtime','packages\torchat-client-engine','apps\desktop\native'
    ) -ExtraValues @(
        "profile=$profile",
        "onion=$($EnvironmentState.Values['TORCHAT_ONION_URL'])",
        "os=$env:OS"
    )
    if ($Policy -eq 'smart' -and (Test-TorChatBuildFresh -RepositoryRoot $Context.RepositoryRoot -Key "desktop-runtime-$profile" -Hash $hash -Artifacts @($artifact))) {
        return [pscustomobject]@{ State = 'Skipped'; Code = 'DESKTOP_ENGINE_FRESH'; Message = 'Desktop engine unchanged'; Artifact = $artifact }
    }
    Stop-TorChatBuildProcesses -RepositoryRoot $Context.RepositoryRoot
    if ($env:OS -eq 'Windows_NT') {
        $perlRoot = @('C:\Strawberry\perl\bin','C:\Perl64\bin','C:\Perl\bin') |
            Where-Object { Test-Path -LiteralPath (Join-Path $_ 'perl.exe') } |
            Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($perlRoot)) {
            throw 'Native Windows Perl is required for desktop OpenSSL builds.'
        }
        $env:PATH = "$perlRoot;$env:PATH"
    }
    $previous = $env:TORCHAT_COMPILED_ONION_URL
    $env:TORCHAT_COMPILED_ONION_URL = [string]$EnvironmentState.Values['TORCHAT_ONION_URL']
    try {
        $args = @('build','-p','torchat-desktop')
        if ($Context.Configuration -eq 'release') { $args += '--release' }
        [void](Invoke-TorChatNative -Context $Context -FilePath 'cargo' -ArgumentList $args -WorkingDirectory $Context.RepositoryRoot -LogName 'cargo-desktop.log')
    } finally {
        $env:TORCHAT_COMPILED_ONION_URL = $previous
    }
    if (-not (Test-Path -LiteralPath $artifact)) { throw "Desktop engine artifact missing: $artifact" }
    Set-TorChatBuildFresh -RepositoryRoot $Context.RepositoryRoot -Key "desktop-runtime-$profile" -Hash $hash -Artifacts @($artifact)
    [pscustomobject]@{ State = 'Ready'; Code = 'DESKTOP_ENGINE_BUILT'; Message = $artifact; Artifact = $artifact }
}

function Build-TorChatAndroidEngine {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [ValidateSet('smart','rebuild')][string]$Policy = 'smart',
        [string]$RustTarget = 'aarch64-linux-android',
        [string]$AndroidNdk = $env:ANDROID_NDK_HOME
    )
    Assert-TorChatTool -Name cargo
    Assert-TorChatTool -Name rustup
    $ndk = Resolve-TorChatAndroidNdk -AndroidNdk $AndroidNdk
    $abi = switch ($RustTarget) {
        'aarch64-linux-android' { 'arm64-v8a' }
        'armv7-linux-androideabi' { 'armeabi-v7a' }
        'x86_64-linux-android' { 'x86_64' }
        'i686-linux-android' { 'x86' }
        default { throw "Unsupported Android Rust target: $RustTarget" }
    }
    $toolPrefix = switch ($RustTarget) {
        'aarch64-linux-android' { 'aarch64-linux-android' }
        'armv7-linux-androideabi' { 'armv7a-linux-androideabi' }
        'x86_64-linux-android' { 'x86_64-linux-android' }
        'i686-linux-android' { 'i686-linux-android' }
    }
    Initialize-TorChatAndroidToolchain -AndroidNdk $ndk -RustTarget $RustTarget -ToolPrefix $toolPrefix
    # Cargo can sporadically fail with os error 5 while creating a new target
    # triple directory on Windows (typically after an aggressive cleanup or an
    # antivirus/indexer race). Prepare and verify the exact directory before
    # Cargo starts so the build never depends on that racy first mkdir.
    $cargoTarget = Join-Path $Context.RepositoryRoot "target\$RustTarget"
    New-Item -ItemType Directory -Force -Path $cargoTarget -ErrorAction Stop | Out-Null
    $writeProbe = Join-Path $cargoTarget '.torchat-write-probe'
    try {
        [IO.File]::WriteAllText($writeProbe, 'ok')
    } catch {
        throw "Android Rust target directory is not writable: $cargoTarget. $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $writeProbe -Force -ErrorAction SilentlyContinue
    }
    $out = Join-Path $Context.RepositoryRoot "apps\mobile\flutter\build\app\generated\jniLibs\$abi"
    $artifact = Join-Path $out 'libtorchat_client_engine.so'
    $hash = Get-TorChatInputHash -RepositoryRoot $Context.RepositoryRoot -Roots @(
        'Cargo.toml','Cargo.lock','common\client-engine-contract.json','common\torchat-core',
        'packages\torchat-runtime','packages\torchat-client-engine','packages\torchat-client-engine-ffi'
    ) -ExtraValues @("target=$RustTarget","ndk=$env:ANDROID_NDK_HOME")
    if ($Policy -eq 'smart' -and (Test-TorChatBuildFresh -RepositoryRoot $Context.RepositoryRoot -Key "android-core-$RustTarget" -Hash $hash -Artifacts @($artifact))) {
        return [pscustomobject]@{ State = 'Skipped'; Code = 'ANDROID_ENGINE_FRESH'; Message = 'Android engine unchanged'; Artifact = $artifact }
    }
    [void](Invoke-TorChatNative -Context $Context -FilePath 'rustup' -ArgumentList @('target','add',$RustTarget) -LogName 'rustup-android.log')
    [void](Invoke-TorChatNative -Context $Context -FilePath 'cargo' -ArgumentList @('build','--target',$RustTarget,'-p','torchat-client-engine-ffi','--release') -WorkingDirectory $Context.RepositoryRoot -LogName 'cargo-android.log')
    $source = Join-Path $Context.RepositoryRoot "target\$RustTarget\release\libtorchat_client_engine_ffi.so"
    if (-not (Test-Path -LiteralPath $source)) { throw "Android engine source library missing: $source" }
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    try {
        Copy-Item -LiteralPath $source -Destination $artifact -Force -ErrorAction Stop
    } catch [UnauthorizedAccessException] {
        if (-not (Test-Path -LiteralPath $artifact)) { throw }
        if ((Get-TorChatFileSha256 -Path $source) -ne (Get-TorChatFileSha256 -Path $artifact)) { throw }
        Write-TorChatWarning "Android engine library is locked but already current: $artifact"
    }
    if (-not (Test-Path -LiteralPath $artifact)) { throw "Android engine artifact missing: $artifact" }
    Set-TorChatBuildFresh -RepositoryRoot $Context.RepositoryRoot -Key "android-core-$RustTarget" -Hash $hash -Artifacts @($artifact)
    [pscustomobject]@{ State = 'Ready'; Code = 'ANDROID_ENGINE_BUILT'; Message = $artifact; Artifact = $artifact }
}

function Build-TorChatAndroidClient {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [ValidateSet('smart','rebuild')][string]$Policy = 'smart'
    )
    Assert-TorChatTool -Name flutter
    Import-TorChatEnvironmentState -EnvironmentState $EnvironmentState -RequireOnion
    $variant = $Context.Configuration
    $artifact = Join-Path $Context.RepositoryRoot "apps\mobile\flutter\build\app\outputs\flutter-apk\app-$variant.apk"
    $engineArtifacts = @(
        (Join-Path $Context.RepositoryRoot 'apps\mobile\flutter\build\app\generated\jniLibs\arm64-v8a\libtorchat_client_engine.so'),
        (Join-Path $Context.RepositoryRoot 'apps\mobile\flutter\build\app\generated\jniLibs\x86_64\libtorchat_client_engine.so')
    )
    foreach ($engineArtifact in $engineArtifacts) {
        if (-not (Test-Path -LiteralPath $engineArtifact)) {
            throw "Android engine ABI artifact missing before APK build: $engineArtifact"
        }
    }
    $engineFingerprints = @($engineArtifacts | ForEach-Object {
        "engine=$([IO.Path]::GetFileName((Split-Path -Parent $_))):$(Get-TorChatFileSha256 -Path $_)"
    })
    $hash = Get-TorChatInputHash -RepositoryRoot $Context.RepositoryRoot -Roots @(
        'common\client-engine-contract.json','apps\mobile\flutter\pubspec.yaml','apps\mobile\flutter\pubspec.lock',
        'apps\mobile\flutter\lib','apps\mobile\flutter\assets','apps\mobile\flutter\android'
    ) -ExtraValues (@(
        "environment=$($Context.Environment)",
        "onion=$($EnvironmentState.Values['TORCHAT_ONION_URL'])",
        "variant=$variant",
        "torkaPairingCode=$($EnvironmentState.Values['TORCHAT_TORKA_PAIRING_CODE'])"
    ) + $engineFingerprints)
    if ($Policy -eq 'smart' -and (Test-TorChatBuildFresh -RepositoryRoot $Context.RepositoryRoot -Key "flutter-android-$variant" -Hash $hash -Artifacts @($artifact))) {
        return [pscustomobject]@{ State = 'Skipped'; Code = 'ANDROID_APK_FRESH'; Message = 'Android APK unchanged'; Artifact = $artifact }
    }
    $previousConfig = $env:TORCHAT_CONFIG_FILE
    $previousProfile = $env:TORCHAT_DEV_PROFILE
    $previousPair = $env:TORCHAT_DEV_PAIR
    $torkaPairingCode = [string]$EnvironmentState.Values['TORCHAT_TORKA_PAIRING_CODE']
    $env:TORCHAT_CONFIG_FILE = $EnvironmentState.Paths.RuntimeEnvironment
    $env:TORCHAT_DEV_PROFILE = ''
    $env:TORCHAT_DEV_PAIR = 'false'
    try {
        $arguments = @('build','apk',"--$variant")
        if (-not [string]::IsNullOrWhiteSpace($torkaPairingCode)) {
            $arguments += "--dart-define=TORCHAT_TORKA_PAIRING_CODE=$torkaPairingCode"
        }
        [void](Invoke-TorChatNative -Context $Context -FilePath 'flutter' -ArgumentList $arguments -WorkingDirectory (Join-Path $Context.RepositoryRoot 'apps\mobile\flutter') -LogName 'flutter-android.log')
    } finally {
        $env:TORCHAT_CONFIG_FILE = $previousConfig
        $env:TORCHAT_DEV_PROFILE = $previousProfile
        $env:TORCHAT_DEV_PAIR = $previousPair
    }
    if (-not (Test-Path -LiteralPath $artifact)) { throw "Android APK missing: $artifact" }
    Set-TorChatBuildFresh -RepositoryRoot $Context.RepositoryRoot -Key "flutter-android-$variant" -Hash $hash -Artifacts @($artifact)
    [pscustomobject]@{ State = 'Ready'; Code = 'ANDROID_APK_BUILT'; Message = $artifact; Artifact = $artifact }
}

function Build-TorChatWindowsClient {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [ValidateSet('smart','rebuild')][string]$Policy = 'smart'
    )
    if ($env:OS -ne 'Windows_NT') { throw 'Windows client builds require Windows.' }
    Assert-TorChatTool -Name flutter
    Assert-TorChatTool -Name robocopy
    Import-TorChatEnvironmentState -EnvironmentState $EnvironmentState -RequireOnion
    $variant = if ($Context.Configuration -eq 'release') { 'Release' } else { 'Debug' }
    $flutterVariant = if ($Context.Configuration -eq 'release') { '--release' } else { '--debug' }
    $artifact = Join-Path $Context.RepositoryRoot "apps\desktop\flutter\build\windows\x64\runner\$variant\torchat_desktop.exe"
    $hash = Get-TorChatInputHash -RepositoryRoot $Context.RepositoryRoot -Roots @(
        'common\client-engine-contract.json','apps\mobile\flutter\pubspec.yaml','apps\mobile\flutter\pubspec.lock',
        'apps\mobile\flutter\lib','apps\mobile\flutter\assets','apps\desktop\flutter',
        'packages\torchat-flutter-ui'
    ) -ExtraValues @(
        "environment=$($Context.Environment)",
        "onion=$($EnvironmentState.Values['TORCHAT_ONION_URL'])",
        "variant=$variant",
        "torkaPairingCode=$($EnvironmentState.Values['TORCHAT_TORKA_PAIRING_CODE'])"
    )
    if ($Policy -eq 'smart' -and (Test-TorChatBuildFresh -RepositoryRoot $Context.RepositoryRoot -Key "flutter-windows-$variant" -Hash $hash -Artifacts @($artifact))) {
        return [pscustomobject]@{ State = 'Skipped'; Code = 'WINDOWS_CLIENT_FRESH'; Message = 'Windows client unchanged'; Artifact = $artifact }
    }
    Stop-TorChatBuildProcesses -RepositoryRoot $Context.RepositoryRoot
    $stagingParent = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }
    $repoBytes = [Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($Context.RepositoryRoot)).ToLowerInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $repoHash = ([BitConverter]::ToString($sha.ComputeHash($repoBytes)) -replace '-','').Substring(0,12).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    $mobileRoot = Join-Path $Context.RepositoryRoot 'apps\mobile\flutter'
    $desktopRoot = Join-Path $Context.RepositoryRoot 'apps\desktop\flutter'
    $uiPackageRoot = Join-Path $Context.RepositoryRoot 'packages\torchat-flutter-ui'
    # Keep staging isolated per exact Flutter input set. The old fixed path could
    # retain a partially copied project (including merge-conflict markers) when
    # a previous build was interrupted or robocopy was unable to replace a file.
    $inputHash = $hash.Substring(0, 16).ToLowerInvariant()
    $stagingRoot = Join-Path $stagingParent "TorChat\flutter-windows\$repoHash\$inputHash"
    $stagingMobile = Join-Path $stagingRoot 'apps\mobile\flutter'
    $stagingDesktop = Join-Path $stagingRoot 'apps\desktop\flutter'
    $stagingPackages = Join-Path $stagingRoot 'packages'
    $stagingBuild = Join-Path $stagingDesktop 'build\windows'
    $destinationBuild = Join-Path $desktopRoot 'build\windows'
    Remove-TorChatDirectoryRobust -Path $stagingRoot -Description 'Windows Flutter staging directory'
    New-Item -ItemType Directory -Force -Path $stagingMobile,$stagingDesktop,$stagingPackages | Out-Null
    & robocopy $mobileRoot $stagingMobile /E /NFL /NDL /NJH /NJS /NP `
        /XD (Join-Path $mobileRoot 'build') `
            (Join-Path $mobileRoot '.dart_tool') `
            (Join-Path $mobileRoot 'android') `
        /XF '*.apk' '*.aab' '*.log' | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Windows Flutter staging copy failed with robocopy exit $LASTEXITCODE." }
    & robocopy $desktopRoot $stagingDesktop /E /NFL /NDL /NJH /NJS /NP `
        /XD (Join-Path $desktopRoot 'build') `
            (Join-Path $desktopRoot '.dart_tool') `
            (Join-Path $desktopRoot 'windows\flutter\ephemeral') `
        /XF '*.log' | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Desktop Flutter staging copy failed with robocopy exit $LASTEXITCODE." }
    & robocopy $uiPackageRoot (Join-Path $stagingPackages 'torchat-flutter-ui') /E /NFL /NDL /NJH /NJS /NP `
        /XD (Join-Path $uiPackageRoot '.dart_tool') | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Shared Flutter UI staging copy failed with robocopy exit $LASTEXITCODE." }
    $sourceArb = Join-Path $mobileRoot 'lib\locales\resources\app_en.arb'
    $stagedArb = Join-Path $stagingMobile 'lib\locales\resources\app_en.arb'
    if (-not (Test-Path -LiteralPath $stagedArb)) { throw "Windows Flutter staging copy omitted localization catalog: $stagedArb" }
    $sourceArbHash = (Get-FileHash -LiteralPath $sourceArb -Algorithm SHA256).Hash
    $stagedArbHash = (Get-FileHash -LiteralPath $stagedArb -Algorithm SHA256).Hash
    if ($sourceArbHash -ne $stagedArbHash) {
        throw "Windows Flutter staging copy produced a different app_en.arb (source $sourceArb, staged $stagedArb)."
    }
    $previousConfig = $env:TORCHAT_CONFIG_FILE
    $torkaPairingCode = [string]$EnvironmentState.Values['TORCHAT_TORKA_PAIRING_CODE']
    $env:TORCHAT_CONFIG_FILE = $EnvironmentState.Paths.RuntimeEnvironment
    try {
        # Resolve plugins before the build so the staging copy can repair the
        # Windows include layout of flutter_secure_storage_windows. Version
        # 4.1.0 declares its own include directory as INTERFACE while its
        # source uses a path rooted at include/, which breaks MSVC builds.
        [void](Invoke-TorChatNative -Context $Context -FilePath 'flutter' -ArgumentList @('pub','get') -WorkingDirectory $stagingDesktop -LogName 'flutter-windows-pub-get.log')
        $secureStorageRoot = Join-Path $stagingDesktop 'windows\flutter\ephemeral\.plugin_symlinks\flutter_secure_storage_windows'
        $secureStorageCmake = Join-Path $secureStorageRoot 'windows\CMakeLists.txt'
        $secureStorageCpp = Join-Path $secureStorageRoot 'windows\flutter_secure_storage_windows_plugin.cpp'
        if (Test-Path -LiteralPath $secureStorageRoot) {
            $secureStorageItem = Get-Item -LiteralPath $secureStorageRoot -Force
            if (($secureStorageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $secureStorageSource = [string]$secureStorageItem.Target
                # Flutter's Windows toolchain follows this link while copying
                # plugin sources. Patch the resolved package first so the
                # generated CMake project receives the corrected source.
                $resolvedCmake = Join-Path $secureStorageSource 'windows\CMakeLists.txt'
                $resolvedCpp = Join-Path $secureStorageSource 'windows\flutter_secure_storage_windows_plugin.cpp'
                if ((Test-Path -LiteralPath $resolvedCmake) -and (Test-Path -LiteralPath $resolvedCpp)) {
                    $resolvedCmakeText = [IO.File]::ReadAllText($resolvedCmake)
                    $resolvedCppText = [IO.File]::ReadAllText($resolvedCpp)
                    [IO.File]::WriteAllText($resolvedCmake, $resolvedCmakeText.Replace('target_include_directories(${PLUGIN_NAME} INTERFACE', 'target_include_directories(${PLUGIN_NAME} PUBLIC'), [Text.UTF8Encoding]::new($false))
                    [IO.File]::WriteAllText($resolvedCpp, $resolvedCppText.Replace('#include "include/flutter_secure_storage_windows/flutter_secure_storage_windows_plugin.h"', '#include "flutter_secure_storage_windows/flutter_secure_storage_windows_plugin.h"'), [Text.UTF8Encoding]::new($false))
                }
                # Remove only this generated staging link. PowerShell can
                # follow directory links on exFAT, so use rmdir for the link
                # itself and verify that the target was not touched.
                cmd.exe /c "rmdir `"$secureStorageRoot`"" | Out-Null
                if (Test-Path -LiteralPath $secureStorageRoot) {
                    throw "Could not replace staged flutter_secure_storage_windows link: $secureStorageRoot"
                }
                New-Item -ItemType Directory -Force -Path $secureStorageRoot | Out-Null
                & robocopy $secureStorageSource $secureStorageRoot /E /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -gt 7) { throw "Failed to materialize staged flutter_secure_storage_windows plugin (robocopy exit $LASTEXITCODE)." }
                $secureStorageCmake = Join-Path $secureStorageRoot 'windows\CMakeLists.txt'
                $secureStorageCpp = Join-Path $secureStorageRoot 'windows\flutter_secure_storage_windows_plugin.cpp'
            }
        }
        if ((Test-Path -LiteralPath $secureStorageCmake) -and (Test-Path -LiteralPath $secureStorageCpp)) {
            $cmakeText = [IO.File]::ReadAllText($secureStorageCmake)
            $cppText = [IO.File]::ReadAllText($secureStorageCpp)
            $newCmakeText = $cmakeText.Replace('target_include_directories(${PLUGIN_NAME} INTERFACE', 'target_include_directories(${PLUGIN_NAME} PUBLIC')
            $newCppText = $cppText.Replace('#include "include/flutter_secure_storage_windows/flutter_secure_storage_windows_plugin.h"', '#include "flutter_secure_storage_windows/flutter_secure_storage_windows_plugin.h"')
            if ($newCmakeText -ne $cmakeText) {
                [IO.File]::WriteAllText($secureStorageCmake, $newCmakeText, [Text.UTF8Encoding]::new($false))
            }
            if ($newCppText -ne $cppText) {
                [IO.File]::WriteAllText($secureStorageCpp, $newCppText, [Text.UTF8Encoding]::new($false))
            }
            if (($newCmakeText -ne $cmakeText) -or ($newCppText -ne $cppText)) {
                Write-TorChatInfo 'Applied MSVC include-path workaround to staged flutter_secure_storage_windows plugin.'
            }
        }
        # Force CMake to re-read the corrected plugin CMakeLists instead of
        # reusing a project generated from the broken package metadata.
        if (Test-Path -LiteralPath $stagingBuild) {
            Remove-TorChatDirectoryRobust -Path $stagingBuild -Description 'stale Windows Flutter CMake output'
        }
        $arguments = @('build','windows',$flutterVariant,'--no-pub')
        if (-not [string]::IsNullOrWhiteSpace($torkaPairingCode)) {
            $arguments += "--dart-define=TORCHAT_TORKA_PAIRING_CODE=$torkaPairingCode"
        }
        [void](Invoke-TorChatNative -Context $Context -FilePath 'flutter' -ArgumentList $arguments -WorkingDirectory $stagingDesktop -LogName 'flutter-windows.log')
    } finally {
        $env:TORCHAT_CONFIG_FILE = $previousConfig
    }
    # Do not recursively delete the fixed output directory. A running Flutter
    # process can keep a DLL open and make Remove-Item fail for the whole tree.
    # The build was produced in an isolated staging directory; update the
    # destination in place after the process stop above.
    New-Item -ItemType Directory -Force -Path $destinationBuild | Out-Null
    $copyExit = 16
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        & robocopy $stagingBuild $destinationBuild /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        $copyExit = $LASTEXITCODE
        if ($copyExit -le 7) { break }
        Write-TorChatWarning "Windows Flutter output synchronization attempt $attempt failed (robocopy exit $copyExit)."
        Stop-TorChatBuildProcesses -RepositoryRoot $Context.RepositoryRoot
        Start-Sleep -Milliseconds (500 * $attempt)
    }
    if ($copyExit -gt 7) { throw "Windows Flutter output copy failed after 5 attempts (robocopy exit $copyExit)." }
    if (-not (Test-Path -LiteralPath $artifact)) { throw "Windows client artifact missing: $artifact" }
    Set-TorChatBuildFresh -RepositoryRoot $Context.RepositoryRoot -Key "flutter-windows-$variant" -Hash $hash -Artifacts @($artifact)
    [pscustomobject]@{ State = 'Ready'; Code = 'WINDOWS_CLIENT_BUILT'; Message = $artifact; Artifact = $artifact }
}

function Build-TorChatServerImage {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [switch]$NoCache
    )
    Assert-TorChatTool -Name docker
    $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
    $args = @($compose.Arguments + @('build','relay'))
    if ($NoCache) { $args += '--no-cache' }
    [void](Invoke-TorChatNative -Context $Context -FilePath 'docker' -ArgumentList $args -WorkingDirectory $Context.RepositoryRoot -LogName 'docker-build-relay.log')
    [pscustomobject]@{ State = 'Ready'; Code = 'SERVER_IMAGE_BUILT'; Message = 'Relay server image built' }
}

function Build-TorChatTorkaImage {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [switch]$NoCache
    )
    Assert-TorChatTool -Name docker
    $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
    $args = @($compose.Arguments + @('build','torka'))
    if ($NoCache) { $args += '--no-cache' }
    [void](Invoke-TorChatNative -Context $Context -FilePath 'docker' -ArgumentList $args -WorkingDirectory $Context.RepositoryRoot -LogName 'docker-build-torka.log')
    [pscustomobject]@{ State = 'Ready'; Code = 'TORKA_IMAGE_BUILT'; Message = 'Torka P2P test peer image built' }
}

Export-ModuleMember -Function @(
    'Get-TorChatInputHash',
    'Test-TorChatBuildFresh',
    'Set-TorChatBuildFresh',
    'Remove-TorChatDirectoryRobust',
    'Stop-TorChatBuildProcesses',
    'Build-TorChatDesktopEngine',
    'Build-TorChatAndroidEngine',
    'Build-TorChatAndroidClient',
    'Build-TorChatWindowsClient',
    'Build-TorChatServerImage',
    'Build-TorChatTorkaImage'
)
