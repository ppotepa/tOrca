[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$roots = @(
    (Join-Path $repoRoot 'common\torchat-client-runtime\src'),
    (Join-Path $repoRoot 'desktop\src'),
    (Join-Path $repoRoot 'mobile\android\app\src\main\kotlin'),
    (Join-Path $repoRoot 'mobile\lib'),
    (Join-Path $repoRoot 'server\torchat-server\src')
)

$legacy = @(
    'ChatController',
    'RuntimeCommandAdapter',
    'RuntimeStateSnapshot',
    'RuntimeSessionHost',
    'RuntimeJsonHandle',
    'queueMessage',
    'updateMessageState',
    'markState(',
    'set_message_state(',
    'RuntimeCommand::QueueMessage',
    'RuntimeCommand::UpdateMessageState'
)

foreach ($needle in $legacy) {
    $hits = rg -n -F --glob '!concat.txt' --glob '!scripts/internal/check-legacy-cleanup.ps1' $needle $roots 2>$null
    if ($hits) {
        throw "Legacy path still present: $needle"
    }
}

Write-Host '[torchat] legacy cleanup check passed'
