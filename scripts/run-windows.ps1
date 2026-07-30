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
$arguments = @(
    'run', 'windows',
    '-Environment', $Environment,
    '-ClientDataPolicy', $clientData
)
if ($Release) { $arguments += '-Release' }
if ($SkipEnvironmentStart) { $arguments += '-SkipEnvironmentStart' }
& (Join-Path $PSScriptRoot 'torchat.ps1') @arguments
