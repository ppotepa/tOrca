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

    [Alias('DeviceAddress')][string]$Device = 'auto',
    [string]$PairAddress,
    [string]$PairCode,

    [switch]$Release,
    [switch]$Incremental,
    [switch]$Clean,
    [switch]$SkipEnvironmentStart,
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
  run     [android|windows|all]
  stop    [android|windows|all]
  clean   [build|server-data|client-data|all]
  logs    [show|collect|export]
  device  [list|pair|connect|status]

Examples:
  .\scripts\torchat.ps1 deploy all
  .\scripts\torchat.ps1 deploy android -Device auto
  .\scripts\torchat.ps1 stack restart -OnionPolicy preserve
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

# Compatibility aliases remain accepted while documentation and CI migrate to
# the domain/action command tree.
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
    'full-deploy' { $Command = 'deploy'; $Target = 'all'; $BuildPolicy = 'rebuild' }
    'redeploy' { $Command = 'deploy'; $Target = 'all' }
    'reset-client-state' { $Command = 'clean'; $Target = 'client-data' }
}

if ($Command -eq 'logs' -and $Target -eq 'all') { $Target = 'show' }
if ($Command -eq 'stack' -and $Target -eq 'all') { $Target = 'status' }
if ($Command -eq 'device' -and $Target -eq 'all') { $Target = 'list' }
if ($Command -eq 'clean' -and $Target -eq 'all' -and -not $Confirm) { $Target = 'build' }
if ($Release) { $Configuration = 'release' }
if ($Incremental) { $BuildPolicy = 'smart' }
if ($Clean -or $ClientDataPolicy -eq 'clean') { $ClientDataPolicy = 'reset' }
if ($SkipEnvironmentStart) { $StackPolicy = 'skip' }

$allowedCommands = @('status','stack','build','deploy','run','stop','clean','logs','device')
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
$mutating = $Command -in @('stack','build','deploy','run','stop','clean')
if ($mutating) {
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
