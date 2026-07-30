[CmdletBinding()]
param(
    [string]$DeviceAddress,
    [switch]$ResetDevState,
    [switch]$Clean,
    [int]$ReadyAttempts = 30
)

$ErrorActionPreference = 'Stop'
$clientData = if ($ResetDevState -or $Clean) { 'reset' } else { 'preserve' }
$parameters = @{
    Command = 'run'
    Target = 'android'
    ClientDataPolicy = $clientData
}
if ($DeviceAddress) { $parameters.Device = $DeviceAddress }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
