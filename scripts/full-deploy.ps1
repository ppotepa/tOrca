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
$parameters = @{
    Command = 'deploy'
    Target = 'all'
    Environment = $Environment
    BuildPolicy = $buildPolicy
    OnionPolicy = 'preserve'
    DatabasePolicy = 'preserve'
    ClientDataPolicy = $clientData
    Readiness = 'development'
}
if ($Release) { $parameters.Release = $true }
if ($NoCache) { $parameters.NoCache = $true }
if ($DeviceAddress) { $parameters.Device = $DeviceAddress }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
