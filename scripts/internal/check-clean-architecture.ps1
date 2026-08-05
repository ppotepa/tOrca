[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)


$removedContractFiles = @(
    'common\client-runtime-contract.json',
    'common\client-runtime-fixtures.json',
    'common\client-runtime-scenarios.json',
    'packages\torchat-runtime\src\c_api.rs'
)
$removedLegacyFiles = @(
    'common\torchat-core\src\c_api.rs',
    'common\torchat-core\include\torchat_core.h',
    'apps\mobile\flutter\android\app\src\main\kotlin\org\torchat\core\NativeCore.kt',
    'apps\mobile\flutter\android\app\src\main\kotlin\org\torchat\mobile\RuntimePayloads.kt',
    'apps\mobile\flutter\android\app\src\main\kotlin\org\torchat\mobile\RuntimeTransportFact.kt'
)
foreach ($relativePath in $removedContractFiles) {
    $path = Join-Path $repoRoot $relativePath
    if (Test-Path -LiteralPath $path) {
        throw "Removed artifact was restored: $relativePath"
    }
}
foreach ($relativePath in $removedLegacyFiles) {
    $path = Join-Path $repoRoot $relativePath
    if (Test-Path -LiteralPath $path) {
        throw "Removed architecture artifact was restored: $relativePath"
    }
}

$checks = @(
    @{ Needle = 'EncryptedMessageStore'; Roots = @('apps\mobile\flutter\android\app\src\main') },
    @{ Needle = 'RuntimeStateSnapshot'; Roots = @('apps\mobile\flutter\android\app\src\main', 'apps\desktop\native\src', 'apps\mobile\flutter\lib') },
    @{ Needle = 'AndroidRelayTransport'; Roots = @('apps\mobile\flutter\android\app\src\main') },
    @{ Needle = 'NativeClientRuntime'; Roots = @('apps\mobile\flutter\android') },
    @{ Needle = 'torchat_runtime'; Roots = @('apps\mobile\flutter\android') },
    @{ Needle = 'libtorchat_core'; Roots = @('apps\mobile\flutter\android', 'scripts') },
    @{ Needle = 'NativeCore'; Roots = @('apps\mobile\flutter\android\app\src\main') },
    @{ Needle = 'DesktopRuntimeStorage'; Roots = @('apps\desktop\native\src') },
    @{ Needle = 'DesktopState'; Roots = @('apps\desktop\native\src') },
    @{ Needle = 'LocalStore'; Roots = @('apps\desktop\native\src') },
    @{ Needle = 'RuntimeRequest'; Roots = @('apps\desktop\native\src', 'apps\mobile\flutter\lib') },
    @{ Needle = 'RuntimeResponse'; Roots = @('apps\desktop\native\src', 'apps\mobile\flutter\lib') },
    @{ Needle = 'prepareAcceptPairing'; Roots = @('apps\mobile\flutter\lib', 'apps\mobile\flutter\android\app\src\main') },
    @{ Needle = 'commitAcceptPairing'; Roots = @('apps\mobile\flutter\lib', 'apps\mobile\flutter\android\app\src\main') },
    @{ Needle = 'prepareRejectPairing'; Roots = @('apps\mobile\flutter\lib', 'apps\mobile\flutter\android\app\src\main') },
    @{ Needle = 'commitRejectPairing'; Roots = @('apps\mobile\flutter\lib', 'apps\mobile\flutter\android\app\src\main') },
    @{ Needle = 'prepareCancelPairing'; Roots = @('apps\mobile\flutter\lib', 'apps\mobile\flutter\android\app\src\main') },
    @{ Needle = 'confirmPairingCancelled'; Roots = @('apps\mobile\flutter\lib', 'apps\mobile\flutter\android\app\src\main') },
    @{ Needle = 'preparePendingSendEffects'; Roots = @('apps\mobile\flutter\lib', 'apps\mobile\flutter\android\app\src\main', 'apps\desktop\native\src') },
    @{ Needle = 'preparePendingReceiptEffects'; Roots = @('apps\mobile\flutter\lib', 'apps\mobile\flutter\android\app\src\main', 'apps\desktop\native\src') },
    @{ Needle = 'importStateJson'; Roots = @('apps\mobile\flutter\lib', 'apps\mobile\flutter\android\app\src\main', 'apps\desktop\native\src') },
    @{ Needle = 'exportStateJson'; Roots = @('apps\mobile\flutter\lib', 'apps\mobile\flutter\android\app\src\main', 'apps\desktop\native\src') },
    @{ Needle = 'desktop/sql'; Roots = @('apps\desktop\native') },
    @{ Needle = 'assets/sql'; Roots = @('apps\mobile\flutter\android') },
    @{ Needle = 'OkHttpClient'; Roots = @('apps\mobile\flutter\android\app\src\main') },
    @{ Needle = 'SQLiteDatabase'; Roots = @('apps\mobile\flutter\android\app\src\main') },
    @{ Needle = "'method': method"; Roots = @('apps\mobile\flutter\lib') },
    @{ Needle = "'params': params"; Roots = @('apps\mobile\flutter\lib') },
    @{ Needle = 'map_runtime_request'; Roots = @('apps\desktop\native\src') },
    @{ Needle = 'response_to_runtime_response'; Roots = @('apps\desktop\native\src') },
    @{ Needle = 'client-runtime-contract.json'; Roots = @('common', 'apps\mobile\flutter', 'apps', 'scripts', 'tools') }
    @{ Needle = 'torchat_identity_'; Roots = @('common', 'apps\mobile\flutter', 'apps') }
    @{ Needle = 'torchat_conversation_'; Roots = @('common', 'apps\mobile\flutter', 'apps') }
    @{ Needle = 'snapshot?.contacts ?? state.contacts'; Roots = @('apps\mobile\flutter\lib') }
    @{ Needle = 'snapshot?.conversations ?? state.conversations'; Roots = @('apps\mobile\flutter\lib') }
)

foreach ($check in $checks) {
    $paths = @($check.Roots | ForEach-Object { Join-Path $repoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if ($paths.Count -eq 0) {
        continue
    }
    $hits = @(rg -n -F --glob '!concat.txt' --glob '!**/jniLibs/**' $check.Needle $paths 2>$null |
        Where-Object { -not $_.StartsWith($PSCommandPath) })
    if ($hits) {
        throw "Removed production path is present: $($check.Needle)`n$hits"
    }
}

Write-Host '[torchat] clean architecture check passed'
