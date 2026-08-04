[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Target = 'all',

    [ValidateSet('local','staging','production')][string]$Environment = 'local',
    [ValidateSet('debug','release')][string]$Configuration = 'debug',
    [ValidateSet('dashboard','plain','json')][string]$Ui = 'dashboard',
    [ValidateSet('quiet','normal','detailed','trace')][string]$Verbosity = 'normal',

    [ValidateSet('smart','rebuild','skip')][string]$BuildPolicy = 'smart',
    [ValidateSet('preserve','rotate')][string]$OnionPolicy = 'preserve',
    [ValidateSet('preserve','reset')][string]$DatabasePolicy = 'preserve',
    [Alias('ClientState')][ValidateSet('preserve','reset','clean')][string]$ClientDataPolicy = 'preserve',
    [ValidateSet('ensure','skip')][string]$StackPolicy = 'ensure',
    [ValidateSet('if-changed','always','skip')][string]$InstallPolicy = 'if-changed',
    [ValidateSet('restart','start','skip')][string]$RunPolicy = 'restart',
    [ValidateSet('development','onion','strict')][string]$Readiness = 'development',
    [ValidateSet('prompt','emulator','android-desktop')][string]$ClientMode = 'prompt',

    [Alias('DeviceAddress')][string]$Device = 'auto',
    [string]$PairAddress,
    [string]$PairCode,

    [switch]$Release,
    [ValidateRange(0, 600)][int]$ReadyAttempts = 0,
    [switch]$NoCache,
    [switch]$DryRun,
    [switch]$NoColor,
    [switch]$Confirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $PSScriptRoot 'modules'

function Show-TorChatHelp {
    Write-Host @'
TorChat command line

Usage:
  .\scripts\torchat.ps1 <command> <target> [options]

Commands:
  status  [all|stack|android|windows]
  stack   [start|stop|restart|status|reset|repair]
  build   [server|desktop-runtime|android|windows|clients|all]
  deploy  [android|windows|all]
  deploy-clean
  run     [android|windows|all]
  stop    [android|windows|all]
  test    [runtime|flutter|android|windows|all]
  clean   [build|server-data|client-data|all]
  logs    [show|collect|export]
  device  [list|pair|connect|status]

Examples:
  .\scripts\torchat.ps1 deploy all
  .\scripts\torchat.ps1 deploy android -Device auto
  .\scripts\torchat.ps1 deploy all -Device all
  .\scripts\torchat.ps1 deploy all -ClientMode emulator
  .\scripts\torchat.ps1 deploy all -ClientMode android-desktop
  .\scripts\torchat.ps1 deploy-clean
  .\scripts\torchat.ps1 run android -Device auto
  .\scripts\torchat.ps1 stack restart -OnionPolicy preserve
  .\scripts\torchat.ps1 stop all -Device all
  .\scripts\torchat.ps1 stack reset -DatabasePolicy reset -Confirm
  .\scripts\torchat.ps1 stack reset -OnionPolicy rotate -Confirm
  .\scripts\torchat.ps1 logs export

Default policies:
  build=smart onion=preserve database=preserve clientData=preserve
  stack=ensure install=if-changed run=restart readiness=development
'@
}

if ($Command -in @('help','--help','-h','/?')) {
    Show-TorChatHelp
    return
}

foreach ($module in @(
    'TorChat.Ui.psm1',
    'TorChat.Core.psm1',
    'TorChat.Environment.psm1',
    'TorChat.State.psm1',
    'TorChat.Stack.psm1',
    'TorChat.Build.psm1',
    'TorChat.Android.psm1',
    'TorChat.Windows.psm1',
    'TorChat.Diagnostics.psm1',
    'TorChat.Commands.psm1'
)) {
    $path = Join-Path $moduleRoot $module
    if (-not (Test-Path -LiteralPath $path)) { throw "TorChat module is missing: $path" }
    Import-Module $path -Force -DisableNameChecking
}

# Named public commands map to the domain/action command tree.
switch ($Command) {
    'start-dev' { $Command = 'stack'; $Target = 'start' }
    'stop-dev' { $Command = 'stack'; $Target = 'stop' }
    'build-clients' { $Command = 'build'; $Target = 'clients' }
    'deploy-android' { $Command = 'deploy'; $Target = 'android' }
    'deploy-mobile' { $Command = 'deploy'; $Target = 'android' }
    'deploy-windows' { $Command = 'deploy'; $Target = 'windows' }
    'run-android' { $Command = 'run'; $Target = 'android' }
    'run-windows' { $Command = 'run'; $Target = 'windows' }
    'run-desktop' { $Command = 'run'; $Target = 'windows' }
    'full-deploy' {
        $Command = 'deploy'
        $Target = 'all'
        if ($BuildPolicy -eq 'smart') { $BuildPolicy = 'rebuild' }
        if ($InstallPolicy -eq 'if-changed') { $InstallPolicy = 'always' }
        if ($RunPolicy -eq 'restart') { $RunPolicy = 'start' }
    }
    'deploy-clean' {
        $Command = 'deploy'
        $Target = 'all'
        $BuildPolicy = 'rebuild'
        $OnionPolicy = 'rotate'
        $DatabasePolicy = 'reset'
        $ClientDataPolicy = 'reset'
        $InstallPolicy = 'always'
        $RunPolicy = 'restart'
        $StackPolicy = 'ensure'
        $Confirm = $true
    }
    'redeploy' {
        $Command = 'deploy'
        $Target = 'all'
        $BuildPolicy = 'rebuild'
        # Keep the already-published relay onion during a normal development
        # redeploy. Rotation has a separate explicit deploy-clean workflow.
        $OnionPolicy = 'preserve'
        $DatabasePolicy = 'reset'
        $ClientDataPolicy = 'reset'
        $InstallPolicy = 'always'
        $RunPolicy = 'restart'
        $StackPolicy = 'ensure'
        $Confirm = $true
    }
    'reset-client-state' { $Command = 'clean'; $Target = 'client-data' }
}

if ($Command -eq 'logs' -and $Target -eq 'all') { $Target = 'show' }
if ($Command -eq 'stack' -and $Target -eq 'all') { $Target = 'status' }
if ($Command -eq 'device' -and $Target -eq 'all') { $Target = 'list' }
if ($Command -eq 'clean' -and $Target -eq 'all' -and -not $Confirm -and -not $DryRun) {
    throw 'clean all requires -Confirm.'
}
if ($Release) { $Configuration = 'release' }
if ($ClientDataPolicy -eq 'clean') { $ClientDataPolicy = 'reset' }

if ($Command -eq 'deploy' -and $Target -eq 'all' -and $ClientMode -eq 'prompt') {
    $interactive = $false
    try { $interactive = $null -ne $Host.UI.RawUI } catch { $interactive = $false }
    if ($interactive -and -not $DryRun) {
        Write-Host ''
        Write-Host 'Client deployment target:' -ForegroundColor Cyan
        Write-Host '  [1] Android emulator/device only'
        Write-Host '  [2] Android APK + Windows desktop'
        do { $choice = Read-Host 'Choose 1 or 2 (default 2)' } while ($choice -and $choice -notin @('1','2'))
        $ClientMode = if ($choice -eq '1') { 'emulator' } else { 'android-desktop' }
    } else {
        # CI and redirected stdin must never block. The full client matrix is
        # the safe default outside an interactive developer shell.
        $ClientMode = 'android-desktop'
    }
}

$allowedCommands = @('status','stack','build','deploy','run','stop','test','clean','logs','device')
if ($allowedCommands -notcontains $Command) {
    Show-TorChatHelp
    throw "Unsupported command '$Command'."
}

$context = New-TorChatRunContext `
    -RepositoryRoot $repositoryRoot `
    -Command $Command `
    -Target $Target `
    -Environment $Environment `
    -Configuration $Configuration `
    -UiMode $Ui `
    -Verbosity $Verbosity `
    -NoColor:$NoColor `
    -DryRun:$DryRun

if ($Ui -ne 'json') {
    Initialize-TorChatConsole -Context $context
    Write-TorChatBanner -Context $context
}

$mutex = $null
$mutexAcquired = $false
$mutating = -not $DryRun -and $Command -in @('stack','build','deploy','run','stop','clean')
if ($mutating) {
    # Keep one global mutex for all current TorChat invocations on the host.
    $mutexName = if ($env:OS -eq 'Windows_NT') { 'Global\TorChat-Cli' } else { 'TorChat-Cli' }
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    try {
        $mutexAcquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $mutexAcquired = $true
    }
    if (-not $mutexAcquired) {
        $mutex.Dispose()
        throw 'Another mutating TorChat command is already running.'
    }
}

$failure = $null
try {
    $environmentState = Get-TorChatEnvironmentState -RepositoryRoot $repositoryRoot -Environment $Environment
    Import-TorChatEnvironmentState -EnvironmentState $environmentState

    $options = @{
        BuildPolicy = $BuildPolicy
        OnionPolicy = $OnionPolicy
        DatabasePolicy = $DatabasePolicy
        ClientDataPolicy = $ClientDataPolicy
        StackPolicy = $StackPolicy
        InstallPolicy = $InstallPolicy
        RunPolicy = $RunPolicy
        Readiness = $Readiness
        ReadyAttempts = $ReadyAttempts
        Device = $Device
        PairAddress = $PairAddress
        PairCode = $PairCode
        NoCache = [bool]$NoCache
        Confirm = [bool]$Confirm
        ClientMode = $ClientMode
    }
    [void](Invoke-TorChatCommand -Context $context -EnvironmentState $environmentState -Command $Command -Target $Target -Options $options)
} catch {
    $failure = $_
    $failurePath = Join-Path $context.RunDirectory 'failure.txt'
    $_ | Out-String | Set-Content -LiteralPath $failurePath -Encoding UTF8
    Write-TorChatEvent -Context $context -Stage 'command' -State 'failed' -Message $_.Exception.Message -Data @{ failurePath = $failurePath }
    $hasRecordedFailure = @($context.Results | Where-Object State -eq 'Failed').Count -gt 0
    if (-not $hasRecordedFailure) {
        $result = New-TorChatStageResult -Id 'command' -Name 'Command execution' -State 'Failed' -Code 'COMMAND_FAILED' -Message $_.Exception.Message
        [void]$context.Results.Add($result)
        Write-TorChatEvent -Context $context -Stage 'command' -State 'failed' -Message $_.Exception.Message
        Write-TorChatStageResult -Result $result
        Write-TorChatFailure "Execution stopped. Full diagnostic: $failurePath"
    }
} finally {
    try {
        [void](Complete-TorChatRun -Context $context)
    } catch {
        Write-Warning "Unable to finalize TorChat run: $($_.Exception.Message)"
    }
    if ($mutex) {
        if ($mutexAcquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

if ($failure) { throw "TorChat $Command $Target failed. Full diagnostic: $failurePath" }
