[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sqlRoots = @(
    (Join-Path $repoRoot 'desktop\sql'),
    (Join-Path $repoRoot 'mobile\android\app\src\main\assets\sql'),
    (Join-Path $repoRoot 'infra\db\migrations')
)

$forbidden = @(
    'message_state_update.sql',
    'set_message_state',
    'markState('
)

foreach ($needle in $forbidden) {
    $hits = rg -n -F --glob '!concat.txt' --glob '!**/build/**' $needle $sqlRoots 2>$null
    if ($hits) {
        throw "SQL isolation violation: $needle"
    }
}

Write-Host '[torchat] SQL isolation check passed'
