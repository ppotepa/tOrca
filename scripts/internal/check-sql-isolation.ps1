[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$checker = Join-Path $PSScriptRoot 'check-sql-files.py'
if (Test-Path -LiteralPath $checker) {
    & python $checker --root $repoRoot --strict
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$sqlRoots = @(
    (Join-Path $repoRoot 'packages\torchat-storage\sql')
)
$sqlRoots = @($sqlRoots | Where-Object { Test-Path -LiteralPath $_ })
$connectionPragmas = Join-Path $repoRoot 'packages\torchat-storage\sql\queries\connection_pragmas.sql'
if (Test-Path -LiteralPath $connectionPragmas) {
    $pragmas = Get-Content -LiteralPath $connectionPragmas -Raw
    foreach ($forbidden in @('CREATE TABLE', 'CREATE TRIGGER', 'CREATE VIEW', 'ALTER TABLE', 'INSERT INTO')) {
        if ($pragmas -match [regex]::Escape($forbidden)) {
            throw "Connection pragmas contain schema/data SQL: $forbidden"
        }
    }
}

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
