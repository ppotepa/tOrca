[CmdletBinding()]
param([switch]$Release)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot
try {
    $profile = if ($Release) { 'release' } else { 'debug' }
    $onion = $env:TORCHAT_ONION_URL
    if ($onion -notmatch '^https?://[a-z2-7]{56}\.onion$') {
        throw 'TORCHAT_ONION_URL must be a real v3 onion URL before building the desktop client.'
    }
    $binaryName = if ($env:OS -eq 'Windows_NT') { 'torchat-desktop.exe' } else { 'torchat-desktop' }
    $binaryPath = Join-Path $repoRoot "target\$profile\$binaryName"
    if ($env:OS -eq 'Windows_NT' -and (Test-Path -LiteralPath $binaryPath)) {
        $resolvedBinaryPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $binaryPath).Path)
        $running = @(Get-CimInstance Win32_Process -Filter "Name='torchat-desktop.exe'" |
            Where-Object {
                $_.ExecutablePath -and
                [IO.Path]::GetFullPath($_.ExecutablePath).Equals($resolvedBinaryPath, [StringComparison]::OrdinalIgnoreCase)
            })
        foreach ($process in $running) {
            Write-Host "[torchat] Stopping previous desktop runtime (PID $($process.ProcessId)) before rebuild."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        if ($running.Count -gt 0) { Start-Sleep -Milliseconds 1000 }
    }
    $cargoArgs = @('build', '-p', 'torchat-desktop')
    if ($Release) { $cargoArgs += '--release' }
    $previousCompiledOnion = $env:TORCHAT_COMPILED_ONION_URL
    $env:TORCHAT_COMPILED_ONION_URL = $onion
    try { & cargo @cargoArgs } finally { $env:TORCHAT_COMPILED_ONION_URL = $previousCompiledOnion }
    if ($LASTEXITCODE -ne 0) { throw 'Rust desktop runtime build failed.' }
    $isWindowsHost = $env:OS -eq 'Windows_NT'
    $name = if ($isWindowsHost) { 'torchat-desktop.exe' } else { 'torchat-desktop' }
    $source = Join-Path $repoRoot "target\$profile\$name"
    if (-not (Test-Path -LiteralPath $source)) { throw "Runtime binary missing: $source" }
    Write-Host "[torchat] Desktop runtime ready: $source"
    return (Resolve-Path -LiteralPath $source).Path
} finally { Pop-Location }
