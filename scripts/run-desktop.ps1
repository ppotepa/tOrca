[CmdletBinding()]
param(
    [string]$Nickname = "Bob",
    [string]$IdentityFile,
    [switch]$SkipServer,
    [switch]$Rebuild,
    [switch]$NoDevPair,
    [switch]$ResetDevState,
    [switch]$HeadlessSmoke,
    [string]$HeadlessSend
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$startScript = Join-Path $PSScriptRoot "start-dev.ps1"
. (Join-Path $PSScriptRoot "internal\dev-config.ps1")

if (-not $SkipServer) {
    Write-Host "[torchat] Starting development onion server..."
    & $startScript -Rebuild:$Rebuild
    if ($LASTEXITCODE -ne 0) { throw "Development stack failed to start." }
} else {
    Import-TorChatDevConfig $repoRoot
}

if ([string]::IsNullOrWhiteSpace($IdentityFile)) {
    $IdentityFile = "tmp\bob.key"
}
$identityPath = Join-Path $repoRoot $IdentityFile
$identityParent = Split-Path -Parent $identityPath
New-Item -ItemType Directory -Force -Path $identityParent | Out-Null
Set-Content -LiteralPath $identityPath -Value $env:TORCHAT_DEV_BOB_KEY -NoNewline -Encoding ascii

$alicePath = Join-Path $repoRoot "tmp\alice.key"
Set-Content -LiteralPath $alicePath -Value $env:TORCHAT_DEV_ALICE_KEY -NoNewline -Encoding ascii

if ($ResetDevState) {
    $statePath = [IO.Path]::ChangeExtension($identityPath, "state.db")
    foreach ($candidate in @($statePath, "$statePath-wal", "$statePath-shm")) {
        if (Test-Path -LiteralPath $candidate) {
            Remove-Item -LiteralPath $candidate -Force
        }
    }
    Write-Host "[torchat] Reset desktop Bob local chat state."
}

$tor = & (Join-Path $PSScriptRoot "internal\ensure-desktop-tor.ps1") -RepoRoot $repoRoot
Write-Host "[torchat] Embedded Tor $($tor.Version): $($tor.Binary)"
Write-Host "[torchat] Onion: $env:TORCHAT_ONION_URL"

# A forcibly closed GUI used to leave its managed tor.exe alive. That process
# keeps the shared DataDirectory lock while a new torrc points at another
# SOCKS port, causing an endless 80% connection screen. Remove only an orphan
# whose command line references this exact desktop Tor data directory.
$torrcPath = [IO.Path]::GetFullPath((Join-Path $tor.DataDirectory "torrc.generated"))
$managedTor = Get-CimInstance Win32_Process -Filter "Name = 'tor.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine.IndexOf($torrcPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
    }
foreach ($process in $managedTor) {
    $parent = Get-Process -Id $process.ParentProcessId -ErrorAction SilentlyContinue
    if ($parent -and $parent.ProcessName -eq "torchat-desktop") {
        throw "TorChat desktop is already running (PID $($parent.Id)). Close it before starting another instance."
    }
    Write-Host "[torchat] Stopping orphaned managed Tor process $($process.ProcessId)..."
    Stop-Process -Id $process.ProcessId -Force
    Wait-Process -Id $process.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
}

$cargoArgs = @(
    "run", "-p", "torchat-desktop", "--",
    "--server-url", $env:TORCHAT_ONION_URL,
    "--tor-binary", $tor.Binary,
    "--tor-data-dir", $tor.DataDirectory,
    "--identity-file", $IdentityFile,
    "--nickname", $Nickname
)
if (-not $NoDevPair) {
    $fixture = Join-Path $repoRoot $env:TORCHAT_DEV_FIXTURE
    $cargoArgs += @(
        "--dev-fixture", $fixture,
        "--dev-peer", "derived-from-key",
        "--dev-peer-identity-file", $alicePath,
        "--dev-peer-nickname", "Alice"
    )
}
if ($HeadlessSmoke) {
    $cargoArgs += "--headless-smoke"
}
if (-not [string]::IsNullOrWhiteSpace($HeadlessSend)) {
    $cargoArgs += @("--headless-send", $HeadlessSend)
}

Push-Location $repoRoot
try {
    & cargo @cargoArgs
    if ($LASTEXITCODE -ne 0) { throw "Desktop client exited with code $LASTEXITCODE." }
} finally {
    Pop-Location
}
