param(
    [string]$AndroidNdk = $env:ANDROID_NDK_HOME,
    [string]$RustTarget = "aarch64-linux-android",
    [switch]$SkipIfFresh
)

$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$jni = Join-Path $repo "mobile\build\app\generated\jniLibs"
. (Join-Path $PSScriptRoot "build-cache.ps1")

function Test-TorChatFileExists([string]$Path) {
    try {
        Test-Path -LiteralPath $Path
    } catch [System.UnauthorizedAccessException] {
        [IO.File]::Exists($Path)
    }
}

function Get-TorChatSha256([string]$Path) {
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$msysPerl = "C:\msys64\usr\bin"
$gitPerl = "C:\Program Files\Git\usr\bin"
$strawberryPerl = "C:\Strawberry\perl\bin"
foreach ($candidate in @($msysPerl, $gitPerl, $strawberryPerl)) {
    if (Test-Path -LiteralPath (Join-Path $candidate "perl.exe")) {
        $env:PATH = "$candidate;$env:PATH"
        break
    }
}

if ([string]::IsNullOrWhiteSpace($AndroidNdk)) {
    $sdk = $env:ANDROID_SDK_ROOT
    if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = $env:ANDROID_HOME }
    if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = Join-Path $env:LOCALAPPDATA "Android\Sdk" }
    $AndroidNdk = Get-ChildItem (Join-Path $sdk "ndk") -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if ([string]::IsNullOrWhiteSpace($AndroidNdk) -or -not (Test-Path -LiteralPath $AndroidNdk)) {
    throw "Android NDK not found. Install it through Android Studio or set ANDROID_NDK_HOME."
}
$env:ANDROID_NDK_HOME = $AndroidNdk -replace '\\', '/'

rustup target add $RustTarget

# The Flutter UI and Android background service use the checked-in C ABI
# header and the shared Rust engine library.

$abi = switch ($RustTarget) {
    "aarch64-linux-android" { "arm64-v8a" }
    "armv7-linux-androideabi" { "armeabi-v7a" }
    "x86_64-linux-android" { "x86_64" }
    "i686-linux-android" { "x86" }
    default { throw "Unsupported Android Rust target: $RustTarget" }
}
$toolPrefix = switch ($RustTarget) {
    "aarch64-linux-android" { "aarch64-linux-android" }
    "armv7-linux-androideabi" { "armv7a-linux-androideabi" }
    "x86_64-linux-android" { "x86_64-linux-android" }
    "i686-linux-android" { "i686-linux-android" }
    default { throw "Unsupported Android Rust target: $RustTarget" }
}
$targetEnv = $RustTarget.ToUpperInvariant().Replace("-", "_")
$llvmBin = "$env:ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/bin"
$clang = "$llvmBin/$toolPrefix" + "21-clang.cmd"
$clangExe = "$llvmBin/clang.exe"
$ar = "$llvmBin/llvm-ar.exe"
$ranlib = "$llvmBin/llvm-ranlib.exe"
if (-not (Test-Path -LiteralPath $clang) -or -not (Test-Path -LiteralPath $clangExe)) {
    throw "Android NDK clang not found for $RustTarget in $llvmBin."
}
[Environment]::SetEnvironmentVariable("CARGO_TARGET_$($targetEnv)_LINKER", $clang, "Process")
[Environment]::SetEnvironmentVariable("CC_$RustTarget", $clangExe, "Process")
[Environment]::SetEnvironmentVariable("CC_$($RustTarget.Replace('-', '_'))", $clangExe, "Process")
[Environment]::SetEnvironmentVariable("AR_$RustTarget", $ar, "Process")
[Environment]::SetEnvironmentVariable("AR_$($RustTarget.Replace('-', '_'))", $ar, "Process")
[Environment]::SetEnvironmentVariable("RANLIB_$RustTarget", $ranlib, "Process")
[Environment]::SetEnvironmentVariable("RANLIB_$($RustTarget.Replace('-', '_'))", $ranlib, "Process")
[Environment]::SetEnvironmentVariable("CFLAGS_$RustTarget", "--target=$RustTarget" + "21", "Process")
[Environment]::SetEnvironmentVariable("CFLAGS_$($RustTarget.Replace('-', '_'))", "--target=$RustTarget" + "21", "Process")

$out = Join-Path $jni $abi
$libraryPath = Join-Path $out "libtorchat_client_engine.so"
if ($SkipIfFresh) {
    $inputHash = Get-TorChatInputHash -RepoRoot $repo -Roots @(
        'Cargo.toml',
        'Cargo.lock',
        'common\client-engine-contract.json',
        'common\torchat-core',
        'common\torchat-client-runtime',
        'common\torchat-client-engine',
        'common\torchat-client-engine-ffi'
    ) -ExtraValues @(
        "rust_target=$RustTarget",
        "android_ndk=$env:ANDROID_NDK_HOME"
    )
    if (Test-TorChatBuildFresh -RepoRoot $repo -Key "android-core-$RustTarget" -Hash $inputHash -Artifacts @($libraryPath)) {
        Write-Host "[torchat] Android Rust engine unchanged; using $libraryPath"
        return
    }
}
New-Item -ItemType Directory -Force -Path $out | Out-Null
cargo build --target $RustTarget -p torchat-client-engine-ffi --release
$sourceLibraryPath = Join-Path $repo "target\$RustTarget\release\libtorchat_client_engine_ffi.so"
if (-not (Test-Path -LiteralPath $sourceLibraryPath)) {
    throw "Rust Android engine build did not produce source library: $sourceLibraryPath"
}
$copyRequired = $true
if (Test-TorChatFileExists $libraryPath) {
    try {
        $copyRequired = (Get-TorChatSha256 $sourceLibraryPath) -ne
            (Get-TorChatSha256 $libraryPath)
    } catch {
        throw "Android engine library exists but cannot be read: $libraryPath. Stop Android Studio/Gradle/ADB users of the project or remove the locked file, then rerun."
    }
}
if ($copyRequired) {
    try {
        Copy-Item $sourceLibraryPath $libraryPath -Force -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        if (-not (Test-TorChatFileExists $libraryPath)) { throw }
        $sourceHash = Get-TorChatSha256 $sourceLibraryPath
        $targetHash = Get-TorChatSha256 $libraryPath
        if ($sourceHash -ne $targetHash) { throw }
        Write-Host "[torchat] Android engine library is already current but locked: $libraryPath"
    }
}
if (-not (Test-TorChatFileExists $libraryPath)) { throw "Rust Android engine library was not produced for $abi." }
if ($SkipIfFresh) {
    Set-TorChatBuildFresh -RepoRoot $repo -Key "android-core-$RustTarget" -Hash $inputHash -Artifacts @($libraryPath)
}
