Set-StrictMode -Version Latest

function Get-TorChatWindowsRunnerProcesses {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    if ($env:OS -ne 'Windows_NT') { return @() }
    $windowsRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'mobile\build\windows'))
    return @(Get-CimInstance Win32_Process -Filter "Name='torchat_mobile.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($windowsRoot, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Get-TorChatWindowsSidecarProcesses {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    if ($env:OS -ne 'Windows_NT') { return @() }
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    return @(Get-CimInstance Win32_Process -Filter "Name='torchat-desktop.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Get-TorChatWindowsTorProcesses {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    if ($env:OS -ne 'Windows_NT') { return @() }
    $dataRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot '.torchat\clients\desktop\tor'))
    return @(Get-CimInstance Win32_Process -Filter "Name='tor.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($dataRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
}

function Stop-TorChatWindowsProcessSet {
    param([AllowEmptyCollection()][object[]]$Processes = @())
    foreach ($process in @($Processes)) {
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    foreach ($process in @($Processes)) {
        try { Wait-Process -Id ([int]$process.ProcessId) -Timeout 5 -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-TorChatWindowsClient {
    param([Parameter(Mandatory = $true)]$Context)
    Stop-TorChatWindowsProcessSet -Processes @(Get-TorChatWindowsRunnerProcesses -RepositoryRoot $Context.RepositoryRoot)
    Stop-TorChatWindowsProcessSet -Processes @(Get-TorChatWindowsSidecarProcesses -RepositoryRoot $Context.RepositoryRoot)
    Stop-TorChatWindowsProcessSet -Processes @(Get-TorChatWindowsTorProcesses -RepositoryRoot $Context.RepositoryRoot)
    for ($attempt = 1; $attempt -le 25; $attempt++) {
        if (@(Get-TorChatWindowsRunnerProcesses -RepositoryRoot $Context.RepositoryRoot).Count -eq 0 -and
            @(Get-TorChatWindowsSidecarProcesses -RepositoryRoot $Context.RepositoryRoot).Count -eq 0 -and
            @(Get-TorChatWindowsTorProcesses -RepositoryRoot $Context.RepositoryRoot).Count -eq 0) {
            return [pscustomobject]@{ State = 'Ready'; Code = 'WINDOWS_STOPPED'; Message = 'Windows runtime tree stopped' }
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Windows runner, sidecar or desktop Tor did not stop cleanly.'
}

function Reset-TorChatWindowsClientState {
    param([Parameter(Mandatory = $true)]$Context)
    [void](Stop-TorChatWindowsClient -Context $Context)
    $root = Join-Path $Context.RepositoryRoot '.torchat\clients\desktop'
    $rootFull = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($name in @('torchat-client-v1.db','torchat-client-v1.db-wal','torchat-client-v1.db-shm','torchat-client-v1.db-journal','identity.key')) {
        $path = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $resolved = [IO.Path]::GetFullPath($path)
        if (-not $resolved.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove path outside desktop client directory: $resolved" }
        Remove-Item -LiteralPath $resolved -Force
    }
    [pscustomobject]@{ State = 'Ready'; Code = 'WINDOWS_STATE_RESET'; Message = 'Desktop client database and identity reset' }
}

function Get-TorChatEmbeddedTor {
    param([Parameter(Mandatory = $true)]$Context)
    $manifestPath = Join-Path $Context.RepositoryRoot 'infra\config\desktop-tor-packages.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Desktop Tor package manifest missing: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $isLinux = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)
    if ($architecture -ne [Runtime.InteropServices.Architecture]::X64) { throw "Embedded Tor supports x86_64 only; detected $architecture." }
    $platform = if ($isLinux) { 'linux-x86_64' } else { 'windows-x86_64' }
    $package = $manifest.packages.$platform
    if (-not $package) { throw "No embedded Tor package configured for $platform." }

    $cacheRoot = Join-Path $Context.RepositoryRoot "tmp\tools\tor\$($manifest.version)\$platform"
    $archive = Join-Path $cacheRoot 'tor-expert-bundle.tar.gz'
    $extractRoot = Join-Path $cacheRoot 'bundle'
    $binary = Join-Path $extractRoot ($package.binary -replace '/', [IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    if (-not (Test-Path -LiteralPath $archive)) {
        Write-TorChatInfo "Downloading Tor Expert Bundle $($manifest.version) for $platform"
        Invoke-WebRequest -Uri $package.url -OutFile $archive
    }
    $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($actualHash -ne $package.sha256) { throw "Tor package checksum mismatch. Expected $($package.sha256), got $actualHash." }
    if (-not (Test-Path -LiteralPath $binary)) {
        Assert-TorChatTool -Name tar
        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
        [void](Invoke-TorChatNative -Context $Context -FilePath 'tar' -ArgumentList @('-xf',$archive,'-C',$extractRoot) -LogName 'tor-extract.log')
    }
    if (-not (Test-Path -LiteralPath $binary)) { throw "Tor executable missing after extraction: $binary" }
    [pscustomobject]@{
        Binary = (Resolve-Path -LiteralPath $binary).Path
        DataDirectory = Join-Path $Context.RepositoryRoot '.torchat\clients\desktop\tor\data'
        Version = $manifest.tor_version
    }
}

function Save-TorChatWindowsDiagnostics {
    param([Parameter(Mandatory = $true)]$Context)
    $root = Join-Path $Context.RunDirectory 'windows-diagnostics'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('torchat_mobile.exe','torchat-desktop.exe','tor.exe') } |
        Select-Object Name,ProcessId,ParentProcessId,ExecutablePath,CommandLine |
        Format-List | Out-File -LiteralPath (Join-Path $root 'processes.txt') -Encoding utf8
    return $root
}

function Get-TorChatWindowsApplicationReadiness {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $journalRoot = Join-Path $RepositoryRoot '.torchat\clients\desktop\engine-logs'
    $latest = Get-ChildItem -LiteralPath $journalRoot -Filter 'startup-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) {
        return [pscustomobject]@{ Engine = $false; PeerEndpoint = $false; Ready = $false }
    }
    $events = @(Get-Content -LiteralPath $latest.FullName -ErrorAction SilentlyContinue) |
        ForEach-Object {
            try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        }
    $engineReady = @($events | Where-Object {
        $_.component -eq 'engine' -and $_.message -eq 'client engine actor started for Windows'
    }).Count -gt 0
    $peerEndpointReady = @($events | Where-Object {
        $_.component -eq 'peer' -and $_.eventCode -eq 'peer_endpoint_changed' -and $_.message -match '(?:^|\s)status=Verified(?:\s|$)'
    }).Count -gt 0
    [pscustomobject]@{
        Engine = $engineReady
        PeerEndpoint = $peerEndpointReady
        # The rendezvous relay is connected only while pairing. Normal
        # application readiness requires the local engine and onion endpoint.
        Ready = $engineReady -and $peerEndpointReady
    }
}

function Test-TorChatWindowsApplicationReady {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    return (Get-TorChatWindowsApplicationReadiness -RepositoryRoot $RepositoryRoot).Ready
}

function Start-TorChatWindowsClient {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [ValidateSet('preserve','reset')][string]$ClientDataPolicy = 'preserve',
        [int]$ReadyAttempts = 300,
        [int]$FunctionalReadyAttempts = 180
    )
    if ($env:OS -ne 'Windows_NT') { throw 'Windows client can only be started on Windows.' }
    [void](Stop-TorChatWindowsClient -Context $Context)
    if ($ClientDataPolicy -eq 'reset') { [void](Reset-TorChatWindowsClientState -Context $Context) }
    Import-TorChatEnvironmentState -EnvironmentState $EnvironmentState -RequireOnion

    $tor = Get-TorChatEmbeddedTor -Context $Context
    $profile = if ($Context.Configuration -eq 'release') { 'release' } else { 'debug' }
    $variant = if ($Context.Configuration -eq 'release') { 'Release' } else { 'Debug' }
    $engine = Join-Path $Context.RepositoryRoot "target\$profile\torchat-desktop.exe"
    $runner = Join-Path $Context.RepositoryRoot "mobile\build\windows\x64\runner\$variant\torchat_mobile.exe"
    if (-not (Test-Path -LiteralPath $engine)) { throw "Desktop engine artifact missing: $engine" }
    if (-not (Test-Path -LiteralPath $runner)) { throw "Windows client artifact missing: $runner" }

    $env:TORCHAT_TOR_BINARY = $tor.Binary
    $env:TORCHAT_TOR_DATA_DIR = $tor.DataDirectory
    if ($Context.Environment -eq 'local') {
        $relaySocksPort = [int]$EnvironmentState.Values['TORCHAT_SOCKS_PORT']
        $env:TORCHAT_RELAY_SOCKS5_PROXY = "socks5h://127.0.0.1:$relaySocksPort"
    } else {
        Remove-Item Env:TORCHAT_RELAY_SOCKS5_PROXY -ErrorAction SilentlyContinue
    }
    $env:TORCHAT_DESKTOP_PATH = $engine
    $env:TORCHAT_IDENTITY_FILE = Join-Path $Context.RepositoryRoot '.torchat\clients\desktop\identity.key'
    $env:TORCHAT_LOG_DIR = Join-Path $Context.RepositoryRoot '.torchat\logs'
    $env:TORCHAT_DEPLOY_RUN_ID = $Context.RunId

    $started = Start-Process -FilePath $runner -WorkingDirectory (Split-Path -Parent $runner) -PassThru
    $runners = @()
    $sidecars = @()
    for ($attempt = 1; $attempt -le $ReadyAttempts; $attempt++) {
        Start-Sleep -Milliseconds 500
        $runners = @(Get-TorChatWindowsRunnerProcesses -RepositoryRoot $Context.RepositoryRoot)
        $sidecars = @(Get-TorChatWindowsSidecarProcesses -RepositoryRoot $Context.RepositoryRoot)
        $percent = [Math]::Min(99, [int](100 * $attempt / [Math]::Max(1,$ReadyAttempts)))
        Write-TorChatStageProgress -Context $Context -Name 'Windows runtime' -Percent $percent -Detail "runner=$($runners.Count) sidecar=$($sidecars.Count)"
        if ($started.HasExited) { throw "Windows runner exited with code $($started.ExitCode)." }
        if ($runners.Count -gt 1 -or $sidecars.Count -gt 1) { throw "Duplicate Windows runtime processes detected: runner=$($runners.Count), sidecar=$($sidecars.Count)." }
        if ($runners.Count -eq 1 -and $sidecars.Count -eq 1) { break }
    }
    if ($runners.Count -ne 1 -or $sidecars.Count -ne 1) {
        $diagnostics = Save-TorChatWindowsDiagnostics -Context $Context
        throw "Windows did not reach runtime readiness. Diagnostics: $diagnostics"
    }
    $applicationReadiness = $null
    $applicationReady = $false
    for ($attempt = 1; $attempt -le $FunctionalReadyAttempts; $attempt++) {
        $applicationReadiness = Get-TorChatWindowsApplicationReadiness -RepositoryRoot $Context.RepositoryRoot
        $applicationReady = $applicationReadiness.Ready
        $percent = [Math]::Min(99, [int](100 * $attempt / [Math]::Max(1,$FunctionalReadyAttempts)))
        Write-TorChatStageProgress -Context $Context -Name 'Windows application readiness' -Percent $percent -Detail "engine=$($applicationReadiness.Engine) p2p=$($applicationReadiness.PeerEndpoint)"
        if ($applicationReady) { break }
        if ($started.HasExited) { throw "Windows runner exited with code $($started.ExitCode)." }
        Start-Sleep -Seconds 1
    }
    if (-not $applicationReady) {
        $diagnostics = Save-TorChatWindowsDiagnostics -Context $Context
        throw "Windows processes started, but the engine/onion endpoint did not reach APPLICATION_READY. Diagnostics: $diagnostics"
    }
    $runnerPid = [int]$runners[0].ProcessId
    $sidecarPid = [int]$sidecars[0].ProcessId
    Start-Sleep -Seconds 5
    $stableRunners = @(Get-TorChatWindowsRunnerProcesses -RepositoryRoot $Context.RepositoryRoot)
    $stableSidecars = @(Get-TorChatWindowsSidecarProcesses -RepositoryRoot $Context.RepositoryRoot)
    if ($stableRunners.Count -ne 1 -or [int]$stableRunners[0].ProcessId -ne $runnerPid -or
        $stableSidecars.Count -ne 1 -or [int]$stableSidecars[0].ProcessId -ne $sidecarPid) {
        $diagnostics = Save-TorChatWindowsDiagnostics -Context $Context
        throw "Windows runtime was not stable for five seconds. Diagnostics: $diagnostics"
    }
    [pscustomobject]@{ State = 'Ready'; Code = 'WINDOWS_READY'; Message = "Windows application ready (runner $runnerPid, sidecar $sidecarPid)"; RunnerPid = $runnerPid; SidecarPid = $sidecarPid }
}

function Get-TorChatWindowsStatus {
    param([Parameter(Mandatory = $true)]$Context)
    $runners = @(Get-TorChatWindowsRunnerProcesses -RepositoryRoot $Context.RepositoryRoot)
    $sidecars = @(Get-TorChatWindowsSidecarProcesses -RepositoryRoot $Context.RepositoryRoot)
    $tors = @(Get-TorChatWindowsTorProcesses -RepositoryRoot $Context.RepositoryRoot)
    $ready = $runners.Count -eq 1 -and $sidecars.Count -eq 1 -and
        (Test-TorChatWindowsApplicationReady -RepositoryRoot $Context.RepositoryRoot)
    [pscustomobject]@{
        State = if ($ready) { 'Ready' } else { 'Warning' }
        Code = if ($ready) { 'WINDOWS_RUNNING' } else { 'WINDOWS_NOT_READY' }
        Message = "runner=$($runners.Count) sidecar=$($sidecars.Count) tor=$($tors.Count)"
        Runners = $runners
        Sidecars = $sidecars
        Tor = $tors
    }
}

Export-ModuleMember -Function @(
    'Get-TorChatWindowsRunnerProcesses','Get-TorChatWindowsSidecarProcesses','Get-TorChatWindowsTorProcesses',
    'Stop-TorChatWindowsClient','Reset-TorChatWindowsClientState','Get-TorChatEmbeddedTor','Start-TorChatWindowsClient','Get-TorChatWindowsStatus','Save-TorChatWindowsDiagnostics'
)
