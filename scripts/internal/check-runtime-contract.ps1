[CmdletBinding()]
param(
    [switch]$FailOnLegacy
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$required = @(
    'preparePendingSendEffects',
    'applyMessageTransportOutcome',
    'MessageSendEffect',
    'MessageTransportOutcome'
)

$requiredMissing = @()
foreach ($needle in $required) {
    $hits = rg -n --glob '!concat.txt' --glob '!scripts/internal/check-runtime-contract.ps1' --glob '!scripts/internal/check-legacy-cleanup.ps1' --glob '!scripts/internal/check-server-relay-ephemeral.ps1' --glob '!scripts/internal/check-sql-isolation.ps1' $needle $repoRoot 2>$null
    if (-not $hits) {
        $requiredMissing += $needle
    }
}

if ($requiredMissing.Count -gt 0) {
    throw "Missing required runtime contract markers: $($requiredMissing -join ', ')"
}

if ($FailOnLegacy) {
    $legacy = @(
        'RuntimeCommand::QueueMessage',
        '"queueMessage" =>',
        'RuntimeCommand::UpdateMessageState',
        '"updateMessageState" =>',
        'RuntimeContract.QUEUE_MESSAGE',
        'RuntimeContract.UPDATE_MESSAGE_STATE',
        'markState(',
        'set_message_state('
    )
    foreach ($needle in $legacy) {
        $hits = rg -n --glob '!concat.txt' $needle $repoRoot 2>$null
        if ($hits) {
            throw "Legacy runtime contract path still present: $needle"
        }
    }
}

Write-Host '[torchat] runtime contract check passed'
