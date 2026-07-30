[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [ValidateSet('clean','preserve')][string]$ClientState = 'preserve',
    [switch]$Release,
    [switch]$Clean,
    [switch]$SkipEnvironmentStart,
    [int]$ReadyAttempts = 40
)

$ErrorActionPreference = 'Stop'
$clientData = if ($Clean -or $ClientState -eq 'clean') { 'reset' } else { 'preserve' }
$parameters = @{
    Command = 'run'
    Target = 'windows'
    Environment = $Environment
    ClientDataPolicy = $clientData
}
if ($Release) { $parameters.Release = $true }
if ($SkipEnvironmentStart) { $parameters.SkipEnvironmentStart = $true }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
