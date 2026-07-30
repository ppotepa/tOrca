[CmdletBinding()]
param(
    [ValidateSet('local')][string]$Environment = 'local',
    [ValidateSet('clean','preserve')][string]$ClientState = 'preserve',
    [switch]$Release,
    [switch]$Incremental,
    [switch]$PreserveTor,
    [switch]$NoCache,
    [string]$DeviceAddress
)

$ErrorActionPreference = 'Stop'
$clientData = if ($ClientState -eq 'clean') { 'reset' } else { 'preserve' }
$parameters = @{
    Command = 'deploy'
    Target = 'all'
    Environment = $Environment
    BuildPolicy = 'smart'
    OnionPolicy = 'preserve'
    DatabasePolicy = 'preserve'
    ClientDataPolicy = $clientData
    Readiness = 'development'
}
if ($Release) { $parameters.Release = $true }
if ($NoCache) { $parameters.NoCache = $true }
if ($DeviceAddress) { $parameters.Device = $DeviceAddress }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
