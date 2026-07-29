[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$forbidden = @(
    'messages',
    'message_body',
    'ciphertext',
    'mls',
    'welcome',
    'application'
)

$serverRoots = @(
    (Join-Path $repoRoot 'server\torchat-server\sql'),
    (Join-Path $repoRoot 'infra\db\migrations')
)
foreach ($needle in $forbidden) {
    $hits = rg -n -F --glob '!**/target/**' $needle $serverRoots 2>$null
    if ($hits) {
        throw "Server relay persistence marker found: $needle"
    }
}

Write-Host '[torchat] server relay ephemeral check passed'
