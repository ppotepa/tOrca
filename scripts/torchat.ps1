[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('doctor','env','build','deploy','run','full','test','ci','reset','status','start','stop','rebuild','deploy-android','desktop','full-deploy')]
    [string]$Command = 'status',
    [Parameter(Position = 1)][ValidateSet('up','down','status')][string]$Action = 'status',
    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [ValidateSet('android','windows','all')][string]$Target = 'all',
    [ValidateSet('client','server','all')][string]$Scope = 'client',
    [switch]$Confirm,
    [switch]$NoCache,
    [switch]$SkipChecks,
    [switch]$SkipMobileBuild,
    [switch]$Release,
    [string]$DeviceAddress
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'internal\environment.ps1')

function Invoke-TorChat {
    param([string]$Script, [hashtable]$Parameters = @{})
    & (Join-Path $PSScriptRoot $Script) @Parameters
    if ($LASTEXITCODE -ne 0) { throw "$Script failed with exit code $LASTEXITCODE." }
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

# Compatibility aliases are intentionally thin; new automation uses the verbs
# above and never relies on implicit dev/release state.
switch ($Command) {
    'start' { $Command = 'env'; $Action = 'up' }
    'stop' { $Command = 'env'; $Action = 'down' }
    'rebuild' { $Command = 'build' }
    'deploy-android' { $Command = 'deploy'; $Target = 'android' }
    'desktop' { $Command = 'run'; $Target = 'windows' }
    'full-deploy' { $Command = 'full' }
}

$state = Ensure-TorChatEnvironment $repoRoot $Environment

switch ($Command) {
    'doctor' {
        Assert-TorChatTool docker
        Assert-TorChatTool cargo
        Assert-TorChatTool flutter
        Assert-TorChatTool adb
        docker info *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop is not running.' }
        Write-Host '[torchat] doctor: Docker, Rust, Flutter and ADB are available.'
        if ($Environment -eq 'local') { & adb mdns services 2>$null | Select-Object -First 20 }
    }
    'status' { Show-TorChatStatus $state }
    'env' {
        if ($Environment -ne 'local') {
            if ($Action -ne 'status') { throw "Only local Docker is controlled from this workstation. '$Environment' is managed on its Linux host." }
            Import-TorChatEnvironment $state -RequireOnion
            Show-TorChatStatus $state
            break
        }
        if ($Action -eq 'up') { Invoke-TorChat 'start-dev.ps1' @{ Rebuild = $false; Environment = 'local' } }
        elseif ($Action -eq 'down') { Invoke-TorChat 'stop-dev.ps1' @{ Environment = 'local' } }
        else { Show-TorChatStatus $state }
    }
    'build' {
        if ($Environment -eq 'local') { Invoke-TorChat 'start-dev.ps1' @{ Rebuild = $true; ForceRecreate = $true; NoCache = $NoCache; Environment = 'local' } }
        $arguments = @{ Environment = $Environment; Target = $Target; SkipChecks = $SkipChecks }
        if ($Release -or $Environment -ne 'local') { $arguments.Release = $true }
        Invoke-TorChat 'internal\build-clients.ps1' $arguments
    }
    'deploy' {
        if ($Target -ne 'android') { throw 'deploy currently supports only Android; use run --target windows for desktop.' }
        if ($Environment -eq 'local') { Invoke-TorChat 'start-dev.ps1' @{ Environment = 'local' } }
        $arguments = @{ SkipServer = $true; Environment = $Environment; Release = ($Release -or $Environment -ne 'local') }
        if ($DeviceAddress) { $arguments.DeviceAddress = $DeviceAddress }
        Invoke-TorChat 'deploy-android.ps1' $arguments
    }
    'run' {
        if ($Target -ne 'windows') { throw 'run currently supports the Windows Flutter target.' }
        if ($Environment -eq 'local') { Invoke-TorChat 'start-dev.ps1' @{ Environment = 'local' } }
        Import-TorChatEnvironment $state -RequireOnion
        Invoke-TorChat 'internal\build-desktop-runtime.ps1' @{ Release = $true }
        $tor = & (Join-Path $PSScriptRoot 'internal\ensure-desktop-tor.ps1') $repoRoot
        $env:TORCHAT_TOR_BINARY = $tor.Binary
        $env:TORCHAT_TOR_DATA_DIR = $tor.DataDirectory
        $env:TORCHAT_RUNTIME_PATH = Join-Path $repoRoot 'target\release\torchat-desktop.exe'
        $env:TORCHAT_IDENTITY_FILE = Join-Path $repoRoot '.torchat\clients\desktop\identity.key'
        Push-Location (Join-Path $repoRoot 'mobile')
        try { flutter run -d windows } finally { Pop-Location }
    }
    'full' {
        if ($Environment -eq 'local') { Invoke-TorChat 'start-dev.ps1' @{ Rebuild = $true; ForceRecreate = $true; NoCache = $NoCache; Environment = 'local' } }
        $build = @{ Environment = $Environment; Target = 'all'; SkipChecks = $SkipChecks }
        if ($Environment -ne 'local') { $build.Release = $true }
        Invoke-TorChat 'internal\build-clients.ps1' $build
        $deploy = @{ SkipServer = $true; SkipCoreBuild = $true; SkipApkBuild = $true; Environment = $Environment; Release = ($Environment -ne 'local') }
        if ($DeviceAddress) { $deploy.DeviceAddress = $DeviceAddress }
        Invoke-TorChat 'deploy-android.ps1' $deploy
        & $PSCommandPath run -Environment $Environment -Target windows
    }
    'test' {
        Invoke-TorChat 'internal\check-sql-isolation.ps1'
        Invoke-TorChat 'internal\build-clients.ps1' @{ Environment = $Environment; Target = 'android'; SkipChecks = $false }
    }
    'ci' {
        if ($Environment -eq 'local') { Invoke-TorChat 'start-dev.ps1' @{ Environment = 'local' } }
        Invoke-TorChat 'internal\build-clients.ps1' @{ Environment = $Environment; Target = 'all'; SkipChecks = $false }
    }
    'reset' {
        if (-not $Confirm) { throw 'Reset is destructive. Repeat with -Confirm after choosing -Scope client, server or all.' }
        if ($Environment -ne 'local') { throw "Reset for '$Environment' is intentionally unavailable from a workstation." }
        if ($Scope -in @('server','all')) {
            $project = $state.Values['TORCHAT_COMPOSE_PROJECT']
            $targets = @("${project}_postgres_dev", "${project}_tor_dev")
            foreach ($volume in $targets) {
                $exists = (& docker volume ls --format '{{.Name}}' | Where-Object { $_ -eq $volume })
                if ($exists) { & docker volume rm $volume; if ($LASTEXITCODE -ne 0) { throw "Could not remove local volume $volume" } }
            }
        }
        if ($Scope -in @('client','all')) {
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
