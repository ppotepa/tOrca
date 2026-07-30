[CmdletBinding()]
param(
    [ValidateSet('local','staging','production')]
    [string]$Environment = 'local',
    [ValidateSet('clean','preserve')]
    [string]$ClientState = 'preserve',
    [switch]$Release,
    [switch]$Clean,
    [switch]$SkipEnvironmentStart,
    [int]$ReadyAttempts = 40
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$deployRunId = if ($env:TORCHAT_DEPLOY_RUN_ID) { $env:TORCHAT_DEPLOY_RUN_ID } else { [Guid]::NewGuid().ToString('N') }
$env:TORCHAT_DEPLOY_RUN_ID = $deployRunId
. (Join-Path $PSScriptRoot 'internal\environment.ps1')

function Get-RepoProcesses {
    param([string]$Name)
    $repoPath = [IO.Path]::GetFullPath($repoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    return @(Get-CimInstance Win32_Process -Filter "Name='$Name'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            ([IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($repoPath, [StringComparison]::OrdinalIgnoreCase)
        })
}

function Get-FlutterProcesses {
    $windowsRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'mobile\build\windows'))
    return @(Get-CimInstance Win32_Process -Filter "Name='torchat_mobile.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            ([IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($windowsRoot, [StringComparison]::OrdinalIgnoreCase)
        })
}

function Stop-ProcessSet {
    param([array]$Processes, [string]$Label)
    foreach ($process in $Processes) {
        Write-Host "[torchat] deployRunId=$deployRunId state=stopping role=$Label pid=$($process.ProcessId)"
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    foreach ($process in $Processes) {
        try { Wait-Process -Id ([int]$process.ProcessId) -Timeout 5 -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-TorChatRuntimeTree {
    Stop-ProcessSet -Processes @(Get-FlutterProcesses) -Label 'windows-runner'
    Stop-ProcessSet -Processes @(Get-RepoProcesses -Name 'torchat-desktop.exe') -Label 'desktop-engine'

    $torDataRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.torchat\clients\desktop\tor'))
    $torProcesses = @(Get-CimInstance Win32_Process -Filter "Name='tor.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and $_.CommandLine.IndexOf($torDataRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
    Stop-ProcessSet -Processes $torProcesses -Label 'desktop-tor'

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        if (@(Get-FlutterProcesses).Count -eq 0 -and @(Get-RepoProcesses -Name 'torchat-desktop.exe').Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 150
    }
    throw 'Previous Windows TorChat runtime tree did not stop cleanly.'
}

function Clear-TorChatDesktopState {
    $clientRoot = Join-Path $repoRoot '.torchat\clients\desktop'
    $clientRootPath = [IO.Path]::GetFullPath($clientRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    $files = @(
        (Join-Path $clientRoot 'torchat-client-v1.db'),
        (Join-Path $clientRoot 'torchat-client-v1.db-wal'),
        (Join-Path $clientRoot 'torchat-client-v1.db-shm'),
        (Join-Path $clientRoot 'torchat-client-v1.db-journal'),
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
    Write-Host '[torchat] Cleared desktop client state by explicit request.'
}

function Save-WindowsLaunchDiagnostics {
    param([string]$RunId)
    $root = Join-Path $repoRoot ".torchat\command-logs\windows-launch-$RunId"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('torchat_mobile.exe','torchat-desktop.exe','tor.exe') } |
        Select-Object Name, ProcessId, ParentProcessId, ExecutablePath, CommandLine |
        Format-List | Out-File -LiteralPath (Join-Path $root 'processes.txt') -Encoding utf8
    $latestLogs = Join-Path $repoRoot '.torchat\logs'
    if (Test-Path -LiteralPath $latestLogs) {
        Get-ChildItem -LiteralPath $latestLogs -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 20 FullName, Length, LastWriteTime |
            Format-Table -AutoSize | Out-File -LiteralPath (Join-Path $root 'recent-logs.txt') -Encoding utf8
    }
    Write-Warning "Windows launch diagnostics saved to $root"
}

$state = Ensure-TorChatEnvironment $repoRoot $Environment
if ($Environment -eq 'local' -and -not $SkipEnvironmentStart) {
    & (Join-Path $PSScriptRoot 'start-dev.ps1') -Environment local -SkipOnionHealth
    if (-not $?) { throw 'Local development stack failed to start.' }
}

try {
    Stop-TorChatRuntimeTree
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
    $env:TORCHAT_DEPLOY_RUN_ID = $deployRunId

    $variant = if ($Release) { 'Release' } else { 'Debug' }
    $desktopClient = Join-Path $repoRoot "mobile\build\windows\x64\runner\$variant\torchat_mobile.exe"
    if (-not (Test-Path -LiteralPath $desktopClient)) {
        & (Join-Path $PSScriptRoot 'deploy-windows.ps1') -Environment $Environment -Release:$Release
        if (-not $?) { throw 'Windows client deployment failed.' }
    }
    if (-not (Test-Path -LiteralPath $desktopClient)) {
        throw "Flutter Windows executable was not produced: $desktopClient"
    }

    $runner = Start-Process -FilePath $desktopClient -WorkingDirectory (Split-Path -Parent $desktopClient) -PassThru
    $runnerProcesses = @()
    $sidecarProcesses = @()
    for ($attempt = 1; $attempt -le $ReadyAttempts; $attempt++) {
        Start-Sleep -Milliseconds 500
        $runnerProcesses = @(Get-FlutterProcesses)
        $sidecarProcesses = @(Get-RepoProcesses -Name 'torchat-desktop.exe')
        if ($runnerProcesses.Count -eq 1 -and $sidecarProcesses.Count -eq 1) { break }
        if ($runner.HasExited) { throw "Windows Flutter runner exited with code $($runner.ExitCode)." }
        if ($runnerProcesses.Count -gt 1 -or $sidecarProcesses.Count -gt 1) {
            throw "Multiple Windows runtime processes detected (runner=$($runnerProcesses.Count), sidecar=$($sidecarProcesses.Count))."
        }
    }

    if ($runnerProcesses.Count -ne 1) { throw "Expected one Windows runner, found $($runnerProcesses.Count)." }
    if ($sidecarProcesses.Count -ne 1) { throw "Expected one desktop sidecar, found $($sidecarProcesses.Count)." }

    $runnerPid = [int]$runnerProcesses[0].ProcessId
    $sidecarPid = [int]$sidecarProcesses[0].ProcessId
    Start-Sleep -Seconds 5
    $stableRunners = @(Get-FlutterProcesses)
    $stableSidecars = @(Get-RepoProcesses -Name 'torchat-desktop.exe')
    if ($stableRunners.Count -ne 1 -or [int]$stableRunners[0].ProcessId -ne $runnerPid) {
        throw 'Windows runner was not stable for five seconds after launch.'
    }
    if ($stableSidecars.Count -ne 1 -or [int]$stableSidecars[0].ProcessId -ne $sidecarPid) {
        throw 'Desktop sidecar was not stable for five seconds after launch.'
    }

    Write-Host "[torchat] Windows APP_READY deployRunId=$deployRunId runnerPid=$runnerPid sidecarPid=$sidecarPid"
    Write-Host '[torchat] Windows engine process is stable; Tor and relay readiness remain visible in the application status center.'
} catch {
    Save-WindowsLaunchDiagnostics -RunId $deployRunId
    throw
}
