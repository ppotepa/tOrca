[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$SkipIfFresh
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'build-cache.ps1')
Push-Location $repoRoot
try {
    $profile = if ($Release) { 'release' } else { 'debug' }
    $onion = $env:TORCHAT_ONION_URL
    if ($onion -notmatch '^https?://[a-z2-7]{56}\.onion$') {
        throw 'TORCHAT_ONION_URL must be a real v3 onion URL before building the desktop client.'
    }
    $binaryName = if ($env:OS -eq 'Windows_NT') { 'torchat-desktop.exe' } else { 'torchat-desktop' }
    $binaryPath = Join-Path $repoRoot "target\$profile\$binaryName"
    if ($SkipIfFresh) {
        $inputHash = Get-TorChatInputHash -RepoRoot $repoRoot -Roots @(
            'Cargo.toml',
            'Cargo.lock',
            'common\client-engine-contract.json',
            'common\torchat-core',
            'common\torchat-client-runtime',
            'common\torchat-client-engine',
            'desktop'
        ) -ExtraValues @(
            "profile=$profile",
            "onion=$onion",
            "os=$env:OS"
        )
        if (Test-TorChatBuildFresh -RepoRoot $repoRoot -Key "desktop-runtime-$profile" -Hash $inputHash -Artifacts @($binaryPath)) {
            Write-Host "[torchat] Desktop engine client unchanged; using $binaryPath"
            return (Resolve-Path -LiteralPath $binaryPath).Path
        }
    }
    if ($env:OS -eq 'Windows_NT' -and (Test-Path -LiteralPath $binaryPath)) {
        $resolvedBinaryPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $binaryPath).Path)
        $running = @(Get-CimInstance Win32_Process -Filter "Name='torchat-desktop.exe'" |
            Where-Object {
                $_.ExecutablePath -and
                [IO.Path]::GetFullPath($_.ExecutablePath).Equals($resolvedBinaryPath, [StringComparison]::OrdinalIgnoreCase)
            })
        foreach ($process in $running) {
            Write-Host "[torchat] Stopping previous desktop engine client (PID $($process.ProcessId)) before rebuild."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        if ($running.Count -gt 0) { Start-Sleep -Milliseconds 1000 }
    }
    if ($env:OS -eq 'Windows_NT') {
        $nativePerlRoots = @(
            'C:\Strawberry\perl\bin',
            'C:\Perl64\bin',
            'C:\Perl\bin'
        )
        $nativePerlRoot = $nativePerlRoots |
            Where-Object { Test-Path -LiteralPath (Join-Path $_ 'perl.exe') } |
            Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($nativePerlRoot)) {
            throw 'Native Windows Perl is required for openssl-sys desktop/MSVC builds. Install Strawberry Perl or add a MSWin32 perl.exe to PATH.'
        }
        $env:PATH = "$nativePerlRoot;$env:PATH"
    }
    $cargoArgs = @('build', '-p', 'torchat-desktop')
    if ($Release) { $cargoArgs += '--release' }
    $previousCompiledOnion = $env:TORCHAT_COMPILED_ONION_URL
    $env:TORCHAT_COMPILED_ONION_URL = $onion
    try { & cargo @cargoArgs } finally { $env:TORCHAT_COMPILED_ONION_URL = $previousCompiledOnion }
    if ($LASTEXITCODE -ne 0) { throw 'Rust desktop engine client build failed.' }
    $isWindowsHost = $env:OS -eq 'Windows_NT'
    $name = if ($isWindowsHost) { 'torchat-desktop.exe' } else { 'torchat-desktop' }
    $source = Join-Path $repoRoot "target\$profile\$name"
    if (-not (Test-Path -LiteralPath $source)) { throw "Desktop engine client binary missing: $source" }
    if ($SkipIfFresh) {
        Set-TorChatBuildFresh -RepoRoot $repoRoot -Key "desktop-runtime-$profile" -Hash $inputHash -Artifacts @($source)
    }
    Write-Host "[torchat] Desktop engine client ready: $source"
    return (Resolve-Path -LiteralPath $source).Path
} finally { Pop-Location }
