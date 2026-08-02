[CmdletBinding()]
param(
    [ValidateRange(60, 600)][int]$TimeoutSeconds = 300,
    [switch]$Rebuild,
    [switch]$UseExistingStack
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$torchat = Join-Path $repositoryRoot 'scripts\torchat.ps1'
if (-not (Test-Path -LiteralPath $torchat)) {
    throw "TorChat entrypoint is missing: $torchat"
}

# The standard stack command resolves and persists the generated onion before
# creating Torka. Reuse it rather than duplicating the fragile Tor lifecycle
# in a test script. A developer can opt into an already-running stack without
# contending for the global deploy mutex.
if (-not $UseExistingStack) {
    & $torchat stack start -Readiness strict -BuildPolicy $(if ($Rebuild) { 'rebuild' } else { 'smart' })
    if ($LASTEXITCODE -ne 0) { throw 'Could not start the local TorChat stack.' }
}

$runtimeEnv = Join-Path $repositoryRoot '.torchat\runtime\local\environment.env'
if (-not (Test-Path -LiteralPath $runtimeEnv)) {
    throw "Local runtime environment is missing: $runtimeEnv"
}
$runtimeValues = @{}
foreach ($line in Get-Content -LiteralPath $runtimeEnv) {
    if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $runtimeValues[$Matches[1]] = $Matches[2]
    }
}
$project = if ($runtimeValues['TORCHAT_COMPOSE_PROJECT']) {
    [string]$runtimeValues['TORCHAT_COMPOSE_PROJECT']
} else {
    'torchat-local'
}
$compose = @(
    'compose', '--project-name', $project, '--env-file', $runtimeEnv,
    '-f', (Join-Path $repositoryRoot 'infra\docker\compose.dev.yml'),
    '--profile', 'integration'
)
$env:TORCHAT_INTEGRATION_TIMEOUT_SECONDS = [string]$TimeoutSeconds

try {
    # The finite peer must never reuse a previous test identity or pairing
    # state. Its volume is exclusive to this test and does not affect Torka,
    # the relay database or developer client data.
    try {
        & docker volume rm -f "${project}_torka_integration_dev" 2>$null | Out-Null
    } catch {
        # Compose may still have a just-stopped one-shot container reference;
        # `up` below removes/reuses it and the volume is not shared with any
        # persistent client.
    }
    $up = @('up')
    if ($Rebuild) { $up += '--build' }
    if ($UseExistingStack) { $up += '--no-deps' }
    $up += @('--abort-on-container-exit', '--exit-code-from', 'torka-integration', 'torka-integration')
    & docker @($compose + $up)
    if ($LASTEXITCODE -ne 0) {
        throw "Two-engine Tor integration failed. Inspect: docker $($compose -join ' ') logs torka torka-integration"
    }
} finally {
    & docker @($compose + @('rm', '-sf', 'torka-integration')) | Out-Null
}

Write-Host 'TorChat two-real-engine Tor P2P integration passed.'
