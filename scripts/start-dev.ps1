[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$ForceRecreate,
    [switch]$NoCache,
    [switch]$KeepOtherStacks,
    [switch]$SkipOnionHealth,
    [switch]$AllowOnionWarmup,
    [ValidateSet('local')][string]$Environment = 'local'
)

$ErrorActionPreference = 'Stop'
$action = if ($ForceRecreate) { 'restart' } else { 'start' }
$buildPolicy = if ($Rebuild) { 'rebuild' } else { 'smart' }
$readiness = if ($SkipOnionHealth -or $AllowOnionWarmup) { 'development' } else { 'onion' }
$parameters = @{
    Command = 'stack'
    Target = $action
    Environment = $Environment
    BuildPolicy = $buildPolicy
    OnionPolicy = 'preserve'
    DatabasePolicy = 'preserve'
    Readiness = $readiness
}
if ($NoCache) { $parameters.NoCache = $true }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
