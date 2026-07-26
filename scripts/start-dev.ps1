[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$ForceRecreate,
    [switch]$NoCache
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $repoRoot "infra\docker\compose.dev.yml"
. (Join-Path $PSScriptRoot "internal\dev-config.ps1")

Import-TorChatDevConfig $repoRoot -AllowPlaceholder
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Desktop is not running." }
if ($NoCache -and -not $Rebuild) {
    throw "-NoCache requires -Rebuild."
}

Push-Location $repoRoot
try {
    docker compose -f $compose config | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose configuration is invalid." }
    if ($Rebuild) {
        $buildArgs = @("compose", "-f", $compose, "build")
        if ($NoCache) { $buildArgs += "--no-cache" }
        & docker @buildArgs
        if ($LASTEXITCODE -ne 0) { throw "Docker image rebuild failed." }
    }
    # A normal start asks Compose for an incremental build. An explicit
    # rebuild already produced the images above, so do not invoke BuildKit
    # twice before recreating the containers.
    $upArgs = @("compose", "-f", $compose, "up", "-d", "--remove-orphans")
    if (-not $Rebuild) { $upArgs += "--build" }
    if ($ForceRecreate) { $upArgs += "--force-recreate" }
    & docker @upArgs
    if ($LASTEXITCODE -ne 0) { throw "Development stack failed to start." }

    $onion = $null
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $onion = (docker compose -f $compose exec -T tor cat /var/lib/tor/hidden_service/hostname 2>$null | Select-Object -First 1).Trim()
        if ($onion -match '^[a-z2-7]{56}\.onion$') { break }
        Start-Sleep -Seconds 2
    }
    if ($onion -notmatch '^[a-z2-7]{56}\.onion$') { throw "Tor onion hostname was not generated." }
    Set-TorChatDevOnionUrl $repoRoot "http://$onion"
    $health = $null
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try { $health = Invoke-RestMethod http://127.0.0.1:8080/health -TimeoutSec 2; break } catch { Start-Sleep 2 }
    }
    if ($health.status -ne "ok") { throw "Server healthcheck failed." }
    docker compose -f $compose ps
    Write-Host "Development server: $($env:TORCHAT_ONION_URL)"
} finally { Pop-Location }
