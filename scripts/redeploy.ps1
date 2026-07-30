[CmdletBinding()]
param(
    # Redeploy always handles both clients. Keep the conventional positional
    # `all` accepted so `./redeploy.ps1 all` is not interpreted as an
    # environment name.
    [Parameter(Position = 0)]
    [ValidateSet('all')]
    [string]$Target = 'all',

    [ValidateSet('local')][string]$Environment = 'local',
    [ValidateSet('clean','preserve')][string]$ClientState = 'preserve',
    [switch]$Release,
    [switch]$Incremental,
    [switch]$PreserveTor,
    [switch]$NoCache,
    [string]$DeviceAddress,
    [ValidateSet('dashboard','plain','json')][string]$Ui = 'dashboard',
    [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal'
)

$ErrorActionPreference = 'Stop'
if ($Incremental) {
    Write-Warning '-Incremental is retained for compatibility; smart, state-preserving deploy is already the default.'
}
if ($PreserveTor) {
    Write-Warning '-PreserveTor is retained for compatibility; the unified redeploy preserves the local onion by default.'
}
$clientData = if ($ClientState -eq 'clean') { 'reset' } else { 'preserve' }
$parameters = @{
    Command = 'deploy'
    Target = $Target
    Environment = $Environment
    BuildPolicy = 'smart'
    OnionPolicy = 'preserve'
    DatabasePolicy = 'preserve'
    ClientDataPolicy = $clientData
    Readiness = 'development'
    Ui = $Ui
    Verbosity = $Verbosity
}
if ($Release) { $parameters.Release = $true }
if ($NoCache) { $parameters.NoCache = $true }
if ($DeviceAddress) { $parameters.Device = $DeviceAddress }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
