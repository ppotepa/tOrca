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
# Forbidden compatibility stubs. The multi-line pattern is assembled into a
# variable first: PowerShell otherwise splits an @() array element on the
# embedded newline, which yields a false positive matching only the method
# signature line (e.g. an Err(unsupported) trait default mistaken for an
# Ok(()) no-op stub).
$forbiddenExpediteStub = 'fn expedite_retry_after_ready(&mut self) -> RuntimeResult<()> {' + [Environment]::NewLine + '        Ok(())'
$forbiddenStorageStubs = @(
    'Ok(Vec::new())',
    '.into_iter().find(',
    'for conversation in self.conversations()',
    $forbiddenExpediteStub
)
foreach ($forbidden in $forbiddenStorageStubs) {
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

$pairingFeature = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-runtime/src/features/pairing/mod.rs')
foreach ($required in @(
    'pub struct PairingFeature',
    'pairing_inbox_by_id',
    'pairing_outbox_by_id',
    'contact_by_installation_id',
    'FeatureResult<InviteState>'
)) {
    if (-not $pairingFeature.Contains($required)) {
        throw "pairing feature is missing its capability-based command boundary: $required"
    }
}
foreach ($forbidden in @('pairing_inbox()?.into_iter()', 'pairing_outbox()?.into_iter()', 'contacts()?.into_iter()')) {
    if ($pairingFeature.Contains($forbidden)) {
        throw "pairing feature performs a forbidden collection scan: $forbidden"
    }
}

$contactsFeature = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-runtime/src/features/contacts/mod.rs')
foreach ($required in @('contact_by_installation_id', 'update_settings', 'pub fn verify')) {
    if (-not $contactsFeature.Contains($required)) {
        throw "contacts feature is missing migrated command behavior: $required"
    }
}
if ($contactsFeature.Contains('contacts()?.into_iter()')) {
    throw 'contacts feature performs a forbidden collection scan'
}

$conversationsFeature = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-runtime/src/features/conversations/mod.rs')
foreach ($required in @('conversation_for_contact', 'activate_for_contact')) {
    if (-not $conversationsFeature.Contains($required)) {
        throw "conversations feature is missing migrated command behavior: $required"
    }
}
if ($conversationsFeature.Contains('conversations()?.into_iter()')) {
    throw 'conversations feature performs a forbidden collection scan'
}

$featureFacade = Get-Content -Raw -LiteralPath (Require-File 'packages/torchat-runtime/src/feature_facade.rs')
foreach ($required in @(
    'feature_prepare_accept_pairing',
    'feature_accept_pairing',
    'feature_reject_pairing',
    'feature_archive_pairing',
    'feature_prepare_cancel_pairing',
    'feature_confirm_pairing_cancelled',
    'feature_update_contact_settings',
    'feature_verify_contact',
    'feature_start_conversation'
)) {
    if (-not $featureFacade.Contains($required)) {
        throw "feature facade does not expose the migrated command: $required"
    }
}

$pairingHandlerRequirements = @{
    'packages/torchat-client-engine/src/actor/commands/pairing/accept_pairing.rs' = 'feature_accept_pairing'
    'packages/torchat-client-engine/src/actor/commands/pairing/reject_pairing.rs' = 'feature_reject_pairing'
    'packages/torchat-client-engine/src/actor/commands/pairing/archive_pairing.rs' = 'feature_archive_pairing'
    'packages/torchat-client-engine/src/actor/commands/pairing/cancel_pairing.rs' = 'feature_prepare_cancel_pairing'
    'packages/torchat-client-engine/src/actor/command_pipeline/effect_outcomes/pairing_cancelled.rs' = 'feature_confirm_pairing_cancelled'
}
foreach ($entry in $pairingHandlerRequirements.GetEnumerator()) {
    $handler = Get-Content -Raw -LiteralPath (Require-File $entry.Key)
    if (-not $handler.Contains('ClientRuntimeFeatureFacade') -or -not $handler.Contains($entry.Value)) {
        throw "pairing handler '$($entry.Key)' bypasses the feature facade"
    }
}

$featureCommandRequirements = @{
    'packages/torchat-client-engine/src/actor/commands/contacts/update_contact_settings.rs' = 'feature_update_contact_settings'
    'packages/torchat-client-engine/src/actor/commands/contacts/verify_contact.rs' = 'feature_verify_contact'
    'packages/torchat-client-engine/src/actor/commands/conversations/start_conversation.rs' = 'feature_start_conversation'
}
foreach ($entry in $featureCommandRequirements.GetEnumerator()) {
    $handler = Get-Content -Raw -LiteralPath (Require-File $entry.Key)
    if (-not $handler.Contains('ClientRuntimeFeatureFacade') -or -not $handler.Contains($entry.Value)) {
        throw "command handler '$($entry.Key)' bypasses the feature facade"
    }
    foreach ($forbidden in @('runtime.update_contact_settings', 'runtime.verify_contact', 'runtime.start_conversation')) {
        if ($handler.Contains($forbidden)) {
            throw "command handler '$($entry.Key)' still calls monolithic runtime behavior: $forbidden"
        }
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
