[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [switch]$Release,
    [switch]$Incremental
)

$ErrorActionPreference = 'Stop'
$buildPolicy = if ($Incremental) { 'smart' } else { 'rebuild' }
$arguments = @(
    'build', 'windows',
    '-Environment', $Environment,
    '-BuildPolicy', $buildPolicy
)
if ($Release) { $arguments += '-Release' }
& (Join-Path $PSScriptRoot 'torchat.ps1') @arguments
