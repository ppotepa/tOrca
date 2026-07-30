[CmdletBinding()]
param(
    [ValidateSet('local')][string]$Environment = 'local',
    [string]$DeviceAddress,
    [int]$Tail = 5000,
    [string]$OutputDirectory,
    [switch]$Full,
    [switch]$AllHistory,
    [switch]$IncludeBugreport
)

$ErrorActionPreference = 'Stop'
if ($OutputDirectory) {
    Write-Warning 'The unified collector stores runs under .torchat\runs and exports archives under .torchat\exports; -OutputDirectory is retained only for command compatibility.'
}
if ($Tail -ne 5000 -or $AllHistory -or $IncludeBugreport) {
    Write-Warning 'Tail/AllHistory/IncludeBugreport are compatibility parameters. The new collector captures bounded component diagnostics for the current run.'
}
$action = if ($Full -or $OutputDirectory) { 'export' } else { 'collect' }
$arguments = @('logs', $action, '-Environment', $Environment)
if ($DeviceAddress) { $arguments += @('-Device', $DeviceAddress) }
& (Join-Path $PSScriptRoot 'torchat.ps1') @arguments
