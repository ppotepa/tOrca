[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [switch]$Release,
    [switch]$Incremental,
    [switch]$Clean,
    [ValidateSet('preserve','clean')][string]$ClientState = 'preserve',
    [switch]$NoCache,
    [switch]$SkipMobileBuild,
    [string]$DeviceAddress
)

$ErrorActionPreference = 'Stop'
$clientData = if ($Clean -or $ClientState -eq 'clean') { 'reset' } else { 'preserve' }
$buildPolicy = if ($SkipMobileBuild) { 'skip' } elseif ($Incremental) { 'smart' } else { 'rebuild' }
$arguments = @(
    'deploy', 'all',
    '-Environment', $Environment,
    '-BuildPolicy', $buildPolicy,
    '-OnionPolicy', 'preserve',
    '-DatabasePolicy', 'preserve',
    '-ClientDataPolicy', $clientData,
    '-Readiness', 'development'
)
if ($Release) { $arguments += '-Release' }
if ($NoCache) { $arguments += '-NoCache' }
if ($DeviceAddress) { $arguments += @('-Device', $DeviceAddress) }
& (Join-Path $PSScriptRoot 'torchat.ps1') @arguments
