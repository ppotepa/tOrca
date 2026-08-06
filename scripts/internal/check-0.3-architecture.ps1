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
    'Ok(Vec::new())',
    '.into_iter().find(',
    'for conversation in self.conversations()',
    'fn expedite_retry_after_ready(&mut self) -> RuntimeResult<()> {' + [Environment]::NewLine + '        Ok(())'
)) {
    if ($storage.Contains($forbidden)) {
        throw "RuntimeStorage contains a forbidden compatibility implementation: $forbidden"
    }
}

$pointLookupPort = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-runtime/src/point_lookup_storage.rs')
foreach ($forbidden in @('RuntimeStorage', 'impl<T:', '.into_iter().find(')) {
    if ($pointLookupPort.Contains($forbidden)) {
        throw "PointLookupStorage contains a forbidden compatibility fallback: $forbidden"
    }
}

$storageCapabilities = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-runtime/src/storage_capabilities.rs')
if ($storageCapabilities.Contains('impl<T: RuntimeStorage + ?Sized> OperationStorage')) {
    throw 'OperationStorage must be implemented by active adapters, not the RuntimeStorage compatibility aggregate'
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
    if ($command.requiresCommandId -and -not $command.idempotent) {
        throw "command '$($command.wireName)' requires commandId but is not idempotent"
    }
}

$requiredFeatures = @('contacts','conversations','messaging','pairing','peer','presence','receipts','relationships')
foreach ($feature in $requiredFeatures) {
    Require-File "packages/torchat-runtime/src/features/$feature/mod.rs" | Out-Null
}

foreach ($required in @(
    'packages/torchat-runtime/src/storage_port.rs',
    'packages/torchat-storage/src/storage/point_lookup_queries.rs',
    'packages/torchat-storage/src/storage/point_lookup_repository.rs',
    'packages/torchat-storage/src/storage/transactional_point_lookup.rs',
    'packages/torchat-storage/src/storage/operation_queries.rs',
    'packages/torchat-storage/src/storage/operation_repository.rs',
    'packages/torchat-storage/src/storage/transactional_operation_storage.rs',
    'packages/torchat-storage/sql/migrations/004_durable_operations.sql',
    'packages/torchat-client-engine/src/actor/command_pipeline/stages.rs',
    'packages/torchat-client-engine/src/generated/command_contract.rs',
    'apps/mobile/flutter/lib/core/runtime/generated/command_contract.g.dart',
    'apps/mobile/flutter/android/app/src/main/kotlin/org/torchat/generated/GeneratedCommandContract.kt',
    'packages/torchat-client-engine-ffi/src/abi.rs',
    'docs/architecture/FFI-ABI.md',
    'packages/torchat-runtime/src/operations.rs',
    'packages/torchat-runtime/src/ids.rs',
    'scripts/internal/generate_sql_catalog.py'
)) {
    Require-File $required | Out-Null
}

$pointLookupRepository = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-storage/src/storage/point_lookup_repository.rs')
foreach ($required in @('impl PointLookupStorage for ClientDatabase', 'point_lookup_queries::contact_by_installation_id', 'point_lookup_queries::message_by_id')) {
    if (-not $pointLookupRepository.Contains($required)) {
        throw "SQLite point lookup repository is not integrated: $required"
    }
}

$transactionalPointLookup = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-storage/src/storage/transactional_point_lookup.rs')
foreach ($required in @('impl PointLookupStorage for SqliteRuntimeStorage', 'point_lookup_queries::contact_by_installation_id', 'point_lookup_queries::message_by_id')) {
    if (-not $transactionalPointLookup.Contains($required)) {
        throw "transactional SQLite point lookup is not integrated: $required"
    }
}

$operationRepository = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-storage/src/storage/operation_repository.rs')
foreach ($required in @('impl OperationStorage for ClientDatabase', 'operation_queries::operation_by_id', 'operation_queries::put_operation')) {
    if (-not $operationRepository.Contains($required)) {
        throw "SQLite durable operation repository is not integrated: $required"
    }
}
if ($operationRepository.Contains('allow(dead_code)')) {
    throw 'durable operation repository contains dead-code suppression'
}

$transactionalOperations = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-storage/src/storage/transactional_operation_storage.rs')
foreach ($required in @('impl OperationStorage for SqliteRuntimeStorage', 'operation_queries::operation_by_id', 'operation_queries::put_operation', 'operation_queries::pending_operations')) {
    if (-not $transactionalOperations.Contains($required)) {
        throw "transactional durable operation storage is not integrated: $required"
    }
}

$commandProcessor = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-client-engine/src/actor/command_pipeline/processor.rs')
foreach ($forbidden in @(
    'let _ = self.database.save_processed_command',
    'let Ok(Some((stored_type, result_json, _revision))) ='
)) {
    if ($commandProcessor.Contains($forbidden)) {
        throw "command pipeline silently ignores idempotency persistence: $forbidden"
    }
}
foreach ($required in @(
    'match self.database.load_processed_command(command_id)',
    'let idempotency_result = (|| -> EngineResult<()>',
    'return self.command_error_result(envelope.request_id, error)'
)) {
    if (-not $commandProcessor.Contains($required)) {
        throw "command pipeline is missing explicit idempotency error handling: $required"
    }
}

Write-Host '[torca] 0.3 architecture ownership check passed'
