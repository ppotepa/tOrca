param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path) {
    $full = Join-Path $RepositoryRoot $Path
    if (-not (Test-Path -LiteralPath $full)) {
        throw "required message delivery file is missing: $Path"
    }
    return Get-Content -Raw -LiteralPath $full
}

$messaging = Require-Text 'packages/torchat-runtime/src/features/messaging/mod.rs'
foreach ($required in @(
    'pub trait MessageDeliveryStorage',
    'feature_queue_message_delivery',
    'feature_prepare_pending_message_deliveries',
    'feature_apply_message_delivery_outcome',
    'begin_message_delivery',
    'complete_message_delivery',
    'retry_message_delivery',
    'fail_message_delivery',
    'enqueue_outbound_delivery',
    'requeue_outbound_delivery',
    'complete_outbound_delivery',
    'message_state_after_transport_outcome'
)) {
    if (-not $messaging.Contains($required)) {
        throw "message delivery facade is incomplete: $required"
    }
}
foreach ($forbidden in @(
    'conversations()?.into_iter()',
    'contacts()?.into_iter()',
    'messages()?.into_iter()'
)) {
    if ($messaging.Contains($forbidden)) {
        throw "message delivery facade performs a forbidden collection scan: $forbidden"
    }
}

$operations = Require-Text 'packages/torchat-runtime/src/features/operations/mod.rs'
foreach ($required in @(
    'OperationType::MessageDelivery',
    'begin_message_delivery',
    'active_message_delivery',
    'complete_message_delivery',
    'retry_message_delivery',
    'fail_message_delivery'
)) {
    if (-not $operations.Contains($required)) {
        throw "message durable operation lifecycle is incomplete: $required"
    }
}

$adapter = Require-Text 'packages/torchat-storage/src/storage/transactional_message_delivery.rs'
foreach ($required in @(
    'impl torchat_runtime::features::messaging::MessageDeliveryStorage for SqliteRuntimeStorage',
    'ENQUEUE_OUTBOUND_DELIVERY',
    'REQUEUE_OUTBOUND_DELIVERY',
    'COMPLETE_OUTBOUND_DELIVERY',
    'changed != 1'
)) {
    if (-not $adapter.Contains($required)) {
        throw "transactional message delivery adapter is incomplete: $required"
    }
}

$storageMod = Require-Text 'packages/torchat-storage/src/storage/mod.rs'
if (-not $storageMod.Contains('include!("transactional_message_delivery.rs");')) {
    throw 'transactional message delivery adapter is not wired into SqliteRuntimeStorage'
}

$send = Require-Text 'packages/torchat-client-engine/src/actor/messaging.rs'
foreach ($required in @(
    'feature_queue_message_delivery',
    'PointLookupStorage::conversation_by_id',
    'PointLookupStorage::message_by_id',
    'persist_outbound_encryption',
    'claim_outgoing_attempt',
    'apply_message_delivery_outcome_with_error'
)) {
    if (-not $send.Contains($required)) {
        throw "send-message actor lifecycle is incomplete: $required"
    }
}
foreach ($forbidden in @(
    'list_conversations()?.into_iter()',
    'runtime.send_message_reply',
    'self.database.enqueue_outbound_delivery',
    'self.database.requeue_outbound_delivery',
    'self.database.complete_outbound_delivery',
    'self.database.mark_message_dead_lettered'
)) {
    if ($send.Contains($forbidden)) {
        throw "send-message actor still owns a forbidden persistence step: $forbidden"
    }
}

$peerEvents = Require-Text 'packages/torchat-client-engine/src/actor/peer_events.rs'
foreach ($required in @(
    'apply_message_delivery_outcome',
    'MessageTransportOutcome::PeerPersisted',
    'MessageTransportOutcome::PeerDelivered',
    'MessageTransportOutcome::PeerRejected'
)) {
    if (-not $peerEvents.Contains($required)) {
        throw "peer ACK path bypasses message delivery lifecycle: $required"
    }
}
if ($peerEvents.Contains('complete_outbound_delivery(&message_id)')) {
    throw 'peer ACK path deletes outbound delivery outside the runtime transaction'
}

$scheduler = Require-Text 'packages/torchat-client-engine/src/actor/retry_scheduler.rs'
foreach ($required in @(
    'RetryKind::MessageSend',
    'flush_pending_message_deliveries',
    'RetryKind::PairingResponse',
    'flush_pending_pairing_deliveries',
    'apply_message_delivery_outcome'
)) {
    if (-not $scheduler.Contains($required)) {
        throw "retry scheduler bypasses the split delivery lifecycle: $required"
    }
}
if ($scheduler.Contains('flush_pending_send_effects')) {
    throw 'retry scheduler still invokes the mixed compatibility send flush'
}

$deletion = Require-Text 'packages/torchat-runtime/src/features/message_deletion.rs'
foreach ($required in @(
    'ClientRuntimeMessageDeletionFacade',
    'OperationState::Cancelled',
    'complete_outbound_delivery',
    'delete_with_context'
)) {
    if (-not $deletion.Contains($required)) {
        throw "message deletion cleanup is incomplete: $required"
    }
}

$retryHandler = Require-Text 'packages/torchat-client-engine/src/actor/commands/messages/retry_message.rs'
foreach ($required in @(
    'retry message requires a durable operation id',
    'feature_retry_message',
    '&command_descriptor'
)) {
    if (-not $retryHandler.Contains($required)) {
        throw "manual retry is not bound to the durable message lifecycle: $required"
    }
}

Write-Host '[torca] durable message delivery lifecycle check passed'
