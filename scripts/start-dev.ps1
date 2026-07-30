[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$ForceRecreate,
    [switch]$NoCache,
    [switch]$KeepOtherStacks,
    [switch]$SkipOnionHealth,
    [switch]$AllowOnionWarmup,
    [ValidateSet('local')][string]$Environment = 'local',
    [ValidateSet('dashboard','plain','json')][string]$Ui = 'dashboard',
    [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal'
)

$ErrorActionPreference = 'Stop'
if ($KeepOtherStacks) {
    Write-Warning '-KeepOtherStacks is retained for compatibility. The unified stack command only manages the TorChat compose project.'
}
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
    Ui = $Ui
    Verbosity = $Verbosity
}
if ($NoCache) { $parameters.NoCache = $true }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
