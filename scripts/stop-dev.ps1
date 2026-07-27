[CmdletBinding()]
param([ValidateSet('local')][string]$Environment = 'local')
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $repoRoot "infra\docker\compose.dev.yml"
. (Join-Path $PSScriptRoot "internal\environment.ps1")
$environmentState = Ensure-TorChatEnvironment $repoRoot $Environment
Push-Location $repoRoot
try {
    & docker @('compose', '--project-name', $environmentState.Values['TORCHAT_COMPOSE_PROJECT'], '--env-file', $environmentState.Paths.RuntimeEnvironment, '-f', $compose, 'down')
    if ($LASTEXITCODE -ne 0) { throw "Development stack stop failed." }
    Write-Host "Local stack stopped. PostgreSQL and Tor volumes were preserved."
} finally { Pop-Location }
