[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "rebuild", "deploy-android", "desktop", "full-deploy", "status")]
    [string]$Command = "status",
    [switch]$NoCache,
    [switch]$ResetDevState,
    [switch]$SkipCoreBuild,
    [switch]$SkipApkBuild,
    [switch]$NoDevPair,
    [string]$DeviceAddress,
    [ValidateSet("Alice", "Bob")]
    [string]$DevProfile = "Alice"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptsRoot = Join-Path $repoRoot "scripts"

function Invoke-TorChatScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$ChildParameters = @{}
    )
    Write-Verbose ("[torchat] {0} {1}" -f $Name, (($ChildParameters.GetEnumerator() | ForEach-Object { "-$($_.Key)=$($_.Value)" }) -join " "))
    & (Join-Path $scriptsRoot $Name) @ChildParameters
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
}

function Start-TorChatDesktop {
    $desktopScript = Join-Path $scriptsRoot "run-desktop.ps1"
    Start-Process powershell.exe `
        -WorkingDirectory $repoRoot `
        -ArgumentList @("-NoExit", "-ExecutionPolicy", "Bypass", "-File", $desktopScript, "-SkipServer") `
        -WindowStyle Normal | Out-Null
    Write-Host "[torchat] Desktop Bob started in a separate PowerShell window."
}

switch ($Command) {
    "start" {
        Invoke-TorChatScript "start-dev.ps1"
    }
    "stop" {
        Invoke-TorChatScript "stop-dev.ps1"
    }
    "rebuild" {
        $childParameters = @{}
        if ($NoCache) { $childParameters.NoCache = $true }
        Invoke-TorChatScript -Name "rebuild-dev.ps1" -ChildParameters $childParameters
    }
    "deploy-android" {
        $childParameters = @{ SkipServer = $true; DevProfile = $DevProfile }
        if ($SkipCoreBuild) { $childParameters.SkipCoreBuild = $true }
        if ($SkipApkBuild) { $childParameters.SkipApkBuild = $true }
        if ($NoDevPair) { $childParameters.NoDevPair = $true }
        if ($ResetDevState) { $childParameters.ResetDevState = $true }
        if ($DeviceAddress) { $childParameters.DeviceAddress = $DeviceAddress }
        Invoke-TorChatScript -Name "deploy-android.ps1" -ChildParameters $childParameters
    }
    "desktop" {
        Invoke-TorChatScript -Name "run-desktop.ps1" -ChildParameters @{ SkipServer = $true }
    }
    "full-deploy" {
        Write-Host "[torchat] Full deploy: rebuild -> Docker -> Android -> desktop"
        $rebuildParameters = @{}
        if ($NoCache) { $rebuildParameters.NoCache = $true }
        Invoke-TorChatScript -Name "rebuild-dev.ps1" -ChildParameters $rebuildParameters

        $androidParameters = @{
            SkipServer = $true
            SkipCoreBuild = $true
            SkipApkBuild = $true
            DevProfile = $DevProfile
        }
        if ($NoDevPair) { $androidParameters.NoDevPair = $true }
        if ($ResetDevState) { $androidParameters.ResetDevState = $true }
        if ($DeviceAddress) { $androidParameters.DeviceAddress = $DeviceAddress }
        Invoke-TorChatScript -Name "deploy-android.ps1" -ChildParameters $androidParameters

        Start-TorChatDesktop
        Write-Host "[torchat] Full deploy completed."
    }
    "status" {
        . (Join-Path $scriptsRoot "internal\dev-config.ps1")
        Import-TorChatDevConfig $repoRoot -AllowPlaceholder
        $compose = Join-Path $repoRoot "infra\docker\compose.dev.yml"
        Write-Host "[torchat] Configured onion: $env:TORCHAT_ONION_URL"
        Write-Host "[torchat] Docker:"
        docker compose -f $compose ps
        Write-Host "[torchat] ADB devices:"
        adb devices
        Write-Host "[torchat] Managed desktop processes:"
        Get-CimInstance Win32_Process -Filter "Name = 'torchat-desktop.exe'" |
            Select-Object ProcessId, ParentProcessId, Name
    }
}
