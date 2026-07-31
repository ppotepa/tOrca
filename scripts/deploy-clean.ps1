[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [switch]$Release,
    [switch]$NoCache,
    [string]$DeviceAddress,
    [ValidateSet('dashboard','plain','json')][string]$Ui = 'dashboard',
    [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal'
)

$ErrorActionPreference = 'Stop'

$parameters = @{
    Command = 'deploy'
    Target = 'all'
    Environment = $Environment
    BuildPolicy = 'rebuild'
    OnionPolicy = 'rotate'
    DatabasePolicy = 'reset'
    ClientDataPolicy = 'reset'
    StackPolicy = 'ensure'
    InstallPolicy = 'always'
    RunPolicy = 'restart'
    Confirm = $true
    Readiness = 'development'
    Ui = $Ui
    Verbosity = $Verbosity
}

if ($Release) { $parameters.Release = $true }
if ($NoCache) { $parameters.NoCache = $true }
if ($DeviceAddress) { $parameters.Device = $DeviceAddress }

& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
