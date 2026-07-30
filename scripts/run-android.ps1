[CmdletBinding()]
param(
    [string]$DeviceAddress,
    [switch]$ResetDevState,
    [switch]$Clean,
    [int]$ReadyAttempts = 30
)

$ErrorActionPreference = 'Stop'
$clientData = if ($ResetDevState -or $Clean) { 'reset' } else { 'preserve' }
$arguments = @(
    'run', 'android',
    '-ClientDataPolicy', $clientData
)
if ($DeviceAddress) { $arguments += @('-Device', $DeviceAddress) }
& (Join-Path $PSScriptRoot 'torchat.ps1') @arguments
