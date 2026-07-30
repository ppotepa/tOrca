[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')]
    [string]$Environment = 'local',
    [ValidateSet('clean','preserve')]
    [string]$ClientState = 'preserve',
    [switch]$Release,
    [switch]$Clean,
    [switch]$SkipEnvironmentStart
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'internal\environment.ps1')

function Stop-TorChatFlutterWindows {
    $windowsRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'mobile\build\windows'))
    $running = @(Get-CimInstance Win32_Process -Filter "Name='torchat_mobile.exe'" |
        Where-Object {
            $_.ExecutablePath -and
            ([IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($windowsRoot, [StringComparison]::OrdinalIgnoreCase)
        })
    foreach ($process in $running) {
        Write-Host "[torchat] Stopping Flutter Windows client PID $($process.ProcessId) before build/run."
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 300 }
}

function Stop-TorChatDesktopHost {
    $repoPath = [IO.Path]::GetFullPath($repoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    $running = @(Get-CimInstance Win32_Process -Filter "Name='torchat-desktop.exe'" |
        Where-Object {
            $_.ExecutablePath -and
            ([IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($repoPath, [StringComparison]::OrdinalIgnoreCase)
        })
    foreach ($process in $running) {
        Write-Host "[torchat] Stopping desktop engine host PID $($process.ProcessId) before build/run."
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 300 }
}

function Clear-TorChatDesktopState {
    $clientRoot = Join-Path $repoRoot '.torchat\clients\desktop'
    $clientRootPath = [IO.Path]::GetFullPath($clientRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    $files = @(
        (Join-Path $clientRoot 'torchat-client-v1.db'),
        (Join-Path $clientRoot 'torchat-client-v1.db-wal'),
        (Join-Path $clientRoot 'torchat-client-v1.db-shm'),
        (Join-Path $clientRoot 'identity.key')
    )
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $resolved = [IO.Path]::GetFullPath($file)
        if (-not $resolved.StartsWith($clientRootPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove path outside desktop client state directory: $resolved"
        }
        Remove-Item -LiteralPath $file -Force
    }
    Write-Host '[torchat] Cleared desktop client identity and developer local engine state.'
}

$state = Ensure-TorChatEnvironment $repoRoot $Environment
if ($Environment -eq 'local' -and -not $SkipEnvironmentStart) {
    & (Join-Path $PSScriptRoot 'start-dev.ps1') -Environment local -SkipOnionHealth
    if (-not $?) { throw 'Local development stack failed to start.' }
}

Stop-TorChatDesktopHost
Stop-TorChatFlutterWindows
if ($Clean -or $ClientState -eq 'clean') { Clear-TorChatDesktopState }

Import-TorChatEnvironment $state -RequireOnion
& (Join-Path $PSScriptRoot 'internal\build-desktop-runtime.ps1') -Release
if (-not $?) { throw 'Desktop Rust engine client build failed.' }

$tor = & (Join-Path $PSScriptRoot 'internal\ensure-desktop-tor.ps1') $repoRoot
$env:TORCHAT_TOR_BINARY = $tor.Binary
$env:TORCHAT_TOR_DATA_DIR = $tor.DataDirectory
$env:TORCHAT_DESKTOP_PATH = Join-Path $repoRoot 'target\release\torchat-desktop.exe'
$env:TORCHAT_IDENTITY_FILE = Join-Path $repoRoot '.torchat\clients\desktop\identity.key'
$env:TORCHAT_LOG_DIR = Join-Path $repoRoot '.torchat\logs'

$variant = if ($Release) { 'Release' } else { 'Debug' }
$desktopClient = Join-Path $repoRoot "mobile\build\windows\x64\runner\$variant\torchat_mobile.exe"
if (-not (Test-Path -LiteralPath $desktopClient)) {
    & (Join-Path $PSScriptRoot 'deploy-windows.ps1') -Environment $Environment -Release:$Release
    if (-not $?) { throw 'Windows client deployment failed.' }
}
if (-not (Test-Path -LiteralPath $desktopClient)) {
    throw "Flutter Windows executable was not produced: $desktopClient"
}

Start-Process -FilePath $desktopClient -WorkingDirectory (Split-Path -Parent $desktopClient)
Write-Host "[torchat] Windows desktop started: $desktopClient"
