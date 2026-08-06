param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path) {
    $full = Join-Path $RepositoryRoot $Path
    if (-not (Test-Path -LiteralPath $full)) {
        throw "required durable operation resume file is missing: $Path"
    }
    return Get-Content -Raw -LiteralPath $full
}

$operationModel = Require-Text 'packages/torchat-runtime/src/operations.rs'
foreach ($required in @(
    'PairingCancellation',
    'pub command_descriptor: Option<String>',
    'with_command_descriptor'
)) {
    if (-not $operationModel.Contains($required)) {
        throw "durable operation model cannot preserve resume context: $required"
    }
}

$migration = Require-Text 'packages/torchat-storage/sql/migrations/005_durable_operation_resume_context.sql'
foreach ($required in @(
    'ADD COLUMN command_descriptor TEXT',
    "operation_type = 'pairing_cancellation'",
    "state IN ('pending', 'running', 'waiting_for_retry')"
)) {
    if (-not $migration.Contains($required)) {
        throw "durable operation resume migration is incomplete: $required"
    }
}

$migrations = Require-Text 'packages/torchat-storage/src/storage/sqlite/migrations.rs'
if (-not $migrations.Contains('005_durable_operation_resume_context.sql')) {
    throw 'durable operation resume migration is not registered'
}

foreach ($path in @(
    'packages/torchat-storage/sql/commands/operations/upsert_operation.sql',
    'packages/torchat-storage/sql/queries/operations/operation_by_id.sql',
    'packages/torchat-storage/sql/queries/operations/pending_operations.sql',
    'packages/torchat-storage/src/storage/operation_queries.rs'
)) {
    $text = Require-Text $path
    if (-not $text.Contains('command_descriptor')) {
        throw "durable operation resume context is not persisted by $path"
    }
}

$scheduler = Require-Text 'packages/torchat-client-engine/src/actor/retry_scheduler.rs'
foreach ($required in @(
    'next_durable_operation_wakeup_at',
    'resume_due_durable_operation',
    'OperationStorage::pending_operations',
    'OperationType::PairingCancellation',
    'feature_begin_pairing_operation',
    'feature_prepare_cancel_pairing',
    'feature_fail_pairing_operation',
    '__resume__:'
)) {
    if (-not $scheduler.Contains($required)) {
        throw "retry scheduler cannot resume durable operations: $required"
    }
}

$inputHandlers = Require-Text 'packages/torchat-client-engine/src/actor/input_handlers.rs'
foreach ($required in @(
    'resume_due_durable_operation',
    'next_durable_operation_wakeup_at',
    '[ordinary_retry_at, durable_retry_at]'
)) {
    if (-not $inputHandlers.Contains($required)) {
        throw "actor timer does not integrate durable operation resume: $required"
    }
}
if ($inputHandlers.Contains('ResponseResult::Error {')) {
    throw 'input handlers bypass the structured RuntimeProblem constructor'
}

Write-Host '[torca] durable operation resume check passed'
