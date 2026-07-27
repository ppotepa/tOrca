[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$ForceRecreate,
    [switch]$NoCache,
    [ValidateSet('local')][string]$Environment = 'local'
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $repoRoot "infra\docker\compose.dev.yml"
. (Join-Path $PSScriptRoot "internal\environment.ps1")

$environmentState = Ensure-TorChatEnvironment $repoRoot $Environment
Import-TorChatEnvironment $environmentState

function Invoke-DockerComposeWithRetry {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$FailureMessage)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & docker @Arguments
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -lt 3) {
            $delay = 5 * $attempt
            Write-Warning "Docker command failed (attempt $attempt/3). Retrying in $delay seconds; this is often a transient registry/network timeout."
            Start-Sleep -Seconds $delay
        }
    }
    throw $FailureMessage
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Desktop is not running." }
if ($NoCache -and -not $Rebuild) {
    throw "-NoCache requires -Rebuild."
}

Push-Location $repoRoot
try {
    $composeArgs = @('compose', '--project-name', $environmentState.Values['TORCHAT_COMPOSE_PROJECT'], '--env-file', $environmentState.Paths.RuntimeEnvironment, '-f', $compose)
    & docker @($composeArgs + @('config')) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose configuration is invalid." }
    if ($Rebuild) {
        $buildArgs = $composeArgs + @('build')
        if ($NoCache) { $buildArgs += "--no-cache" }
        Invoke-DockerComposeWithRetry $buildArgs 'Docker image rebuild failed after three attempts. Check Docker Desktop network/proxy access to registry-1.docker.io and auth.docker.io.'
    }
    # A normal start asks Compose for an incremental build. An explicit
    # rebuild already produced the images above, so do not invoke BuildKit
    # twice before recreating the containers.
    $upArgs = $composeArgs + @('up', '-d', '--remove-orphans')
    if (-not $Rebuild) { $upArgs += "--build" }
    if ($ForceRecreate) { $upArgs += "--force-recreate" }
    Invoke-DockerComposeWithRetry $upArgs 'Local stack failed to start after three attempts.'

    $onion = $null
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $onion = (& docker @($composeArgs + @('exec', '-T', 'tor', 'cat', '/var/lib/tor/hidden_service/hostname')) 2>$null | Select-Object -First 1).Trim()
        if ($onion -match '^[a-z2-7]{56}\.onion$') { break }
        Start-Sleep -Seconds 2
    }
    if ($onion -notmatch '^[a-z2-7]{56}\.onion$') { throw "Tor onion hostname was not generated." }
    Set-TorChatEnvironmentOnion $environmentState "http://$onion"
    Import-TorChatEnvironment $environmentState -RequireOnion
    # The server receives the canonical public endpoint only after Tor has
    # generated it. Recreate just this service with the refreshed env file.
    & docker @($composeArgs + @('up', '-d', 'server'))
    if ($LASTEXITCODE -ne 0) { throw 'Development server restart failed.' }
    $health = $null
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try { $health = Invoke-RestMethod "http://127.0.0.1:$($environmentState.Values['TORCHAT_HTTP_PORT'])/health" -TimeoutSec 2; break } catch { Start-Sleep 2 }
    }
    if ($health.status -ne "ok") { throw "Server healthcheck failed." }
    & docker @($composeArgs + @('ps'))
    Write-Host "[torchat] local onion: $($env:TORCHAT_ONION_URL)"
} finally { Pop-Location }
