[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$serverRoot = Join-Path $repoRoot 'services\torchat-relay'
$cargo = Get-Content -Raw (Join-Path $serverRoot 'Cargo.toml')
foreach ($needle in @('postgres', 'rusqlite', 'sqlx', 'diesel', 'sled')) {
    if ($cargo -match "(?i)\b$needle\b") { throw "Relay server has datastore dependency: $needle" }
}

foreach ($relative in @('sql', 'data', 'storage', 'repository')) {
    if (Test-Path -LiteralPath (Join-Path $serverRoot $relative)) {
        throw "Relay server contains persistent-data directory: $relative"
    }
}
$source = Get-ChildItem -LiteralPath (Join-Path $serverRoot 'src') -Recurse -File -Filter *.rs |
    Get-Content -Raw
foreach ($needle in @('std::fs::write', 'File::create', 'tokio_postgres', 'RelayPayloadV1', 'PeerCiphertextPayload')) {
    if ($source -match [regex]::Escape($needle)) { throw "Relay server contains forbidden application/storage symbol: $needle" }
}
if ($source -notmatch 'route\("/health"') { throw 'Relay server is missing /health route' }
if ($source -notmatch 'route\("/rendezvous"') { throw 'Relay server is missing V1 /rendezvous route' }
if ($source -match 'route\("/metrics"') { throw 'Relay server exposes a public history endpoint' }

Write-Host '[torchat] server relay ephemeral check passed'
