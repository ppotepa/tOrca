[CmdletBinding()]
param(
    [switch]$FailOnLegacy
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$manifestPath = Join-Path $repoRoot 'common\client-engine-contract.json'

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing engine contract manifest: $manifestPath"
}

$generated = @(
    (Join-Path $repoRoot 'mobile\android\app\src\main\kotlin\org\torchat\generated\EngineContract.kt'),
    (Join-Path $repoRoot 'mobile\lib\core\runtime\generated\runtime_contract.g.dart'),
    (Join-Path $repoRoot 'mobile\lib\core\models\generated\runtime_models.g.dart')
)
foreach ($file in $generated) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Missing generated contract artifact: $file"
    }
}

try {
    $contract = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
} catch {
    throw "Engine contract manifest is not valid JSON: $manifestPath"
}

$requiredPublic = @(
    'connect',
    'identity',
    'profile',
    'setNickname',
    'refreshPairingCode',
    'submitPairingCode',
    'pairingInbox',
    'pairingOutbox',
    'acceptPairing',
    'rejectPairing',
    'archivePairing',
    'cancelPairing',
    'verifyContact',
    'contacts',
    'conversations',
    'messages',
    'openConversation',
    'closeConversation',
    'startConversation',
    'sendMessage'
)

$publicMethods = @($contract.methods.public | ForEach-Object { $_.ToString() })
$missingPublic = @($requiredPublic | Where-Object { $_ -notin $publicMethods })
if ($missingPublic.Count -gt 0) {
    throw "Engine contract manifest is missing required public methods: $($missingPublic -join ', ')"
}

$generatedChecks = @(
    @{ Path = $generated[0]; Needles = @('const val CONNECT = "connect"', 'const val MESSAGES = "messages"', 'const val PROFILE_READY = "profile_ready"') },
    @{ Path = $generated[1]; Needles = @("static const connect = 'connect';", "static const messages = 'messages';", "static const profileReady = 'profile_ready';") },
    @{ Path = $generated[2]; Needles = @("'FORWARDED'", "'WELCOME_PREPARED'") }
)
foreach ($check in $generatedChecks) {
    $content = Get-Content -LiteralPath $check.Path -Raw
    foreach ($needle in $check.Needles) {
        if ($content -notlike "*$needle*") {
            throw "Generated contract artifact is stale: missing '$needle' in $($check.Path)"
        }
    }
}

Write-Host '[torchat] runtime contract check passed'
