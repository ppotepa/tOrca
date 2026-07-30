[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')]
    [string]$Environment = 'local',
    [switch]$Release,
    [switch]$Incremental
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

& (Join-Path $PSScriptRoot 'internal\build-clients.ps1') -Environment $Environment -Target windows -Release:$Release -Smart:$Incremental
if (-not $?) { throw 'Windows client deployment build failed.' }

$variant = if ($Release) { 'Release' } else { 'Debug' }
$desktopClient = Join-Path $repoRoot "mobile\build\windows\x64\runner\$variant\torchat_mobile.exe"
if (-not (Test-Path -LiteralPath $desktopClient)) {
    throw "Flutter Windows executable was not produced: $desktopClient"
}

Write-Host "[torchat] Windows client ready: $desktopClient"
