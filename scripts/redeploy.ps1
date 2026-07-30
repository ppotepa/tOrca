[CmdletBinding()]
param(
    [ValidateSet('local')]
    [string]$Environment = 'local',
    [ValidateSet('clean','preserve')]
    [string]$ClientState = 'clean',
    [switch]$Release,
    [switch]$Incremental,
    [switch]$PreserveTor,
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

function Test-DesktopClientRunning {
    $windowsRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'mobile\build\windows'))
    return @(
        Get-CimInstance Win32_Process -Filter "Name='torchat_mobile.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ExecutablePath -and
                [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith(
                    $windowsRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    ).Count -gt 0
}

if ($Incremental -and $PreserveTor) {
    throw 'Use either -Incremental or -PreserveTor, not both.'
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
    if ($Incremental) {
        Invoke-Step 'Reuse local Docker/Tor stack' {
            & (Join-Path $PSScriptRoot 'start-dev.ps1') -Environment local -SkipOnionHealth
        }
    } elseif ($PreserveTor) {
        Invoke-Step 'Keep the current Tor instance and onion' {
            & docker @($composeArgs + @('up', '-d', 'postgres', 'tor'))
            if ($LASTEXITCODE -ne 0) { throw 'Could not keep the PostgreSQL and Tor services running.' }
        }

        Invoke-Step 'Rebuild and recreate only the local server' {
            $serverBuild = $composeArgs + @('build', 'server')
            if ($NoCache) { $serverBuild += '--no-cache' }
            & docker @serverBuild
            if ($LASTEXITCODE -ne 0) { throw 'Local server image rebuild failed.' }
            & docker @($composeArgs + @('up', '-d', '--force-recreate', 'server'))
            if ($LASTEXITCODE -ne 0) { throw 'Local server recreation failed.' }
        }

        Invoke-Step 'Verify the preserved Tor/onion stack' {
            & (Join-Path $PSScriptRoot 'start-dev.ps1') -Environment local
        }
    } else {
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
            }
            if ($NoCache) { $startArgs.NoCache = $true }
            & (Join-Path $PSScriptRoot 'start-dev.ps1') @startArgs
        }
    }

    if ($Incremental) {
        Write-Host '[torchat] Incremental redeploy keeps the current onion, server and local volumes.'
    } elseif ($PreserveTor) {
        Write-Host '[torchat] PreserveTor redeploy keeps the current Tor process, onion and Tor volume while rebuilding the server and clients.'
    }

    $environmentState = Ensure-TorChatEnvironment $repoRoot $Environment
    Import-TorChatEnvironment $environmentState -RequireOnion
    $onionLabel = if ($Incremental -or $PreserveTor) { 'Current onion selected for this build' } else { 'Fresh onion selected for this build' }
    Write-Host "[torchat] $onionLabel`: $($env:TORCHAT_ONION_URL)"

    Invoke-Step 'Build Android APK and Windows desktop' {
        $buildArgs = @{
            Environment = 'local'
            Target = 'all'
        }
        if ($Release) { $buildArgs.Release = $true }
        if ($Incremental) { $buildArgs.Smart = $true }
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

        Start-Sleep -Seconds 2
        if (-not (Test-DesktopClientRunning)) {
            $variant = if ($Release) { 'Release' } else { 'Debug' }
            $desktopClient = Join-Path $repoRoot "mobile\build\windows\x64\runner\$variant\torchat_mobile.exe"
            if (-not (Test-Path -LiteralPath $desktopClient)) {
                throw "Windows desktop executable is missing after build: $desktopClient"
            }
            Write-Warning '[torchat] Desktop process was not detected after the normal launcher; retrying once directly.'
            Start-Process -FilePath $desktopClient -WorkingDirectory (Split-Path -Parent $desktopClient)
            Start-Sleep -Seconds 2
        }

        if (-not (Test-DesktopClientRunning)) {
            throw 'Windows desktop process exited immediately after launch. Inspect .torchat\command-logs and .torchat\logs.'
        }
        Write-Host '[torchat] Windows desktop process is running.'
    }
} finally {
    Pop-Location
}
