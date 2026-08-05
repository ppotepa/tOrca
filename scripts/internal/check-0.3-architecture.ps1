param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-File([string]$Path) {
    $full = Join-Path $RepositoryRoot $Path
    if (-not (Test-Path -LiteralPath $full)) {
        throw "required architecture file is missing: $Path"
    }
    return $full
}

$runtimeError = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-runtime/src/error.rs')
foreach ($required in @('RuntimeProblem', 'RuntimeErrorCode', 'retryable', 'diagnostic_context')) {
    if (-not $runtimeError.Contains($required)) {
        throw "stable runtime error contract is missing '$required'"
    }
}

$storage = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-runtime/src/storage.rs')
foreach ($forbidden in @(
    'fn pending_receipts(&self) -> RuntimeResult<Vec<ReceiptSendEffect>> {' + [Environment]::NewLine + '        Ok(Vec::new())',
    'fn expedite_retry_after_ready(&mut self) -> RuntimeResult<()> {' + [Environment]::NewLine + '        Ok(())',
    'fn revoke_peer_endpoint_capability' + [Environment]::NewLine + '        Ok(())'
)) {
    if ($storage.Contains($forbidden)) {
        throw 'RuntimeStorage contains a silent required-operation no-op'
    }
}

$problemClassifier = Get-Content -Raw -LiteralPath (Require-File 'apps/mobile/flutter/lib/core/problems/runtime_problem_classifier.dart')
foreach ($forbidden in @('.toLowerCase()', '.contains(', 'String message')) {
    if ($problemClassifier.Contains($forbidden)) {
        throw "Flutter runtime problem classification still depends on message text: $forbidden"
    }
}

$contract = Get-Content -Raw -LiteralPath (Require-File 'common/client-engine-contract.json') | ConvertFrom-Json -Depth 100
if ($null -eq $contract.commands -or $contract.commands.Count -eq 0) {
    throw 'canonical commands array is missing from client engine contract'
}
foreach ($command in $contract.commands) {
    if ($command.durable -and -not $command.requiresCommandId) {
        throw "durable command '$($command.wireName)' does not require commandId"
    }
}

$requiredFeatures = @('contacts','conversations','messaging','pairing','peer','presence','receipts','relationships')
foreach ($feature in $requiredFeatures) {
    Require-File "packages/torchat-runtime/src/features/$feature/mod.rs" | Out-Null
}

Require-File 'packages/torchat-client-engine-ffi/src/abi.rs' | Out-Null
Require-File 'docs/architecture/FFI-ABI.md' | Out-Null
Require-File 'packages/torchat-client-engine/src/actor/command_pipeline/stages.rs' | Out-Null
Require-File 'packages/torchat-runtime/src/operations.rs' | Out-Null
Require-File 'packages/torchat-runtime/src/ids.rs' | Out-Null

Write-Host '[torca] 0.3 architecture ownership check passed'
