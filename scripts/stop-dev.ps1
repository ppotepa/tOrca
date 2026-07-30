[CmdletBinding()]
param(
    [ValidateSet('local')][string]$Environment = 'local',
    [ValidateSet('dashboard','plain','json')][string]$Ui = 'dashboard',
    [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal'
)

$ErrorActionPreference = 'Stop'
$parameters = @{
    Command = 'stack'
    Target = 'stop'
    Environment = $Environment
    Ui = $Ui
    Verbosity = $Verbosity
}
& (Join-Path $PSScriptRoot 'torchat.ps1') @parameters
