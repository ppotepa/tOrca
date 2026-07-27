param(
    [string]$AndroidNdk = $env:ANDROID_NDK_HOME,
    [string]$RustTarget = "aarch64-linux-android"
)

$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$jni = Join-Path $repo "mobile\android\app\src\main\jniLibs"

if (-not (Get-Command cargo-ndk -ErrorAction SilentlyContinue)) {
    cargo install cargo-ndk --locked
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

rustup target add $RustTarget

# The Flutter UI and Android background service both use the checked-in C ABI
# header and the same native Rust library.

$abi = switch ($RustTarget) {
    "aarch64-linux-android" { "arm64-v8a" }
    "armv7-linux-androideabi" { "armeabi-v7a" }
    "x86_64-linux-android" { "x86_64" }
    "i686-linux-android" { "x86" }
    default { throw "Unsupported Android Rust target: $RustTarget" }
}

$out = Join-Path $jni $abi
New-Item -ItemType Directory -Force -Path $out | Out-Null
cargo ndk -t $RustTarget -o $jni build -p torchat-core --release
Copy-Item (Join-Path $repo "target\$RustTarget\release\torchat_core.dll") (Join-Path $out "libtorchat_core.so") -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $repo "target\$RustTarget\release\libtorchat_core.so") (Join-Path $out "libtorchat_core.so") -Force -ErrorAction SilentlyContinue
if (-not (Test-Path (Join-Path $out "libtorchat_core.so"))) {
    throw "Rust Android library was not produced for $abi."
}
