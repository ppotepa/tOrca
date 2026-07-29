[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)


$removedContractFiles = @(
    'common\client-runtime-contract.json',
    'common\client-runtime-fixtures.json',
    'common\client-runtime-scenarios.json',
    'common\torchat-client-runtime\src\c_api.rs'
)
foreach ($relativePath in $removedContractFiles) {
    $path = Join-Path $repoRoot $relativePath
    if (Test-Path -LiteralPath $path) {
        throw "Removed legacy artifact still exists: $relativePath"
    }
}

$checks = @(
    @{ Needle = 'EncryptedMessageStore'; Roots = @('mobile\android\app\src\main') },
    @{ Needle = 'RuntimeStateSnapshot'; Roots = @('mobile\android\app\src\main', 'desktop\src', 'mobile\lib') },
    @{ Needle = 'AndroidRelayTransport'; Roots = @('mobile\android\app\src\main') },
    @{ Needle = 'NativeClientRuntime'; Roots = @('mobile\android') },
    @{ Needle = 'torchat_client_runtime'; Roots = @('mobile\android') },
    @{ Needle = 'libtorchat_core'; Roots = @('mobile\android', 'scripts') },
    @{ Needle = 'NativeCore'; Roots = @('mobile\android\app\src\main') },
    @{ Needle = 'DesktopRuntimeStorage'; Roots = @('desktop\src') },
    @{ Needle = 'DesktopState'; Roots = @('desktop\src') },
    @{ Needle = 'LocalStore'; Roots = @('desktop\src') },
    @{ Needle = 'RuntimeRequest'; Roots = @('desktop\src', 'mobile\lib') },
    @{ Needle = 'RuntimeResponse'; Roots = @('desktop\src', 'mobile\lib') },
    @{ Needle = 'prepareAcceptPairing'; Roots = @('mobile\lib', 'mobile\android\app\src\main') },
    @{ Needle = 'commitAcceptPairing'; Roots = @('mobile\lib', 'mobile\android\app\src\main') },
    @{ Needle = 'prepareRejectPairing'; Roots = @('mobile\lib', 'mobile\android\app\src\main') },
    @{ Needle = 'commitRejectPairing'; Roots = @('mobile\lib', 'mobile\android\app\src\main') },
    @{ Needle = 'prepareCancelPairing'; Roots = @('mobile\lib', 'mobile\android\app\src\main') },
    @{ Needle = 'confirmPairingCancelled'; Roots = @('mobile\lib', 'mobile\android\app\src\main') },
    @{ Needle = 'preparePendingSendEffects'; Roots = @('mobile\lib', 'mobile\android\app\src\main', 'desktop\src') },
    @{ Needle = 'preparePendingReceiptEffects'; Roots = @('mobile\lib', 'mobile\android\app\src\main', 'desktop\src') },
    @{ Needle = 'importStateJson'; Roots = @('mobile\lib', 'mobile\android\app\src\main', 'desktop\src') },
    @{ Needle = 'exportStateJson'; Roots = @('mobile\lib', 'mobile\android\app\src\main', 'desktop\src') },
    @{ Needle = 'desktop/sql'; Roots = @('desktop') },
    @{ Needle = 'assets/sql'; Roots = @('mobile\android') },
    @{ Needle = 'OkHttpClient'; Roots = @('mobile\android\app\src\main') },
    @{ Needle = 'SQLiteDatabase'; Roots = @('mobile\android\app\src\main') },
    @{ Needle = "'method': method"; Roots = @('mobile\lib') },
    @{ Needle = "'params': params"; Roots = @('mobile\lib') },
    @{ Needle = 'map_runtime_request'; Roots = @('desktop\src') },
    @{ Needle = 'response_to_runtime_response'; Roots = @('desktop\src') },
    @{ Needle = 'client-runtime-contract.json'; Roots = @('common', 'mobile', 'desktop', 'scripts', 'tools') }
)

foreach ($check in $checks) {
    $paths = @($check.Roots | ForEach-Object { Join-Path $repoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if ($paths.Count -eq 0) {
        continue
    }
    $hits = @(rg -n -F --glob '!concat.txt' --glob '!**/jniLibs/**' $check.Needle $paths 2>$null |
        Where-Object { -not $_.StartsWith($PSCommandPath) })
    if ($hits) {
        throw "Legacy production path still present: $($check.Needle)`n$hits"
    }
}

Write-Host '[torchat] legacy cleanup check passed'
