[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $repoRoot "infra\docker\compose.dev.yml"
Push-Location $repoRoot
try {
    docker compose -f $compose down
    if ($LASTEXITCODE -ne 0) { throw "Development stack stop failed." }
    Write-Host "Development stack stopped. PostgreSQL and Tor volumes were preserved."
} finally { Pop-Location }
