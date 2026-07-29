[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')]
    [string]$Environment = 'local',
    [switch]$Release,
    [switch]$Incremental,
    [switch]$Clean,
    [ValidateSet('preserve','clean')]
    [string]$ClientState = 'preserve',
    [switch]$NoCache,
    [switch]$SkipMobileBuild,
    [string]$DeviceAddress
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$cleanClientState = $Clean -or $ClientState -eq 'clean'

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Command
    )
    Write-Host "[torchat] $Name"
    & $Command
    if (-not $?) { throw "$Name failed." }
}

if ($Environment -eq 'local') {
    $serverArgs = @{ Environment = 'local'; SkipOnionHealth = $true }
    if (-not $Incremental) {
        $serverArgs.Rebuild = $true
        $serverArgs.ForceRecreate = $true
        if ($NoCache) { $serverArgs.NoCache = $true }
    } else {
        Write-Host '[torchat] Reusing the running local Docker/Tor stack.'
    }
    Invoke-Step 'Start local environment' {
        & (Join-Path $PSScriptRoot 'start-dev.ps1') @serverArgs
    }
}

$buildArgs = @{
    Environment = $Environment
    Target = 'all'
}
if ($Release -or $Environment -ne 'local') { $buildArgs.Release = $true }
if (-not $SkipMobileBuild) {
    Invoke-Step 'Build clients' {
        & (Join-Path $PSScriptRoot 'internal\build-clients.ps1') @buildArgs
    }
} else {
    Invoke-Step 'Build desktop runtime' {
        & (Join-Path $PSScriptRoot 'internal\build-desktop-runtime.ps1') -Release:($Release -or $Environment -ne 'local')
    }
}

if ($cleanClientState) {
    $desktopStateRoot = Join-Path $repoRoot '.torchat\clients\desktop'
    foreach ($path in @(
        (Join-Path $desktopStateRoot 'identity.key'),
        (Join-Path $desktopStateRoot 'torchat-client-v1.db'),
        (Join-Path $desktopStateRoot 'torchat-client-v1.db-wal'),
        (Join-Path $desktopStateRoot 'torchat-client-v1.db-shm'),
        (Join-Path $desktopStateRoot 'torchat-client-v1.db-journal')
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    Write-Host '[torchat] Cleared desktop client local state.'
}

$deployArgs = @{
    Environment = $Environment
    SkipServer = $true
    SkipCoreBuild = $true
    SkipApkBuild = $true
    Clean = $cleanClientState
}
if ($Release -or $Environment -ne 'local') { $deployArgs.Release = $true }
if ($DeviceAddress) { $deployArgs.DeviceAddress = $DeviceAddress }
Invoke-Step 'Deploy Android' {
    & (Join-Path $PSScriptRoot 'deploy-android.ps1') @deployArgs
}

$runArgs = @{
    Command = 'run-desktop'
    Environment = $Environment
    Target = 'windows'
}
if ($Release) { $runArgs.Release = $true }
if ($cleanClientState) { $runArgs.Clean = $true }
Invoke-Step 'Run desktop' {
    & (Join-Path $PSScriptRoot 'torchat.ps1') @runArgs
}
