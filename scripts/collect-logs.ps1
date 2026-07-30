[CmdletBinding()]
param(
    [ValidateSet('local')][string]$Environment = 'local',
    [string]$DeviceAddress,
    [int]$Tail = 5000,
    [string]$OutputDirectory,
    [switch]$Full,
    [switch]$AllHistory,
    [switch]$IncludeBugreport,
    [ValidateSet('dashboard','plain','json')][string]$Ui = 'dashboard',
    [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal'
)

$ErrorActionPreference = 'Stop'
if ($OutputDirectory) {
    Write-Warning 'The unified collector stores runs under .torchat\runs and exports archives under .torchat\exports; -OutputDirectory is retained only for command compatibility.'
}
if ($Tail -ne 5000 -or $AllHistory -or $IncludeBugreport) {
    Write-Warning 'Tail/AllHistory/IncludeBugreport are compatibility parameters. The new collector captures bounded component diagnostics for the current run.'
}
$action = if ($Full -or $OutputDirectory) { 'export' } else { 'collect' }
$parameters = @{
    Command = 'logs'
    Target = $action
    Environment = $Environment
    Ui = $Ui
    Verbosity = $Verbosity
}
if ($DeviceAddress) { $parameters.Device = $DeviceAddress }
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
