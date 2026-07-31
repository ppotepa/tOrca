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
            $fileHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
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
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq 4) { break }
            Write-TorChatWarning "$Description removal attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
    if ($env:OS -eq 'Windows_NT' -and (Get-Command robocopy -ErrorAction SilentlyContinue)) {
        $empty = Join-Path ([IO.Path]::GetTempPath()) "torchat-empty-$PID-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        try {
            & robocopy $empty $resolved /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -gt 7) { throw "$Description cleanup mirror failed with robocopy exit $LASTEXITCODE." }
        } finally {
            Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
}

function Stop-TorChatBuildProcesses {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    if ($env:OS -ne 'Windows_NT') { return }
    $repoPath = [IO.Path]::GetFullPath($RepositoryRoot)
    foreach ($name in @('torchat_mobile.exe','torchat-desktop.exe')) {
        $running = @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($repoPath, [StringComparison]::OrdinalIgnoreCase)
        })
        foreach ($process in $running) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 500
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
        'common\torchat-client-runtime','common\torchat-client-engine','desktop'
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
    $out = Join-Path $Context.RepositoryRoot "mobile\build\app\generated\jniLibs\$abi"
    $artifact = Join-Path $out 'libtorchat_client_engine.so'
    $hash = Get-TorChatInputHash -RepositoryRoot $Context.RepositoryRoot -Roots @(
        'Cargo.toml','Cargo.lock','common\client-engine-contract.json','common\torchat-core',
        'common\torchat-client-runtime','common\torchat-client-engine','common\torchat-client-engine-ffi'
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
    $artifact = Join-Path $Context.RepositoryRoot "mobile\build\app\outputs\flutter-apk\app-$variant.apk"
    $hash = Get-TorChatInputHash -RepositoryRoot $Context.RepositoryRoot -Roots @(
        'common\client-engine-contract.json','mobile\pubspec.yaml','mobile\pubspec.lock',
        'mobile\lib','mobile\assets','mobile\android'
    ) -ExtraValues @(
        "environment=$($Context.Environment)",
        "onion=$($EnvironmentState.Values['TORCHAT_ONION_URL'])",
        "variant=$variant",
        "torkaPairingCode=$($EnvironmentState.Values['TORCHAT_TORKA_PAIRING_CODE'])"
    )
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
        [void](Invoke-TorChatNative -Context $Context -FilePath 'flutter' -ArgumentList $arguments -WorkingDirectory (Join-Path $Context.RepositoryRoot 'mobile') -LogName 'flutter-android.log')
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
    $artifact = Join-Path $Context.RepositoryRoot "mobile\build\windows\x64\runner\$variant\torchat_mobile.exe"
    $hash = Get-TorChatInputHash -RepositoryRoot $Context.RepositoryRoot -Roots @(
        'common\client-engine-contract.json','mobile\pubspec.yaml','mobile\pubspec.lock',
        'mobile\lib','mobile\assets','mobile\windows'
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
    $mobileRoot = Join-Path $Context.RepositoryRoot 'mobile'
    $stagingMobile = Join-Path $stagingParent "TorChat\flutter-windows\$repoHash\mobile"
    $stagingBuild = Join-Path $stagingMobile 'build\windows'
    $destinationBuild = Join-Path $mobileRoot 'build\windows'
    Remove-TorChatDirectoryRobust -Path $stagingMobile -Description 'Windows Flutter staging directory'
    New-Item -ItemType Directory -Force -Path $stagingMobile | Out-Null
    & robocopy $mobileRoot $stagingMobile /E /NFL /NDL /NJH /NJS /NP `
        /XD (Join-Path $mobileRoot 'build') `
            (Join-Path $mobileRoot '.dart_tool') `
            (Join-Path $mobileRoot 'windows\flutter\ephemeral') `
            (Join-Path $mobileRoot 'android') `
        /XF '*.apk' '*.aab' '*.log' | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Windows Flutter staging copy failed with robocopy exit $LASTEXITCODE." }
    $previousConfig = $env:TORCHAT_CONFIG_FILE
    $torkaPairingCode = [string]$EnvironmentState.Values['TORCHAT_TORKA_PAIRING_CODE']
    $env:TORCHAT_CONFIG_FILE = $EnvironmentState.Paths.RuntimeEnvironment
    try {
        $arguments = @('build','windows',$flutterVariant)
        if (-not [string]::IsNullOrWhiteSpace($torkaPairingCode)) {
            $arguments += "--dart-define=TORCHAT_TORKA_PAIRING_CODE=$torkaPairingCode"
        }
        [void](Invoke-TorChatNative -Context $Context -FilePath 'flutter' -ArgumentList $arguments -WorkingDirectory $stagingMobile -LogName 'flutter-windows.log')
    } finally {
        $env:TORCHAT_CONFIG_FILE = $previousConfig
    }
    Remove-TorChatDirectoryRobust -Path $destinationBuild -Description 'Windows Flutter output directory'
    New-Item -ItemType Directory -Force -Path $destinationBuild | Out-Null
    & robocopy $stagingBuild $destinationBuild /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Windows Flutter output copy failed with robocopy exit $LASTEXITCODE." }
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
    $args = @($compose.Arguments + @('build','server'))
    if ($NoCache) { $args += '--no-cache' }
    [void](Invoke-TorChatNative -Context $Context -FilePath 'docker' -ArgumentList $args -WorkingDirectory $Context.RepositoryRoot -LogName 'docker-build-server.log')
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
