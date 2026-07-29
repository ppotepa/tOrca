param(
    [string]$AndroidNdk = $env:ANDROID_NDK_HOME,
    [string]$RustTarget = "aarch64-linux-android"
)

$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$jni = Join-Path $repo "mobile\android\app\src\main\jniLibs"

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
if (Test-Path -LiteralPath $out) {
    Remove-Item -LiteralPath $out -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $out | Out-Null
cargo build --target $RustTarget -p torchat-client-engine-ffi --release
Copy-Item (Join-Path $repo "target\$RustTarget\release\libtorchat_client_engine_ffi.so") (Join-Path $out "libtorchat_client_engine.so") -Force -ErrorAction SilentlyContinue
if (-not (Test-Path (Join-Path $out "libtorchat_client_engine.so"))) {
    throw "Rust Android engine library was not produced for $abi."
}
