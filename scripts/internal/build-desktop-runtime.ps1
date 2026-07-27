[CmdletBinding()]
param([switch]$Release)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot
try {
    $profile = if ($Release) { 'release' } else { 'debug' }
    cargo build -p torchat-desktop --$profile
    if ($LASTEXITCODE -ne 0) { throw 'Rust desktop runtime build failed.' }
    $isWindowsHost = $env:OS -eq 'Windows_NT'
    $name = if ($isWindowsHost) { 'torchat-desktop.exe' } else { 'torchat-desktop' }
    $source = Join-Path $repoRoot "target\$profile\$name"
    if (-not (Test-Path -LiteralPath $source)) { throw "Runtime binary missing: $source" }
    Write-Host "[torchat] Desktop runtime ready: $source"
    return (Resolve-Path -LiteralPath $source).Path
} finally { Pop-Location }
