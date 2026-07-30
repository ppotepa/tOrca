[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [ValidateSet('clean','preserve')][string]$ClientState = 'preserve',
    [switch]$Release,
    [switch]$Clean,
    [switch]$SkipEnvironmentStart,
    [int]$ReadyAttempts = 40,
    [ValidateSet('dashboard','plain','json')][string]$Ui = 'dashboard',
    [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal'
)

$ErrorActionPreference = 'Stop'
$clientData = if ($Clean -or $ClientState -eq 'clean') { 'reset' } else { 'preserve' }
$parameters = @{
    Command = 'run'
    Target = 'windows'
    Environment = $Environment
    ClientDataPolicy = $clientData
    ReadyAttempts = $ReadyAttempts
    Ui = $Ui
    Verbosity = $Verbosity
}
if ($Release) { $parameters.Release = $true }
if ($SkipEnvironmentStart) { $parameters.SkipEnvironmentStart = $true }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
