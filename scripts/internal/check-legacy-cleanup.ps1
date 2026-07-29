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
    'queueMessage',
    'updateMessageState',
    'markState(',
    'set_message_state(',
    'RuntimeCommand::QueueMessage',
    'RuntimeCommand::UpdateMessageState',
    'RuntimeContract.QUEUE_MESSAGE',
    'RuntimeContract.UPDATE_MESSAGE_STATE'
)

foreach ($needle in $legacy) {
    $hits = rg -n -F --glob '!concat.txt' $needle $roots 2>$null
    if ($hits) {
        throw "Legacy path still present: $needle"
    }
}

Write-Host '[torchat] legacy cleanup check passed'
