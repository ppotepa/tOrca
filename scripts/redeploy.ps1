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
$arguments = @(
    'deploy', 'all',
    '-Environment', $Environment,
    '-BuildPolicy', 'smart',
    '-OnionPolicy', 'preserve',
    '-DatabasePolicy', 'preserve',
    '-ClientDataPolicy', $clientData,
    '-Readiness', 'development'
)
if ($Release) { $arguments += '-Release' }
if ($NoCache) { $arguments += '-NoCache' }
if ($DeviceAddress) { $arguments += @('-Device', $DeviceAddress) }
& (Join-Path $PSScriptRoot 'torchat.ps1') @arguments
