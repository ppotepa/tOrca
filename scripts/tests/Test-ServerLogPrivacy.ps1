[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$checker = Join-Path $repoRoot 'scripts\internal\check-server-log-privacy.ps1'
$source = Join-Path $repoRoot 'server\torchat-server\src\main.rs'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("torchat-log-privacy-" + [guid]::NewGuid())

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $mutatedRoot = Join-Path $tempRoot 'server\torchat-server\src'
    New-Item -ItemType Directory -Path $mutatedRoot -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination (Join-Path $mutatedRoot 'main.rs')
    $mutated = Join-Path $mutatedRoot 'main.rs'
    (Get-Content -LiteralPath $mutated -Raw).Replace(
        'tracing::info!(installation_id_hash',
        'tracing::info!(installation_id = plaintext, installation_id_hash'
    ) | Set-Content -LiteralPath $mutated -NoNewline

    $failedAsExpected = $false
    try {
        & $checker -RepositoryRoot $tempRoot | Out-Null
    } catch {
        $failedAsExpected = $_.Exception.Message -match 'plaintext identifier'
    }
    if (-not $failedAsExpected) {
        throw 'Server log privacy checker accepted the intentionally unsafe mutation.'
    }
    Write-Output 'Server log privacy negative test passed.'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
