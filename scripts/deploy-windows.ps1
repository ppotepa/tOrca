[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [switch]$Release,
    [switch]$Incremental
)

$ErrorActionPreference = 'Stop'
$buildPolicy = if ($Incremental) { 'smart' } else { 'rebuild' }
$parameters = @{
    Command = 'build'
    Target = 'windows'
    Environment = $Environment
    BuildPolicy = $buildPolicy
}
if ($Release) { $parameters.Release = $true }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
