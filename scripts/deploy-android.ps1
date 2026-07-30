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
    [ValidateSet('local','staging','production')][string]$Environment = 'local'
)

$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot 'torchat.ps1'
if ($PairingAddress) {
    if (-not $PairingCode) { throw 'PairingCode is required with PairingAddress.' }
    & $cli device pair -PairAddress $PairingAddress -PairCode $PairingCode
}

$buildPolicy = if ($SkipCoreBuild -and $SkipApkBuild) { 'skip' } elseif ($Rebuild) { 'rebuild' } else { 'smart' }
$clientData = if ($Clean -or $ResetDevState) { 'reset' } else { 'preserve' }
$stackPolicy = if ($SkipServer) { 'skip' } else { 'ensure' }
$arguments = @(
    'deploy', 'android',
    '-Environment', $Environment,
    '-BuildPolicy', $buildPolicy,
    '-StackPolicy', $stackPolicy,
    '-ClientDataPolicy', $clientData,
    '-OnionPolicy', 'preserve',
    '-DatabasePolicy', 'preserve',
    '-Readiness', 'development'
)
if ($Release) { $arguments += '-Release' }
if ($DeviceAddress) { $arguments += @('-Device', $DeviceAddress) }
& $cli @arguments
