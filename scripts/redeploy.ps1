[CmdletBinding()]
param(
    [ValidateSet('local')]
    [string]$Environment = 'local',
    [ValidateSet('clean','preserve')]
    [string]$ClientState = 'preserve',
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

$deployMutex = [System.Threading.Mutex]::new($false, 'Global\TorChat-Redeploy')
$deployMutexAcquired = $false
try {
    $deployMutexAcquired = $deployMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $deployMutexAcquired = $true
}
if (-not $deployMutexAcquired) {
    $deployMutex.Dispose()
    throw 'Another TorChat redeploy is already running. Wait for it to finish before starting a new deploy.'
}

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Command
    )
    Write-Host "[torchat] $Name"
    & $Command
    if (-not $?) { throw "$Name failed." }
}

function Get-DesktopClientProcesses {
    return @(
        Get-Process -Name 'torchat_mobile' -ErrorAction SilentlyContinue |
            Where-Object { -not $_.HasExited }
    )
}

function Get-DesktopSidecarProcesses {
    return @(
        Get-Process -Name 'torchat-desktop' -ErrorAction SilentlyContinue |
            Where-Object { -not $_.HasExited }
    )
}

function Get-DesktopTorProcesses {
    $normalizedRoot = [System.IO.Path]::GetFullPath($repoRoot)
    return @(
        Get-CimInstance Win32_Process -Filter "Name = 'tor.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $commandLine = [string]$_.CommandLine
                $commandLine -and (
                    $commandLine.Contains($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $commandLine.Contains('.torchat', [System.StringComparison]::OrdinalIgnoreCase)
                )
            }
    )
}

function Stop-ProcessSet {
    param(
        [object[]]$Processes,
        [string]$Role
    )
    foreach ($process in @($Processes)) {
        $pidValue = if ($process.PSObject.Properties.Name -contains 'ProcessId') {
            [int]$process.ProcessId
        } else {
            [int]$process.Id
        }
        if ($pidValue -le 0) { continue }
        Write-Host "[torchat] Stopping stale $Role PID $pidValue before launch."
        Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
        try { Wait-Process -Id $pidValue -Timeout 5 -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-DesktopRuntimeTree {
    Stop-ProcessSet -Processes @(Get-DesktopClientProcesses) -Role 'Windows runner'
    Stop-ProcessSet -Processes @(Get-DesktopSidecarProcesses) -Role 'desktop engine'
    Stop-ProcessSet -Processes @(Get-DesktopTorProcesses) -Role 'desktop Tor'

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $runnerCount = @(Get-DesktopClientProcesses).Count
        $sidecarCount = @(Get-DesktopSidecarProcesses).Count
        $torCount = @(Get-DesktopTorProcesses).Count
        if ($runnerCount -eq 0 -and $sidecarCount -eq 0 -and $torCount -eq 0) { return }
        Start-Sleep -Milliseconds 200
    }
    throw 'Could not stop the previous Windows runner, engine sidecar and desktop Tor before redeploy.'
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
    if ($ClientState -eq 'clean') {
        Write-Warning '[torchat] ClientState=clean will remove local client identity, contacts and message state.'
    }

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
        Stop-DesktopRuntimeTree
        $runArgs = @{
            Command = 'run-desktop'
            Environment = 'local'
            ClientState = $ClientState
            Clean = ($ClientState -eq 'clean')
            SkipEnvironmentStart = $true
        }
        if ($Release) { $runArgs.Release = $true }
        & (Join-Path $PSScriptRoot 'torchat.ps1') @runArgs

        $desktopProcesses = @()
        $sidecarProcesses = @()
        for ($attempt = 1; $attempt -le 40; $attempt++) {
            Start-Sleep -Milliseconds 500
            $desktopProcesses = @(Get-DesktopClientProcesses)
            $sidecarProcesses = @(Get-DesktopSidecarProcesses)
            if ($desktopProcesses.Count -eq 1 -and $sidecarProcesses.Count -eq 1) { break }
        }

        if ($desktopProcesses.Count -ne 1) {
            throw "Expected exactly one Windows runner after launch, found $($desktopProcesses.Count). Inspect .torchat\command-logs and .torchat\logs."
        }
        if ($sidecarProcesses.Count -ne 1) {
            throw "Expected exactly one desktop engine sidecar after launch, found $($sidecarProcesses.Count). Inspect .torchat\command-logs and .torchat\logs."
        }

        $runnerPid = $desktopProcesses[0].Id
        $sidecarPid = $sidecarProcesses[0].Id
        Write-Host "[torchat] Windows desktop is ready (runner PID $runnerPid, engine PID $sidecarPid)."
    }
} finally {
    Pop-Location
    if ($deployMutexAcquired) {
        try { $deployMutex.ReleaseMutex() } catch { }
    }
    $deployMutex.Dispose()
}
