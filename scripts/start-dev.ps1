[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$ForceRecreate,
    [switch]$NoCache,
    [switch]$KeepOtherStacks,
    [switch]$SkipOnionHealth,
    [switch]$AllowOnionWarmup,
    [ValidateSet('local')][string]$Environment = 'local'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $repoRoot 'infra\docker\compose.dev.yml'
. (Join-Path $PSScriptRoot 'internal\environment.ps1')

$state = Ensure-TorChatEnvironment $repoRoot $Environment
Import-TorChatEnvironment $state
$composeArgs = @(
    'compose', '--project-name', $state.Values['TORCHAT_COMPOSE_PROJECT'],
    '--env-file', $state.Paths.RuntimeEnvironment, '-f', $compose
)

function Invoke-Compose([string[]]$arguments, [string]$message) {
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw $message }
}

function Wait-Health([string]$url) {
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $health = Invoke-RestMethod -Uri $url -TimeoutSec 2
            if ($health.status -eq 'ok') { return }
        } catch { }
        Start-Sleep -Seconds 2
    }
    throw "Local server healthcheck failed: $url"
}

function Wait-OnionHealth([string]$url, [int]$socksPort) {
    $attempts = 3
    $timeoutSeconds = 12
    $lastFailure = 'no probe result'

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Host "[torchat] Onion probe $attempt/${attempts}: SOCKS=127.0.0.1:$socksPort timeout=${timeoutSeconds}s url=$url/health"
        $probeOutput = & curl.exe --silent --show-error --fail-with-body --max-time $timeoutSeconds `
            --socks5-hostname "127.0.0.1:$socksPort" "$url/health" 2>&1
        $exitCode = $LASTEXITCODE
        $stopwatch.Stop()
        $probeText = ($probeOutput | Out-String).Trim()

        if ($exitCode -eq 0) {
            try {
                $payload = $probeText | ConvertFrom-Json
                if ($payload.status -eq 'ok') {
                    Write-Host "[torchat] Onion probe passed in $($stopwatch.ElapsedMilliseconds) ms."
                    return $true
                }
                $lastFailure = "unexpected health status '$($payload.status)'"
            } catch {
                $lastFailure = "invalid health response: $probeText"
            }
        } else {
            $detail = if ($probeText) { $probeText } else { 'curl returned no diagnostic output' }
            $lastFailure = "curl exit=$exitCode after $($stopwatch.ElapsedMilliseconds) ms: $detail"
        }

        Write-Warning "[torchat] Onion probe $attempt/$attempts not ready: $lastFailure"
        if ($attempt -lt $attempts) { Start-Sleep -Seconds 3 }
    }

    if ($AllowOnionWarmup) {
        Write-Warning "[torchat] Fresh onion is still warming up after short probes. Continuing redeploy; Android and desktop reconnect actors will retry. Last result: $lastFailure"
        return $false
    }

    throw "Tor onion healthcheck failed through SOCKS. Last result: $lastFailure"
}

function Get-OnionHostname {
    for ($attempt = 1; $attempt -le 120; $attempt++) {
        $output = & docker @($composeArgs + @('exec', '-T', 'tor', 'cat', '/var/lib/tor/hidden_service/hostname')) 2>$null
        $hostname = ($output | Select-Object -First 1 | Out-String).Trim()
        if ($hostname -match '^[a-z2-7]{56}\.onion$') { return $hostname }
        Start-Sleep -Seconds 2
    }
    throw 'Tor onion hostname was not generated.'
}

Push-Location $repoRoot
try {
    & docker @($composeArgs + @('config')) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose configuration is invalid.' }

    if ($Rebuild) {
        $build = $composeArgs + @('build')
        if ($NoCache) { $build += '--no-cache' }
        Invoke-Compose $build 'Docker image rebuild failed.'
    }

    $up = $composeArgs + @('up', '-d', '--remove-orphans')
    if ($ForceRecreate) { $up += '--force-recreate' }
    Invoke-Compose $up 'Local stack failed to start.'

    $onion = Get-OnionHostname
    Set-TorChatEnvironmentOnion $state "http://$onion"
    Import-TorChatEnvironment $state -RequireOnion
    if ($Rebuild -or $ForceRecreate) {
        Invoke-Compose ($composeArgs + @('up', '-d', '--force-recreate', 'server')) 'Development server restart failed.'
    }

    Wait-Health ('http://127.0.0.1:{0}/health' -f $state.Values['TORCHAT_HTTP_PORT'])
    if ($SkipOnionHealth) {
        Write-Host '[torchat] Skipping Tor SOCKS onion healthcheck; clients will retry while circuits warm up.'
    } else {
        Wait-OnionHealth $env:TORCHAT_ONION_URL ([int]$state.Values['TORCHAT_SOCKS_PORT'])
    }
    & docker @($composeArgs + @('ps'))
    Write-Host "[torchat] local onion: $($env:TORCHAT_ONION_URL)"
} finally {
    Pop-Location
}
