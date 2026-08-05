[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Read-Text([string]$relativePath) {
    $path = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return Get-Content -LiteralPath $path -Raw
}

$serverManifest = Read-Text 'services\torchat-relay\Cargo.toml'
foreach ($forbidden in @('rusqlite', 'sqlx', 'diesel', 'sled', 'torchat-client-engine',
        'torchat-client-runtime', 'torchat-peer', 'torchat-storage')) {
    if ($serverManifest -match "(?i)(?m)^\s*$forbidden\s*=") {
        throw "Relay manifest has forbidden dependency: $forbidden"
    }
}

$serverSourceRoot = Join-Path $repoRoot 'services\torchat-relay\src'
$serverSource = if (Test-Path -LiteralPath $serverSourceRoot) {
    (Get-ChildItem -LiteralPath $serverSourceRoot -Recurse -File -Filter *.rs |
        Get-Content -Raw) -join "`n"
} else { '' }

foreach ($forbidden in @('PeerCiphertextPayload', 'ApplicationPayloadV1',
        'std::fs::write', 'std::fs::File', 'rusqlite', 'tokio_postgres')) {
    if ($serverSource -match [regex]::Escape($forbidden)) {
        throw "Relay source has forbidden client/storage symbol: $forbidden"
    }
}

$protocolRoots = @(
    (Join-Path $repoRoot 'packages\torchat-protocol'),
    (Join-Path $repoRoot 'packages\torchat-relay-protocol'),
    (Join-Path $repoRoot 'common\torchat-core')
) | Where-Object { Test-Path -LiteralPath $_ }

foreach ($root in $protocolRoots) {
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.rs,Cargo.toml)
    foreach ($file in $files) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($forbidden in @('rusqlite', 'tokio_tungstenite', 'flutter', 'SQLCipher')) {
            if ($content -match [regex]::Escape($forbidden)) {
                throw "Protocol boundary contains forbidden dependency/API '$forbidden': $($file.FullName)"
            }
        }
    }
}

$relayProtocolRoot = Join-Path $repoRoot 'packages\torchat-relay-protocol'
if (Test-Path -LiteralPath $relayProtocolRoot) {
    $relayProtocolSource = (Get-ChildItem -LiteralPath $relayProtocolRoot -Recurse -File -Filter *.rs |
        Get-Content -Raw) -join "`n"
    foreach ($forbidden in @('ApplicationPayloadV1', 'PeerCiphertextPayload', 'MessageEnvelope')) {
        if ($relayProtocolSource -match [regex]::Escape($forbidden)) {
            throw "Relay protocol contains application message symbol: $forbidden"
        }
    }
}

$domainManifest = Read-Text 'packages\torchat-domain\Cargo.toml'
foreach ($forbidden in @('rusqlite', 'tokio', 'tokio-tungstenite', 'reqwest', 'std::net', 'std::fs')) {
    if ($domainManifest -match [regex]::Escape($forbidden)) {
        throw "Domain manifest/source has forbidden infrastructure dependency: $forbidden"
    }
}

$cryptoManifest = Read-Text 'packages\torchat-crypto\Cargo.toml'
foreach ($forbidden in @('rusqlite', 'tokio', 'reqwest', 'flutter', 'sqlcipher')) {
    if ($cryptoManifest -match [regex]::Escape($forbidden)) {
        throw "Crypto manifest has forbidden infrastructure dependency: $forbidden"
    }
}

$storageManifest = Read-Text 'packages\torchat-storage\Cargo.toml'
if ($storageManifest -match '(?im)^\s*torchat-client-engine\s*=') {
    throw 'Storage manifest must not depend on torchat-client-engine'
}
$storageSourceRoot = Join-Path $repoRoot 'packages\torchat-storage\src'
if (Test-Path -LiteralPath $storageSourceRoot) {
    $storageSource = (Get-ChildItem -LiteralPath $storageSourceRoot -Recurse -File -Filter *.rs |
        Get-Content -Raw) -join "`n"
    foreach ($forbidden in @('torchat_client_engine', 'tokio_tungstenite')) {
        if ($storageSource -match [regex]::Escape($forbidden)) {
            throw "Storage source has forbidden engine/transport dependency: $forbidden"
        }
    }
}

$peerManifest = Read-Text 'packages\torchat-peer\Cargo.toml'
foreach ($forbidden in @('torchat-client-engine', 'torchat-storage', 'torchat-rendezvous-client')) {
    if ($peerManifest -match "(?im)^\s*$forbidden\s*=") {
        throw "Peer manifest has forbidden dependency: $forbidden"
    }
}

$desktopFlutterEntry = Join-Path $repoRoot 'apps\desktop\flutter\lib\main.dart'
if (-not (Test-Path -LiteralPath $desktopFlutterEntry)) {
    throw 'Missing desktop Flutter composition root'
}
$domainSourceRoot = Join-Path $repoRoot 'packages\torchat-domain\src'
if (Test-Path -LiteralPath $domainSourceRoot) {
    $domainSource = (Get-ChildItem -LiteralPath $domainSourceRoot -Recurse -File -Filter *.rs |
        Get-Content -Raw) -join "`n"
    foreach ($forbidden in @('std::net', 'std::fs', 'tokio::', 'rusqlite::', 'reqwest::')) {
        if ($domainSource -match [regex]::Escape($forbidden)) {
            throw "Domain source has forbidden infrastructure API: $forbidden"
        }
    }
}

$modulesRoot = Join-Path $repoRoot 'scripts\modules'
$entryPoint = Join-Path $repoRoot 'scripts\torchat.ps1'
if (-not (Test-Path -LiteralPath $entryPoint)) { throw 'Missing public scripts/torchat.ps1 entrypoint' }
if (-not (Test-Path -LiteralPath $modulesRoot)) { throw 'Missing scripts/modules orchestration layer' }

Write-Host '[torchat] dependency boundary check passed'
