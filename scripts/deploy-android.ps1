[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$SkipServer,
    [switch]$SkipCoreBuild,
    [switch]$SkipApkBuild,
    [string]$DeviceAddress,
    [string]$PairingAddress,
    [string]$PairingCode,
    [ValidateSet('', 'Alice', 'Bob')][string]$DevProfile = '',
    [switch]$NoDevPair,
    [switch]$ResetDevState,
    [switch]$Release,
    [switch]$Clean,
    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [ValidateSet('dashboard','plain','json')][string]$Ui = 'dashboard',
    [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal'
)

$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot 'torchat.ps1'
if ($DevProfile -or $NoDevPair) {
    throw 'DevProfile and NoDevPair were removed from the unified build flow. Use the shared runtime pairing flow instead.'
}
if ($PairingAddress) {
    if (-not $PairingCode) { throw 'PairingCode is required with PairingAddress.' }
    & $cli -Command device -Target pair -PairAddress $PairingAddress -PairCode $PairingCode -Ui $Ui -Verbosity $Verbosity
}

$buildPolicy = if ($SkipCoreBuild -and $SkipApkBuild) { 'skip' } elseif ($Rebuild) { 'rebuild' } else { 'smart' }
$clientData = if ($Clean -or $ResetDevState) { 'reset' } else { 'preserve' }
$stackPolicy = if ($SkipServer) { 'skip' } else { 'ensure' }
$parameters = @{
    Command = 'deploy'
    Target = 'android'
    Environment = $Environment
    BuildPolicy = $buildPolicy
    StackPolicy = $stackPolicy
    ClientDataPolicy = $clientData
    OnionPolicy = 'preserve'
    DatabasePolicy = 'preserve'
    Readiness = 'development'
    Ui = $Ui
    Verbosity = $Verbosity
}
if ($Release) { $parameters.Release = $true }
if ($DeviceAddress) { $parameters.Device = $DeviceAddress }
& $cli @parameters
