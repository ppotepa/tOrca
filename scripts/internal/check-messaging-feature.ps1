param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path) {
    $full = Join-Path $RepositoryRoot $Path
    if (-not (Test-Path -LiteralPath $full)) {
        throw "required messaging feature file is missing: $Path"
    }
    return Get-Content -Raw -LiteralPath $full
}

$feature = Require-Text 'packages/torchat-runtime/src/features/messaging/mod.rs'
foreach ($required in @(
    'pub trait ClientRuntimeMessagingFacade',
    'feature_retry_message',
    'feature_queue_message_delivery',
    'feature_apply_message_delivery_outcome',
    'message_by_id',
    'conversation_by_id',
    'contact_by_installation_id',
    'message_state_on_send_prepare',
    'MessageState::Queued',
    'MessageStateChanged'
)) {
    if (-not $feature.Contains($required)) {
        throw "messaging feature command boundary is incomplete: $required"
    }
}
foreach ($forbidden in @(
    'conversations()?.into_iter()',
    'contacts()?.into_iter()',
    'messages()?.into_iter()'
)) {
    if ($feature.Contains($forbidden)) {
        throw "messaging feature performs a forbidden collection scan: $forbidden"
    }
}

$retry = Require-Text 'packages/torchat-client-engine/src/actor/commands/messages/retry_message.rs'
foreach ($required in @(
    'ClientRuntimeMessagingFacade',
    'feature_retry_message',
    'self.clock.now_ms()',
    'deliver_send_effect(retry.value.into())'
)) {
    if (-not $retry.Contains($required)) {
        throw "retry-message handler bypasses the messaging feature: $required"
    }
}
if ($retry.Contains('runtime.retry_message')) {
    throw 'retry-message handler still calls the ClientRuntime monolith'
}

$delete = Require-Text 'packages/torchat-client-engine/src/actor/commands/messages/delete_message_local.rs'
foreach ($required in @(
    'ClientRuntimeMessageDeletionFacade',
    'feature_delete_message_delivery',
    'self.clock.now_ms()'
)) {
    if (-not $delete.Contains($required)) {
        throw "delete-message handler bypasses transactional delivery cleanup: $required"
    }
}
if ($delete.Contains('runtime.delete_message_local')) {
    throw 'delete-message handler still calls the ClientRuntime monolith'
}

Write-Host '[torca] messaging feature command check passed'
