[CmdletBinding()]
param(
    [string]$LibraryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $LibraryPath) {
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'mobile\build') -Filter libtorchat_client_engine.so -File -Recurse -ErrorAction SilentlyContinue)
    if (-not $candidates) { throw 'Android engine library was not found. Build the Android engine first.' }
    $LibraryPath = ($candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
}
if (-not (Test-Path -LiteralPath $LibraryPath)) { throw "Android engine library not found: $LibraryPath" }

$nm = Get-Command llvm-nm -ErrorAction SilentlyContinue
if (-not $nm -and $env:ANDROID_NDK_HOME) {
    $nm = Get-ChildItem -LiteralPath (Join-Path $env:ANDROID_NDK_HOME 'toolchains\llvm\prebuilt') -Filter llvm-nm.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $nm) { throw 'llvm-nm is required to validate Android engine symbols.' }
$nmPath = if ($nm -is [System.IO.FileInfo]) { $nm.FullName } else { $nm.Source }

$symbols = @(& $nmPath -D --defined-only $LibraryPath | ForEach-Object {
    if ($_ -match '\s([A-Za-z_][A-Za-z0-9_]*)$') { $Matches[1] }
})
$required = @(
    'torchat_client_engine_new', 'torchat_client_engine_start',
    'torchat_client_engine_submit_json', 'torchat_client_engine_poll_json',
    'torchat_client_engine_platform_fact_json', 'torchat_client_engine_shutdown',
    'torchat_client_engine_free', 'torchat_client_engine_last_error',
    'torchat_client_engine_free_string'
)
$forbidden = @(
    'torchat_identity_', 'torchat_conversation_',
    'torchat_validate_contact_invite', 'torchat_contact_invite_',
    'torchat_last_error', 'torchat_free_bytes'
)
$missing = @($required | Where-Object { $_ -notin $symbols })
if ($missing) { throw "Android engine ABI is missing: $($missing -join ', ')" }
$foundForbidden = @($symbols | Where-Object {
    $symbol = $_
    @($forbidden | Where-Object { $symbol.StartsWith($_) }).Count -gt 0
})
if ($foundForbidden) { throw "Obsolete Android engine ABI symbols found: $($foundForbidden -join ', ')" }
Write-Host "[torchat] Android engine symbols validated: $LibraryPath"
