[CmdletBinding()]
param(
    [string]$DeviceAddress,
    [switch]$ResetDevState,
    [switch]$Clean,
    [switch]$SkipEnvironmentStart,
    [int]$ReadyAttempts = 30,
    [ValidateSet('dashboard','plain','json')][string]$Ui = 'dashboard',
    [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal'
)

$ErrorActionPreference = 'Stop'
$clientData = if ($ResetDevState -or $Clean) { 'reset' } else { 'preserve' }
$parameters = @{
    Command = 'run'
    Target = 'android'
    ClientDataPolicy = $clientData
    ReadyAttempts = $ReadyAttempts
    Ui = $Ui
    Verbosity = $Verbosity
}
if ($DeviceAddress) { $parameters.Device = $DeviceAddress }
if ($SkipEnvironmentStart) { $parameters.SkipEnvironmentStart = $true }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
