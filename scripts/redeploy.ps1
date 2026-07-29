[CmdletBinding()]
param(
    [ValidateSet('local')]
    [string]$Environment = 'local',
    [ValidateSet('clean','preserve')]
    [string]$ClientState = 'clean',
    [switch]$Release,
    [switch]$NoCache,
    [string]$DeviceAddress
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $repoRoot 'infra\docker\compose.dev.yml'
. (Join-Path $PSScriptRoot 'internal\environment.ps1')

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Command
    )
    Write-Host "[torchat] $Name"
    & $Command
    if (-not $?) { throw "$Name failed." }
}

$environmentState = Ensure-TorChatEnvironment $repoRoot $Environment
$composeArgs = @(
    'compose',
    '--project-name', $environmentState.Values['TORCHAT_COMPOSE_PROJECT'],
    '--env-file', $environmentState.Paths.RuntimeEnvironment,
    '-f', $compose
)

Push-Location $repoRoot
try {
    Invoke-Step 'Destroy local Docker stack, database volume and Tor volume' {
        & docker @($composeArgs + @('down', '--volumes', '--remove-orphans'))
    }

    if (Test-Path -LiteralPath $environmentState.Paths.RuntimeEnvironment) {
        Remove-Item -LiteralPath $environmentState.Paths.RuntimeEnvironment -Force
    }
    Write-Host '[torchat] Removed local runtime environment so a fresh onion and secrets are generated.'

    Invoke-Step 'Start fresh local Docker/Tor stack' {
        $startArgs = @{
            Environment = 'local'
            Rebuild = $true
            ForceRecreate = $true
            AllowOnionWarmup = $true
        }
        if ($NoCache) { $startArgs.NoCache = $true }
        & (Join-Path $PSScriptRoot 'start-dev.ps1') @startArgs
    }

    $environmentState = Ensure-TorChatEnvironment $repoRoot $Environment
    Import-TorChatEnvironment $environmentState -RequireOnion
    Write-Host "[torchat] Fresh onion selected for this build: $($env:TORCHAT_ONION_URL)"

    Invoke-Step 'Build Android APK and Windows desktop with the fresh onion' {
        $buildArgs = @{
            Environment = 'local'
            Target = 'all'
        }
        if ($Release) { $buildArgs.Release = $true }
        & (Join-Path $PSScriptRoot 'internal\build-clients.ps1') @buildArgs
    }

    Invoke-Step 'Install and launch Android app' {
        $deployArgs = @{
            Environment = 'local'
            SkipServer = $true
            SkipCoreBuild = $true
            SkipApkBuild = $true
            Clean = ($ClientState -eq 'clean')
        }
        if ($Release) { $deployArgs.Release = $true }
        if ($DeviceAddress) { $deployArgs.DeviceAddress = $DeviceAddress }
        & (Join-Path $PSScriptRoot 'deploy-android.ps1') @deployArgs
    }

    Invoke-Step 'Start Windows desktop app' {
        $runArgs = @{
            Command = 'run-desktop'
            Environment = 'local'
            ClientState = $ClientState
            Clean = ($ClientState -eq 'clean')
            SkipEnvironmentStart = $true
        }
        if ($Release) { $runArgs.Release = $true }
        & (Join-Path $PSScriptRoot 'torchat.ps1') @runArgs
    }
} finally {
    Pop-Location
}
