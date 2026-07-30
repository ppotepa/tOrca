Set-StrictMode -Version Latest

function Invoke-TorChatCompose {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$ComposeContext,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogName,
        [int[]]$AllowedExitCodes = @(0)
    )
    Invoke-TorChatNative -Context $Context -FilePath 'docker' -ArgumentList @($ComposeContext.Arguments + $Arguments) -WorkingDirectory $Context.RepositoryRoot -LogName $LogName -AllowedExitCodes $AllowedExitCodes
}

function Wait-TorChatHttpHealth {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 60
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $attempt = 0
    do {
        $attempt++
        try {
            $health = Invoke-RestMethod -Uri $Url -TimeoutSec 3
            if ($health.status -eq 'ok') {
                return [pscustomobject]@{ State = 'Ready'; Code = 'HTTP_HEALTH_READY'; Message = "$Url is healthy"; Attempts = $attempt }
            }
        } catch {
            if ($Context.Verbosity -eq 'trace') { Write-TorChatInfo "Health attempt $attempt failed: $($_.Exception.Message)" }
        }
        $elapsed = $TimeoutSeconds - [Math]::Max(0, [Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalSeconds))
        $percent = [Math]::Min(99, [Math]::Max(0, [int](100 * $elapsed / [Math]::Max(1, $TimeoutSeconds))))
        Write-TorChatStageProgress -Context $Context -Name 'Relay local health' -Percent $percent -Detail "attempt $attempt"
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Local relay healthcheck failed after ${TimeoutSeconds}s: $Url"
}

function Get-TorChatOnionHostname {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$ComposeContext,
        [int]$TimeoutSeconds = 240
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $output = @(& docker @($ComposeContext.Arguments + @('exec','-T','tor','cat','/var/lib/tor/hidden_service/hostname')) 2>$null)
        $hostname = ($output | Select-Object -First 1 | Out-String).Trim()
        if ($hostname -match '^[a-z2-7]{56}\.onion$') { return $hostname }
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Tor hidden service hostname was not generated before the timeout.'
}

function Get-TorChatBootstrapSnapshot {
    param([Parameter(Mandatory = $true)]$ComposeContext)
    $logs = @(& docker @($ComposeContext.Arguments + @('logs','--no-color','--tail','120','tor')) 2>&1)
    $text = $logs | Out-String
    $matches = [regex]::Matches($text, 'Bootstrapped ([0-9]{1,3})% \(([^)]+)\): ([^\r\n]+)')
    if ($matches.Count -eq 0) {
        return [pscustomobject]@{ Progress = 0; Phase = 'starting'; Detail = 'Waiting for Tor bootstrap output'; Ready = $false }
    }
    $latest = $matches[$matches.Count - 1]
    $progress = [int]$latest.Groups[1].Value
    [pscustomobject]@{
        Progress = $progress
        Phase = $latest.Groups[2].Value
        Detail = $latest.Groups[3].Value.Trim()
        Ready = $progress -ge 100
    }
}

function Wait-TorChatBootstrap {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$ComposeContext,
        [int]$TimeoutSeconds = 300,
        [switch]$Required
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $last = $null
    do {
        $snapshot = Get-TorChatBootstrapSnapshot -ComposeContext $ComposeContext
        Write-TorChatStageProgress -Context $Context -Name 'Tor bootstrap' -Percent ([Math]::Min(100, $snapshot.Progress)) -Detail "$($snapshot.Phase) · $($snapshot.Detail)"
        if ($snapshot.Ready) {
            return [pscustomobject]@{ State = 'Ready'; Code = 'TOR_BOOTSTRAP_READY'; Message = 'Tor reached 100%'; Snapshot = $snapshot }
        }
        $last = $snapshot
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $message = "Tor bootstrap did not reach 100% within ${TimeoutSeconds}s. Last state: $($last.Progress)% $($last.Phase) $($last.Detail)"
    if ($Required) { throw $message }
    return [pscustomobject]@{ State = 'Warning'; Code = 'TOR_BOOTSTRAP_WARMING'; Message = $message; Snapshot = $last }
}

function Test-TorChatOnionReachability {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$OnionUrl,
        [Parameter(Mandatory = $true)][int]$SocksPort,
        [int]$TimeoutSeconds = 45,
        [switch]$Required
    )
    $curl = if (Get-Command curl.exe -ErrorAction SilentlyContinue) { 'curl.exe' } elseif (Get-Command curl -ErrorAction SilentlyContinue) { 'curl' } else { throw 'Missing required tool: curl' }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $attempt = 0
    $lastFailure = 'no response'
    do {
        $attempt++
        $remaining = [Math]::Max(1, [Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalSeconds))
        $probeTimeout = [Math]::Min(7, $remaining)
        $output = @(& $curl '--silent' '--show-error' '--fail-with-body' '--max-time' "$probeTimeout" '--socks5-hostname' "127.0.0.1:$SocksPort" "$OnionUrl/health" 2>&1)
        $exitCode = $LASTEXITCODE
        $text = ($output | Out-String).Trim()
        if ($exitCode -eq 0) {
            try {
                $payload = $text | ConvertFrom-Json
                if ($payload.status -eq 'ok') {
                    return [pscustomobject]@{ State = 'Ready'; Code = 'ONION_REACHABLE'; Message = "Onion relay is reachable after $attempt attempt(s)"; Attempts = $attempt }
                }
                $lastFailure = "unexpected status '$($payload.status)'"
            } catch {
                $lastFailure = "invalid JSON response: $text"
            }
        } else {
            $classification = switch ($exitCode) {
                7 { 'SOCKS endpoint refused the connection' }
                28 { 'onion descriptor or circuit is still warming' }
                97 { 'SOCKS handshake failed' }
                default { "curl exit $exitCode" }
            }
            $lastFailure = if ($text) { "$classification · $text" } else { $classification }
        }
        $elapsed = $TimeoutSeconds - [Math]::Max(0, [Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalSeconds))
        $percent = [Math]::Min(99, [Math]::Max(0, [int](100 * $elapsed / [Math]::Max(1, $TimeoutSeconds))))
        Write-TorChatStageProgress -Context $Context -Name 'Onion reachability' -Percent $percent -Detail "attempt $attempt · $lastFailure"
        if ([DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Seconds 3 }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $message = "Onion is still warming after ${TimeoutSeconds}s: $lastFailure"
    if ($Required) { throw $message }
    return [pscustomobject]@{ State = 'Warning'; Code = 'ONION_WARMING'; Message = $message; Attempts = $attempt }
}

function Reset-TorChatStackState {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$ComposeContext,
        [ValidateSet('preserve','reset')][string]$DatabasePolicy = 'preserve',
        [ValidateSet('preserve','rotate')][string]$OnionPolicy = 'preserve'
    )
    if ($DatabasePolicy -eq 'preserve' -and $OnionPolicy -eq 'preserve') { return }

    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $ComposeContext -Arguments @('stop','server','postgres','tor') -LogName 'docker-reset-stop.log' -AllowedExitCodes @(0))
    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $ComposeContext -Arguments @('rm','-f','server','postgres','tor') -LogName 'docker-reset-rm.log' -AllowedExitCodes @(0))
    if ($DatabasePolicy -eq 'reset') {
        [void](Invoke-TorChatNative -Context $Context -FilePath 'docker' -ArgumentList @('volume','rm','-f',"$($ComposeContext.Project)_postgres_dev") -LogName 'docker-reset-postgres.log' -AllowedExitCodes @(0,1))
    }
    if ($OnionPolicy -eq 'rotate') {
        [void](Invoke-TorChatNative -Context $Context -FilePath 'docker' -ArgumentList @('volume','rm','-f',"$($ComposeContext.Project)_tor_dev") -LogName 'docker-rotate-onion.log' -AllowedExitCodes @(0,1))
    }
}

function Start-TorChatStack {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [ValidateSet('use','rebuild')][string]$ImagePolicy = 'use',
        [ValidateSet('preserve','reset')][string]$DatabasePolicy = 'preserve',
        [ValidateSet('preserve','rotate')][string]$OnionPolicy = 'preserve',
        [ValidateSet('local','bootstrap','onion','strict')][string]$Readiness = 'local',
        [switch]$NoCache
    )
    Assert-TorChatTool -Name docker
    $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('config') -LogName 'docker-config.log')
    Reset-TorChatStackState -Context $Context -ComposeContext $compose -DatabasePolicy $DatabasePolicy -OnionPolicy $OnionPolicy

    if ($ImagePolicy -eq 'rebuild') {
        $buildArgs = @('build')
        if ($NoCache) { $buildArgs += '--no-cache' }
        [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments $buildArgs -LogName 'docker-build.log')
    }

    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('up','-d','--remove-orphans') -LogName 'docker-up.log')
    [void](Wait-TorChatHttpHealth -Context $Context -Url ("http://127.0.0.1:{0}/health" -f $EnvironmentState.Values['TORCHAT_HTTP_PORT']) -TimeoutSeconds 90)

    $previousOnion = [string]$EnvironmentState.Values['TORCHAT_ONION_URL']
    $hostname = Get-TorChatOnionHostname -Context $Context -ComposeContext $compose
    $onionUrl = "http://$hostname"
    Set-TorChatEnvironmentOnion -EnvironmentState $EnvironmentState -OnionUrl $onionUrl
    Import-TorChatEnvironmentState -EnvironmentState $EnvironmentState -RequireOnion

    if ($previousOnion -ne $onionUrl) {
        [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('up','-d','--force-recreate','server') -LogName 'docker-server-recreate.log')
        [void](Wait-TorChatHttpHealth -Context $Context -Url ("http://127.0.0.1:{0}/health" -f $EnvironmentState.Values['TORCHAT_HTTP_PORT']) -TimeoutSeconds 90)
    }

    if ($Readiness -in @('bootstrap','onion','strict')) {
        [void](Wait-TorChatBootstrap -Context $Context -ComposeContext $compose -TimeoutSeconds 300 -Required:($Readiness -eq 'strict'))
    }
    if ($Readiness -in @('onion','strict')) {
        $probe = Test-TorChatOnionReachability -Context $Context -OnionUrl $onionUrl -SocksPort ([int]$EnvironmentState.Values['TORCHAT_SOCKS_PORT']) -TimeoutSeconds (if ($Readiness -eq 'strict') { 240 } else { 60 }) -Required:($Readiness -eq 'strict')
        if ($probe.State -eq 'Warning') { return $probe }
    }

    return [pscustomobject]@{
        State = 'Ready'
        Code = 'STACK_READY'
        Message = "Local stack is running with onion $hostname"
        OnionUrl = $onionUrl
        Compose = $compose
    }
}

function Stop-TorChatStack {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$EnvironmentState)
    $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('down','--remove-orphans') -LogName 'docker-down.log')
    [pscustomobject]@{ State = 'Ready'; Code = 'STACK_STOPPED'; Message = 'Stack stopped; volumes preserved' }
}

function Restart-TorChatStack {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$EnvironmentState, [ValidateSet('local','bootstrap','onion','strict')][string]$Readiness = 'local')
    [void](Stop-TorChatStack -Context $Context -EnvironmentState $EnvironmentState)
    Start-TorChatStack -Context $Context -EnvironmentState $EnvironmentState -Readiness $Readiness
}

function Repair-TorChatOnion {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$EnvironmentState)
    $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('restart','tor') -LogName 'docker-tor-repair.log')
    $bootstrap = Wait-TorChatBootstrap -Context $Context -ComposeContext $compose -TimeoutSeconds 300
    if ($bootstrap.State -eq 'Warning') { return $bootstrap }
    Test-TorChatOnionReachability -Context $Context -OnionUrl ([string]$EnvironmentState.Values['TORCHAT_ONION_URL']) -SocksPort ([int]$EnvironmentState.Values['TORCHAT_SOCKS_PORT']) -TimeoutSeconds 60
}

function Get-TorChatStackStatus {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$EnvironmentState)
    $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
    $ps = Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('ps') -LogName 'docker-status.log'
    $bootstrap = Get-TorChatBootstrapSnapshot -ComposeContext $compose
    $localHealth = $false
    try {
        $health = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/health" -f $EnvironmentState.Values['TORCHAT_HTTP_PORT']) -TimeoutSec 3
        $localHealth = $health.status -eq 'ok'
    } catch { }
    [pscustomobject]@{
        State = if ($localHealth) { 'Ready' } else { 'Warning' }
        Code = if ($localHealth) { 'STACK_HEALTHY' } else { 'STACK_DEGRADED' }
        Message = "relay=$localHealth tor=$($bootstrap.Progress)% onion=$($EnvironmentState.Values['TORCHAT_ONION_URL'])"
        RelayHealthy = $localHealth
        TorBootstrap = $bootstrap
        OnionUrl = [string]$EnvironmentState.Values['TORCHAT_ONION_URL']
        ProcessOutput = $ps.Output
    }
}

Export-ModuleMember -Function @(
    'Wait-TorChatHttpHealth',
    'Get-TorChatOnionHostname',
    'Get-TorChatBootstrapSnapshot',
    'Wait-TorChatBootstrap',
    'Test-TorChatOnionReachability',
    'Start-TorChatStack',
    'Stop-TorChatStack',
    'Restart-TorChatStack',
    'Repair-TorChatOnion',
    'Get-TorChatStackStatus'
)
