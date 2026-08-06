param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path) {
    $full = Join-Path $RepositoryRoot $Path
    if (-not (Test-Path -LiteralPath $full)) {
        throw "required durable pairing file is missing: $Path"
    }
    return Get-Content -Raw -LiteralPath $full
}

$operations = Require-Text 'packages/torchat-runtime/src/features/operations/mod.rs'
foreach ($required in @(
    'pub struct OperationsFeature',
    'pub trait ClientRuntimeOperationsFacade',
    'feature_begin_pairing_operation',
    'feature_complete_pairing_operation',
    'feature_retry_pairing_operation',
    'feature_fail_pairing_operation',
    'OperationType::PairingCancellation',
    'command_descriptor',
    'OperationState::Completed',
    'schedule_retry',
    'RetryClass::NetworkBackoff'
)) {
    if (-not $operations.Contains($required)) {
        throw "durable pairing lifecycle is incomplete: $required"
    }
}

$features = Require-Text 'packages/torchat-runtime/src/features/mod.rs'
if (-not $features.Contains('pub mod operations;')) {
    throw 'OperationsFeature is not exported from runtime features'
}

$cancelCommand = Require-Text 'packages/torchat-client-engine/src/actor/commands/pairing/cancel_pairing.rs'
foreach ($required in @(
    'ClientRuntimeOperationsFacade',
    'context.command_id.clone()',
    '&context.command_descriptor',
    'feature_begin_pairing_operation',
    'feature_prepare_cancel_pairing'
)) {
    if (-not $cancelCommand.Contains($required)) {
        throw "cancel pairing does not start its durable lifecycle: $required"
    }
}

$cancelOutcome = Require-Text 'packages/torchat-client-engine/src/actor/command_pipeline/effect_outcomes/pairing_cancelled.rs'
foreach ($required in @(
    'feature_complete_pairing_operation',
    'feature_retry_pairing_operation',
    'RuntimeErrorCode::TransportUnavailable',
    'record_pairing_cancel_failure'
)) {
    if (-not $cancelOutcome.Contains($required)) {
        throw "cancel pairing outcome does not persist its lifecycle: $required"
    }
}

$processor = Require-Text 'packages/torchat-client-engine/src/actor/command_pipeline/processor.rs'
foreach ($required in @(
    'record_pairing_cancel_failure',
    'cancel pairing failure is missing its durable operation id',
    'Err(lifecycle_error) => Err(lifecycle_error)'
)) {
    if (-not $processor.Contains($required)) {
        throw "effect pipeline does not persist pairing retry state: $required"
    }
}

$transactionalStorage = Require-Text 'packages/torchat-storage/src/storage/transactional_operation_storage.rs'
if (-not $transactionalStorage.Contains('impl OperationStorage for SqliteRuntimeStorage')) {
    throw 'durable pairing lifecycle is not backed by transactional SQLite storage'
}

Write-Host '[torca] durable pairing lifecycle check passed'
