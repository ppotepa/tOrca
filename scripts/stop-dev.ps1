[CmdletBinding()]
param([ValidateSet('local')][string]$Environment = 'local')

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'torchat.ps1') stack stop -Environment $Environment
