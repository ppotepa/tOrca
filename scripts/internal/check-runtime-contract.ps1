[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$manifestPath = Join-Path $repoRoot 'common\client-engine-contract.json'
$kotlinPath = Join-Path $repoRoot 'mobile\android\app\src\main\kotlin\org\torchat\generated\EngineContract.kt'
$dartContractPath = Join-Path $repoRoot 'mobile\lib\core\runtime\generated\runtime_contract.g.dart'
$dartModelsPath = Join-Path $repoRoot 'mobile\lib\core\models\generated\runtime_models.g.dart'

foreach ($file in @($manifestPath, $kotlinPath, $dartContractPath, $dartModelsPath)) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Missing engine contract artifact: $file"
    }
}

try {
    $contract = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
} catch {
    throw "Engine contract manifest is not valid JSON: $manifestPath"
}

function Assert-ExactContractList {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object[]]$Actual,
        [Parameter(Mandatory = $true)][string[]]$Expected
    )

    $actualValues = @($Actual | ForEach-Object { $_.ToString() })
    $missing = @($Expected | Where-Object { $_ -notin $actualValues })
    $unexpected = @($actualValues | Where-Object { $_ -notin $Expected })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
        throw "$Name mismatch. Missing: $($missing -join ', '); unexpected: $($unexpected -join ', ')"
    }
}

Assert-ExactContractList 'Public engine methods' $contract.methods.public @(
    'bootstrap',
    'connect',
    'getIdentity',
    'getProfile',
    'pairingInbox',
    'pairingOutbox',
    'listContacts',
    'listConversations',
    'listMessages',
    'setNickname',
    'refreshPairingCode',
    'submitPairingCode',
    'acceptPairing',
    'rejectPairing',
    'archivePairing',
    'cancelPairing',
    'verifyContact',
    'updateContactSettings',
    'startConversation',
    'openConversation',
    'closeConversation',
    'sendMessage',
    'retryMessage',
    'deleteMessageLocal',
    'setTyping',
    'setPresence',
    'sendReadReceipts',
    'platformFact',
    'shutdown'
)

Assert-ExactContractList 'Engine command types' $contract.commandTypes @(
    'bootstrap',
    'connect',
    'get_identity',
    'get_profile',
    'pairing_inbox',
    'pairing_outbox',
    'list_contacts',
    'list_conversations',
    'list_messages',
    'set_nickname',
    'refresh_pairing_code',
    'submit_pairing_code',
    'accept_pairing',
    'reject_pairing',
    'archive_pairing',
    'cancel_pairing',
    'verify_contact',
    'update_contact_settings',
    'start_conversation',
    'open_conversation',
    'close_conversation',
    'send_message',
    'retry_message',
    'delete_message_local',
    'set_typing',
    'set_presence',
    'send_read_receipts',
    'platform_fact',
    'shutdown'
)

Assert-ExactContractList 'Engine event types' $contract.engineEventTypes @(
    'response',
    'runtime',
    'connection',
    'notification_requested',
    'log',
    'fatal'
)
Assert-ExactContractList 'Response statuses' $contract.responseStatuses @('ok', 'error')
Assert-ExactContractList 'Response payload types' $contract.responsePayloadTypes @('empty', 'json')
Assert-ExactContractList 'Platform fact types' $contract.platformFactTypes @(
    'tor_status',
    'tor_endpoint_available',
    'tor_endpoint_lost',
    'app_visibility_changed',
    'network_changed'
)

Assert-ExactContractList 'Tor phases' $contract.torPhases @(
    'starting',
    'bootstrapping',
    'ready',
    'failed'
)
Assert-ExactContractList 'Connection states' $contract.connectionStates @(
    'waiting_for_tor',
    'disconnected',
    'connecting',
    'authenticating',
    'waiting_for_ready',
    'connected',
    'backoff',
    'stopped'
)
Assert-ExactContractList 'Transport phases' $contract.transportPhases @(
    'starting',
    'bootstrapping',
    'connecting',
    'degraded',
    'connected',
    'reconnecting',
    'offline',
    'error'
)

$generatedChecks = @(
    @{
        Path = $kotlinPath
        Needles = @(
            'const val GET_IDENTITY = "getIdentity"',
            'const val LIST_MESSAGES = "listMessages"',
            'const val COMMAND_GET_IDENTITY = "get_identity"',
            'const val COMMAND_LIST_MESSAGES = "list_messages"',
            'const val EVENT_RESPONSE = "response"',
            'const val RESPONSE_STATUS_OK = "ok"',
            'const val RESPONSE_PAYLOAD_JSON = "json"',
            'const val ARG_PAIRING_ID = "pairingId"',
            'const val COMMAND_CONVERSATION_ID = "conversation_id"',
            'const val CONVERSATION_ID = "conversationId"',
            'const val TOR_PHASE_READY = "ready"',
            'const val CONNECTION_STATE_BACKOFF = "backoff"',
            'const val TRANSPORT_PHASE_RECONNECTING = "reconnecting"',
            'data class GeneratedEngineResponse',
            'data class GeneratedEngineEvent',
            'Engine response is missing payload envelope',
            'Unknown engine response payload type'
        )
    },
    @{
        Path = $dartContractPath
        Needles = @(
            'abstract final class EngineContract',
            "static const getIdentity = 'getIdentity';",
            "static const listMessages = 'listMessages';",
            "static const commandGetIdentity = 'get_identity';",
            "static const commandListMessages = 'list_messages';",
            "static const eventResponse = 'response';",
            "static const responseStatusOk = 'ok';",
            "static const responsePayloadJson = 'json';",
            "static const argPairingId = 'pairingId';",
            "static const commandConversationId = 'conversation_id';",
            "static const conversationId = 'conversationId';",
            "static const torPhaseReady = 'ready';",
            "static const connectionStateBackoff = 'backoff';",
            "static const transportPhaseReconnecting = 'reconnecting';"
        )
    },
    @{
        Path = $dartModelsPath
        Needles = @(
            'class GeneratedEngineEvent',
            'class GeneratedEngineResponse',
            'expected engine response event',
            'engine response is missing payload envelope',
            'unknown engine response payload type',
            'const generatedTorPhases',
            'const generatedConnectionStates',
            'const generatedTransportPhases',
            "'FORWARDED'",
            "'WELCOME_PREPARED'"
        )
    }
)

foreach ($check in $generatedChecks) {
    $content = Get-Content -LiteralPath $check.Path -Raw
    foreach ($needle in $check.Needles) {
        if (-not $content.Contains($needle)) {
            throw "Generated engine contract artifact is stale: missing '$needle' in $($check.Path)"
        }
    }
}

Write-Host '[torchat] engine contract check passed'
