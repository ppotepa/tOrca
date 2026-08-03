[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
}

$server = Join-Path $RepositoryRoot 'server\torchat-server\src\main.rs'
$queries = Join-Path $RepositoryRoot 'server\torchat-server\src\queries.rs'
$instanceLockSql = Join-Path $RepositoryRoot 'server\torchat-server\sql\queries\instance\try_advisory_lock.sql'
$compose = Join-Path $RepositoryRoot 'infra\docker\compose.host.yml'
if (-not (Test-Path -LiteralPath $server) -or
    -not (Test-Path -LiteralPath $queries) -or
    -not (Test-Path -LiteralPath $instanceLockSql) -or
    -not (Test-Path -LiteralPath $compose)) {
    throw 'Single-instance release files are missing.'
}

$serverText = Get-Content -LiteralPath $server -Raw
$queriesText = Get-Content -LiteralPath $queries -Raw
$instanceLockSqlText = Get-Content -LiteralPath $instanceLockSql -Raw
$composeText = Get-Content -LiteralPath $compose -Raw

if ($serverText -notmatch 'TRY_ADVISORY_LOCK' -or
    $queriesText -notmatch 'try_advisory_lock\.sql' -or
    $instanceLockSqlText -notmatch 'pg_try_advisory_lock') {
    throw 'Server does not acquire the PostgreSQL single-instance advisory lock.'
}
if ($serverText -notmatch 'single-instance-v0\.1') {
    throw 'Server does not expose the enforced 0.1 single-instance deployment mode.'
}
if ($composeText -notmatch '(?m)^\s*replicas:\s*1\s*$') {
    throw 'Release compose must declare exactly one server replica.'
}

Write-Output 'Single-instance release policy check passed.'
