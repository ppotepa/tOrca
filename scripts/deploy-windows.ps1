[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [switch]$Release,
    [switch]$Incremental,
    [ValidateSet('dashboard','plain','json')][string]$Ui = 'dashboard',
    [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal'
)

$ErrorActionPreference = 'Stop'
$buildPolicy = if ($Incremental) { 'smart' } else { 'rebuild' }
$parameters = @{
    Command = 'build'
    Target = 'windows'
    Environment = $Environment
    BuildPolicy = $buildPolicy
    Ui = $Ui
    Verbosity = $Verbosity
}
if ($Release) { $parameters.Release = $true }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
