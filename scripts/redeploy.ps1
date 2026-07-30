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
$deployRunId = if ($env:TORCHAT_DEPLOY_RUN_ID) { $env:TORCHAT_DEPLOY_RUN_ID } else { [Guid]::NewGuid().ToString('N') }
$env:TORCHAT_DEPLOY_RUN_ID = $deployRunId
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
    param([string]$Name, [scriptblock]$Command)
    $started = Get-Date
    Write-Host "[torchat] deployRunId=$deployRunId stage=$Name state=starting"
    & $Command
    if (-not $?) { throw "$Name failed." }
    $duration = [int]((Get-Date) - $started).TotalMilliseconds
    Write-Host "[torchat] deployRunId=$deployRunId stage=$Name state=ready durationMs=$duration"
}

function Get-DesktopClientProcesses {
    return @(Get-Process -Name 'torchat_mobile' -ErrorAction SilentlyContinue | Where-Object { -not $_.HasExited })
}

function Get-DesktopSidecarProcesses {
    return @(Get-Process -Name 'torchat-desktop' -ErrorAction SilentlyContinue | Where-Object { -not $_.HasExited })
}

function Get-DesktopTorProcesses {
    $normalizedRoot = [System.IO.Path]::GetFullPath($repoRoot)
    return @(Get-CimInstance Win32_Process -Filter "Name = 'tor.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $commandLine = [string]$_.CommandLine
            $commandLine -and (
                $commandLine.Contains($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                $commandLine.Contains('.torchat', [System.StringComparison]::OrdinalIgnoreCase)
            )
        })
}

function Stop-ProcessSet {
    param([object[]]$Processes, [string]$Role)
    foreach ($process in @($Processes)) {
        $pidValue = if ($process.PSObject.Properties.Name -contains 'ProcessId') { [int]$process.ProcessId } else { [int]$process.Id }
        if ($pidValue -le 0) { continue }
        Write-Host "[torchat] deployRunId=$deployRunId role=$Role pid=$pidValue state=stopping"
        Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
        try { Wait-Process -Id $pidValue -Timeout 5 -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-DesktopRuntimeTree {
    Stop-ProcessSet -Processes @(Get-DesktopClientProcesses) -Role 'windows-runner'
    Stop-ProcessSet -Processes @(Get-DesktopSidecarProcesses) -Role 'desktop-engine'
    Stop-ProcessSet -Processes @(Get-DesktopTorProcesses) -Role 'desktop-tor'
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        if (@(Get-DesktopClientProcesses).Count -eq 0 -and
            @(Get-DesktopSidecarProcesses).Count -eq 0 -and
            @(Get-DesktopTorProcesses).Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    }
    throw 'Could not stop the previous Windows runner, engine sidecar and desktop Tor before redeploy.'
}

if ($Incremental -and $PreserveTor) { throw 'Use either -Incremental or -PreserveTor, not both.' }

$environmentState = Ensure-TorChatEnvironment $repoRoot $Environment
$composeArgs = @('compose','--project-name',$environmentState.Values['TORCHAT_COMPOSE_PROJECT'],'--env-file',$environmentState.Paths.RuntimeEnvironment,'-f',$compose)

Push-Location $repoRoot
try {
    Write-Host "[torchat] deployRunId=$deployRunId state=started clientState=$ClientState"
    if ($ClientState -eq 'clean') {
        Write-Warning '[torchat] ClientState=clean will remove local client identity, contacts and message state.'
    }

    if ($Incremental) {
        Invoke-Step 'reuse-stack' { & (Join-Path $PSScriptRoot 'start-dev.ps1') -Environment local -SkipOnionHealth }
    } elseif ($PreserveTor) {
        Invoke-Step 'preserve-tor' {
            & docker @($composeArgs + @('up', '-d', 'postgres', 'tor'))
            if ($LASTEXITCODE -ne 0) { throw 'Could not keep the PostgreSQL and Tor services running.' }
        }
        Invoke-Step 'rebuild-server' {
            $serverBuild = $composeArgs + @('build', 'server')
            if ($NoCache) { $serverBuild += '--no-cache' }
            & docker @serverBuild
            if ($LASTEXITCODE -ne 0) { throw 'Local server image rebuild failed.' }
            & docker @($composeArgs + @('up', '-d', '--force-recreate', 'server'))
            if ($LASTEXITCODE -ne 0) { throw 'Local server recreation failed.' }
        }
        Invoke-Step 'verify-stack' { & (Join-Path $PSScriptRoot 'start-dev.ps1') -Environment local }
    } else {
        Invoke-Step 'destroy-stack' { & docker @($composeArgs + @('down', '--volumes', '--remove-orphans')) }
        if (Test-Path -LiteralPath $environmentState.Paths.RuntimeEnvironment) {
            Remove-Item -LiteralPath $environmentState.Paths.RuntimeEnvironment -Force
        }
        Invoke-Step 'start-fresh-stack' {
            $startArgs = @{ Environment = 'local'; Rebuild = $true; ForceRecreate = $true }
            if ($NoCache) { $startArgs.NoCache = $true }
            & (Join-Path $PSScriptRoot 'start-dev.ps1') @startArgs
        }
    }

    $environmentState = Ensure-TorChatEnvironment $repoRoot $Environment
    Import-TorChatEnvironment $environmentState -RequireOnion

    Invoke-Step 'build-windows' {
        $windowsArgs = @{ Environment = 'local' }
        if ($Release) { $windowsArgs.Release = $true }
        if ($Incremental) { $windowsArgs.Incremental = $true }
        & (Join-Path $PSScriptRoot 'deploy-windows.ps1') @windowsArgs
    }

    Invoke-Step 'deploy-android' {
        $deployArgs = @{ Environment = 'local'; SkipServer = $true; Clean = ($ClientState -eq 'clean') }
        if ($Release) { $deployArgs.Release = $true }
        if ($DeviceAddress) { $deployArgs.DeviceAddress = $DeviceAddress }
        & (Join-Path $PSScriptRoot 'deploy-android.ps1') @deployArgs
    }

    Invoke-Step 'run-windows' {
        Stop-DesktopRuntimeTree
        $runArgs = @{
            Environment = 'local'
            ClientState = $ClientState
            Clean = ($ClientState -eq 'clean')
            SkipEnvironmentStart = $true
        }
        if ($Release) { $runArgs.Release = $true }
        & (Join-Path $PSScriptRoot 'run-windows.ps1') @runArgs
        $desktopProcesses = @()
        $sidecarProcesses = @()
        for ($attempt = 1; $attempt -le 40; $attempt++) {
            Start-Sleep -Milliseconds 500
            $desktopProcesses = @(Get-DesktopClientProcesses)
            $sidecarProcesses = @(Get-DesktopSidecarProcesses)
            if ($desktopProcesses.Count -eq 1 -and $sidecarProcesses.Count -eq 1) { break }
        }
        if ($desktopProcesses.Count -ne 1) { throw "Expected exactly one Windows runner, found $($desktopProcesses.Count)." }
        if ($sidecarProcesses.Count -ne 1) { throw "Expected exactly one desktop engine sidecar, found $($sidecarProcesses.Count)." }
        Write-Host "[torchat] deployRunId=$deployRunId stage=windows-ready runnerPid=$($desktopProcesses[0].Id) sidecarPid=$($sidecarProcesses[0].Id)"
    }
    Write-Host "[torchat] deployRunId=$deployRunId state=completed"
} catch {
    Write-Error "[torchat] deployRunId=$deployRunId state=failed error=$($_.Exception.Message)"
    throw
} finally {
    Pop-Location
    if ($deployMutexAcquired) { try { $deployMutex.ReleaseMutex() } catch { } }
    $deployMutex.Dispose()
}
