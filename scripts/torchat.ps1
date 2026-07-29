[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'build-clients',
        'deploy-mobile',
        'run-desktop',
        'full-deploy',
        'redeploy',
        'logs',
        'test',
        'reset-client-state',
        'status',
        'start-dev',
        'stop-dev'
    )]
    [string]$Command = 'status',
    [Parameter(Position = 1)][ValidateSet('up','down','status')][string]$Action = 'status',
    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [ValidateSet('android','windows','all')][string]$Target = 'all',
    [ValidateSet('client','server','all')][string]$Scope = 'client',
    [switch]$Confirm,
    [switch]$NoCache,
    [switch]$SkipMobileBuild,
    [switch]$Release,
    [switch]$Incremental,
    [switch]$Clean,
    [switch]$SkipEnvironmentStart,
    [ValidateSet('preserve','clean')][string]$ClientState = 'preserve',
    [string]$DeviceAddress
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'internal\environment.ps1')

function Invoke-TorChat {
    param([string]$Script, [hashtable]$Parameters = @{})
    $scriptPath = Join-Path $PSScriptRoot $Script
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
        foreach ($entry in $Parameters.GetEnumerator()) {
            $args += "-$($entry.Key)"
            if ($entry.Value -isnot [switch] -and $entry.Value -isnot [bool]) {
                $args += [string]$entry.Value
            } elseif ([bool]$entry.Value) {
                # Switches are represented by presence only.
            } else {
                $args = $args[0..($args.Count - 2)]
            }
        }
        & $pwsh.Source @args
    } else {
        & $scriptPath @Parameters
    }
    if (-not $?) { throw "$Script failed." }
}

function Assert-TorChatTool([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Missing required tool: $Name" }
}

function Show-TorChatStatus($state) {
    Write-Host "[torchat] environment: $Environment"
    Write-Host "[torchat] onion: $($state.Values['TORCHAT_ONION_URL'])"
    if ($Environment -eq 'local') {
        $compose = Join-Path $repoRoot 'infra\docker\compose.dev.yml'
        & docker @('compose','--project-name',$state.Values['TORCHAT_COMPOSE_PROJECT'],'--env-file',$state.Paths.RuntimeEnvironment,'-f',$compose,'ps')
    }
    Write-Host '[torchat] ADB devices:'
    if (Get-Command adb -ErrorAction SilentlyContinue) { adb devices }
}

function Clear-TorChatDesktopState {
    $repoPath = [IO.Path]::GetFullPath($repoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    $running = @(Get-CimInstance Win32_Process -Filter "Name='torchat-desktop.exe'" |
        Where-Object {
            $_.ExecutablePath -and
            ([IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith(
                $repoPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        })
    foreach ($process in $running) {
        Write-Host "[torchat] Stopping desktop runtime PID $($process.ProcessId) before clearing state."
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 300 }
    $clientRoot = Join-Path $repoRoot '.torchat\clients\desktop'
    $identityFile = Join-Path $clientRoot 'identity.key'
    $files = @(
        (Join-Path $clientRoot 'torchat-client-v1.db'),
        (Join-Path $clientRoot 'torchat-client-v1.db-wal'),
        (Join-Path $clientRoot 'torchat-client-v1.db-shm'),
        $identityFile
    )
    foreach ($file in $files) {
        if (Test-Path -LiteralPath $file) {
            $resolved = [IO.Path]::GetFullPath($file)
            $clientRootPath = [IO.Path]::GetFullPath($clientRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
                [IO.Path]::DirectorySeparatorChar
            if (-not $resolved.StartsWith($clientRootPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove path outside desktop client state directory: $resolved"
            }
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                try {
                    Remove-Item -LiteralPath $file -Force -ErrorAction Stop
                    break
                } catch {
                    if ($attempt -eq 5) { throw }
                    Start-Sleep -Milliseconds 250
                }
            }
        }
    }
    $remaining = @($files | Where-Object { Test-Path -LiteralPath $_ })
    if ($remaining.Count -gt 0) {
        throw "Desktop client state reset is incomplete: $($remaining -join ', ')"
    }
    Write-Host '[torchat] Cleared desktop client identity and developer local engine state.'
}

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

$operation = $Command
$operationAction = $Action
$operationTarget = $Target
$operationScope = $Scope

switch ($Command) {
    'start-dev' { $operation = 'env'; $operationAction = 'up' }
    'stop-dev' { $operation = 'env'; $operationAction = 'down' }
    'deploy-mobile' { $operation = 'deploy'; $operationTarget = 'android' }
    'run-desktop' { $operation = 'run'; $operationTarget = 'windows' }
    'build-clients' { $operation = 'build' }
    'reset-client-state' { $operation = 'reset'; $operationScope = 'client' }
    'full-deploy' { $operation = 'full' }
    'redeploy' { $operation = 'redeploy' }
    'logs' { $operation = 'logs' }
}

$state = Ensure-TorChatEnvironment $repoRoot $Environment

switch ($operation) {
    'status' { Show-TorChatStatus $state }
    'env' {
        if ($Environment -ne 'local') {
            if ($operationAction -ne 'status') { throw "Only local Docker is controlled from this workstation. '$Environment' is managed on its Linux host." }
            Import-TorChatEnvironment $state -RequireOnion
            Show-TorChatStatus $state
            break
        }
        if ($operationAction -eq 'up') { Invoke-TorChat 'start-dev.ps1' @{ Rebuild = $false; Environment = 'local' } }
        elseif ($operationAction -eq 'down') { Invoke-TorChat 'stop-dev.ps1' @{ Environment = 'local' } }
        else { Show-TorChatStatus $state }
    }
    'build' {
        if ($Environment -eq 'local') { Invoke-TorChat 'start-dev.ps1' @{ Rebuild = $true; ForceRecreate = $true; NoCache = $NoCache; Environment = 'local' } }
        $arguments = @{ Environment = $Environment; Target = $operationTarget }
        if ($Release -or $Environment -ne 'local') { $arguments.Release = $true }
        Invoke-TorChat 'internal\build-clients.ps1' $arguments
    }
    'deploy' {
        if ($operationTarget -ne 'android') { throw 'deploy currently supports only Android; use run --target windows for desktop.' }
        if ($Environment -eq 'local') { Invoke-TorChat 'start-dev.ps1' @{ Environment = 'local'; SkipOnionHealth = $true } }
        $arguments = @{ SkipServer = $true; Environment = $Environment; Release = ($Release -or $Environment -ne 'local'); Clean = $Clean }
        if ($DeviceAddress) { $arguments.DeviceAddress = $DeviceAddress }
        Invoke-TorChat 'deploy-android.ps1' $arguments
    }
    'run' {
        if ($operationTarget -ne 'windows') { throw 'run currently supports the Windows Flutter target.' }
        if ($Environment -eq 'local' -and -not $SkipEnvironmentStart) {
            Invoke-TorChat 'start-dev.ps1' @{ Environment = 'local'; SkipOnionHealth = $true }
        }
        Stop-TorChatFlutterWindows
        if ($Clean) { Clear-TorChatDesktopState }
        Import-TorChatEnvironment $state -RequireOnion
        Invoke-TorChat 'internal\build-desktop-runtime.ps1' @{ Release = $true }
        $tor = & (Join-Path $PSScriptRoot 'internal\ensure-desktop-tor.ps1') $repoRoot
        $env:TORCHAT_TOR_BINARY = $tor.Binary
        $env:TORCHAT_TOR_DATA_DIR = $tor.DataDirectory
        $env:TORCHAT_RUNTIME_PATH = Join-Path $repoRoot 'target\release\torchat-desktop.exe'
        $env:TORCHAT_IDENTITY_FILE = Join-Path $repoRoot '.torchat\clients\desktop\identity.key'
        $env:TORCHAT_LOG_DIR = Join-Path $repoRoot '.torchat\logs'
        $variant = if ($Release) { 'Release' } else { 'Debug' }
        $desktopClient = Join-Path $repoRoot "mobile\build\windows\x64\runner\$variant\torchat_mobile.exe"
        if (-not (Test-Path -LiteralPath $desktopClient)) {
            Invoke-TorChat 'internal\build-clients.ps1' @{
                Environment = $Environment
                Target = 'windows'
                Release = $Release
            }
        }
        if (-not (Test-Path -LiteralPath $desktopClient)) {
            throw "Flutter Windows executable was not produced: $desktopClient"
        }
        Start-Process -FilePath $desktopClient -WorkingDirectory (Split-Path -Parent $desktopClient)
        Write-Host "[torchat] Windows desktop started: $desktopClient"
    }
    'full' {
        $arguments = @{
            Environment = $Environment
            Release = $Release
            Incremental = $Incremental
            Clean = $Clean
            ClientState = $ClientState
            NoCache = $NoCache
            SkipMobileBuild = $SkipMobileBuild
        }
        if ($DeviceAddress) { $arguments.DeviceAddress = $DeviceAddress }
        Invoke-TorChat 'full-deploy.ps1' $arguments
    }
    'redeploy' {
        $redeployClientState = if ($PSBoundParameters.ContainsKey('ClientState')) {
            $ClientState
        } else {
            'clean'
        }
        $arguments = @{
            Environment = $Environment
            ClientState = $redeployClientState
            Release = $Release
            NoCache = $NoCache
        }
        if ($DeviceAddress) { $arguments.DeviceAddress = $DeviceAddress }
        Invoke-TorChat 'redeploy.ps1' $arguments
    }
    'logs' {
        $arguments = @{ Environment = $Environment }
        if ($DeviceAddress) { $arguments.DeviceAddress = $DeviceAddress }
        Invoke-TorChat 'collect-logs.ps1' $arguments
    }
    'test' {
        Push-Location $repoRoot
        try {
            cargo test -p torchat-client-runtime
            if ($LASTEXITCODE -ne 0) { throw 'torchat-client-runtime unit tests failed.' }
        } finally {
            Pop-Location
        }
    }
    'reset' {
        if (-not $Confirm) { throw 'Reset is destructive. Repeat with -Confirm after choosing -Scope client, server or all.' }
        if ($Environment -ne 'local') { throw "Reset for '$Environment' is intentionally unavailable from a workstation." }
        if ($operationScope -in @('server','all')) {
            $project = $state.Values['TORCHAT_COMPOSE_PROJECT']
            $targets = @("${project}_postgres_dev", "${project}_tor_dev")
            foreach ($volume in $targets) {
                $exists = (& docker volume ls --format '{{.Name}}' | Where-Object { $_ -eq $volume })
                if ($exists) { & docker volume rm $volume; if ($LASTEXITCODE -ne 0) { throw "Could not remove local volume $volume" } }
            }
        }
        if ($operationScope -in @('client','all')) {
            Stop-TorChatFlutterWindows
            Clear-TorChatDesktopState
            $devices = @(adb devices 2>$null | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
            if ($devices.Count -ne 1) { throw 'Client reset requires exactly one connected ADB device.' }
            $installed = (& adb -s $devices[0] shell pm path org.torchat.mobile 2>$null | Out-String).Trim()
            if ($installed -match '^package:') {
                & adb -s $devices[0] uninstall org.torchat.mobile
                if ($LASTEXITCODE -ne 0) { throw 'Could not remove TorChat from the selected Android device.' }
            }
            Write-Host '[torchat] Android app identity and encrypted local state were removed.'
        }
    }
}
