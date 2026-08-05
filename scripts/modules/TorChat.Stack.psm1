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

function Assert-TorChatDockerEngine {
    param([Parameter(Mandatory = $true)]$Context)

    Assert-TorChatTool -Name docker
    $logPath = Join-Path $Context.LogDirectory 'docker-engine-preflight.log'
    $stdoutPath = Join-Path $Context.LogDirectory 'docker-engine-preflight.stdout.log'
    $stderrPath = Join-Path $Context.LogDirectory 'docker-engine-preflight.stderr.log'
    $process = $null
    try {
        $process = Start-Process -FilePath 'docker' -ArgumentList @('version','--format','{{.Server.Version}}') `
            -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if (-not $process.WaitForExit(10000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw 'Docker Desktop Linux engine did not answer within 10 seconds.'
        }
        $output = @()
        if (Test-Path -LiteralPath $stdoutPath) { $output += Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $stderrPath) { $output += Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue }
        $text = ($output | Out-String).TrimEnd()
        # Start-Process may retain a stale ExitCode value until refreshed after
        # WaitForExit; without this Docker was reported unavailable even when
        # stdout contained a valid server version.
        $process.Refresh()
        if ($text) { $text | Set-Content -LiteralPath $logPath -Encoding UTF8 }
        $serverVersion = if (Test-Path -LiteralPath $stdoutPath) {
            (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue).Trim()
        } else { '' }
        # Docker Desktop can return a transient non-zero status from
        # `docker version` while still returning a valid server version. The
        # server version is the authoritative readiness signal here.
        if ([string]::IsNullOrWhiteSpace($serverVersion) -or
            $serverVersion -notmatch '^\d+\.\d+\.\d+') {
            throw 'Docker Desktop Linux engine returned an error.'
        }
        return $serverVersion
    } catch {
        $_ | Out-String | Add-Content -LiteralPath $logPath -Encoding UTF8
        throw "Docker Desktop Linux engine is unavailable. Start or restart Docker Desktop, wait for 'Engine running', then retry. Diagnostics: $logPath"
    } finally {
        if ($process) { $process.Dispose() }
    }
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
            # The relay health endpoint intentionally returns a minimal
            # text response (`ok`), while older deployments returned JSON.
            # Accept both during the transition.
            if ($health -eq 'ok' -or $health.status -eq 'ok') {
                return [pscustomobject]@{
                    State = 'Ready'
                    Code = 'HTTP_HEALTH_READY'
                    Message = "$Url is healthy"
                    Attempts = $attempt
                }
            }
        } catch {
            if ($Context.Verbosity -eq 'trace') {
                Write-TorChatInfo "Health attempt $attempt failed: $($_.Exception.Message)"
            }
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
        return [pscustomobject]@{
            Progress = 0
            Phase = 'starting'
            Detail = 'Waiting for Tor bootstrap output'
            Ready = $false
        }
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
        Write-TorChatStageProgress -Context $Context -Name 'Tor bootstrap' -Percent ([Math]::Min(100, $snapshot.Progress)) -Detail "$($snapshot.Phase) - $($snapshot.Detail)"
        if ($snapshot.Ready) {
            return [pscustomobject]@{
                State = 'Ready'
                Code = 'TOR_BOOTSTRAP_READY'
                Message = 'Tor reached 100%'
                Snapshot = $snapshot
            }
        }
        $last = $snapshot
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $message = "Tor bootstrap did not reach 100% within ${TimeoutSeconds}s. Last state: $($last.Progress)% $($last.Phase) $($last.Detail)"
    if ($Required) { throw $message }
    [pscustomobject]@{
        State = 'Warning'
        Code = 'TOR_BOOTSTRAP_WARMING'
        Message = $message
        Snapshot = $last
    }
}

function Test-TorChatOnionReachability {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$OnionUrl,
        [Parameter(Mandatory = $true)][int]$SocksPort,
        [int]$TimeoutSeconds = 45,
        [switch]$Required
    )
    $curl = if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        'curl.exe'
    } elseif (Get-Command curl -ErrorAction SilentlyContinue) {
        'curl'
    } else {
        throw 'Missing required tool: curl'
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $attempt = 0
    $consecutiveSuccesses = 0
    $lastFailure = 'no response'
    do {
        $attempt++
        $remaining = [Math]::Max(1, [Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalSeconds))
        $probeTimeout = [Math]::Min(7, $remaining)
        $output = @(& $curl '--silent' '--show-error' '--fail-with-body' '--max-time' "$probeTimeout" '--socks5-hostname' "127.0.0.1:$SocksPort" "$OnionUrl/health" 2>&1)
        $exitCode = $LASTEXITCODE
        $text = ($output | Out-String).Trim()
        if ($exitCode -eq 0) {
            # The relay health endpoint intentionally returns the minimal
            # text body `ok`; older relay images returned {"status":"ok"}.
            # Keep the onion probe compatible with both representations.
            $isHealthy = $text -eq 'ok'
            if (-not $isHealthy) {
                try {
                    $payload = $text | ConvertFrom-Json
                    $isHealthy = $payload.status -eq 'ok'
                } catch {
                    $isHealthy = $false
                }
            }
            if ($isHealthy) {
                    $consecutiveSuccesses++
                    if ($consecutiveSuccesses -ge 2) {
                        return [pscustomobject]@{
                            State = 'Ready'
                            Code = 'ONION_REACHABLE'
                            Message = "Onion relay passed two consecutive probes after $attempt attempt(s)"
                            Attempts = $attempt
                        }
                    }
                    $lastFailure = 'first successful probe; confirming circuit stability'
            } else {
                $consecutiveSuccesses = 0
                $lastFailure = "unexpected health response: $text"
            }
        } else {
            $consecutiveSuccesses = 0
            $classification = switch ($exitCode) {
                7 { 'SOCKS endpoint refused the connection' }
                28 { 'onion descriptor or circuit is still warming' }
                97 { 'SOCKS handshake failed' }
                default { "curl exit $exitCode" }
            }
            $lastFailure = if ($text) { "$classification - $text" } else { $classification }
        }
        $elapsed = $TimeoutSeconds - [Math]::Max(0, [Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalSeconds))
        $percent = [Math]::Min(99, [Math]::Max(0, [int](100 * $elapsed / [Math]::Max(1, $TimeoutSeconds))))
        Write-TorChatStageProgress -Context $Context -Name 'Onion reachability' -Percent $percent -Detail "attempt $attempt - $lastFailure"
        if ([DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Seconds 3 }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $message = "Onion is still warming after ${TimeoutSeconds}s: $lastFailure"
    if ($Required) { throw $message }
    [pscustomobject]@{
        State = 'Warning'
        Code = 'ONION_WARMING'
        Message = $message
        Attempts = $attempt
    }
}

function Reset-TorChatStackState {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$ComposeContext,
        [ValidateSet('preserve','reset')][string]$DatabasePolicy = 'preserve',
        [ValidateSet('preserve','rotate')][string]$OnionPolicy = 'preserve'
    )
    if ($DatabasePolicy -eq 'preserve' -and $OnionPolicy -eq 'preserve') { return }

    # A client-database reset keeps the published hidden service running. Tor is
    # stopped only for an explicit onion rotation. The relay has no database.
    $resetServices = if ($OnionPolicy -eq 'rotate') {
        @('relay','tor','torka')
    } else {
        @('relay','torka')
    }
    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $ComposeContext -Arguments (@('stop') + $resetServices) -LogName 'docker-reset-stop.log' -AllowedExitCodes @(0))
    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $ComposeContext -Arguments (@('rm','-f') + $resetServices) -LogName 'docker-reset-rm.log' -AllowedExitCodes @(0))
    if ($DatabasePolicy -eq 'reset') {
        # Torka owns the only application database in the local stack.
        [void](Invoke-TorChatNative -Context $Context -FilePath 'docker' -ArgumentList @('volume','rm','-f',"$($ComposeContext.Project)_torka_dev") -LogName 'docker-reset-torka.log' -AllowedExitCodes @(0,1))
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
        [ValidateSet('local','development','bootstrap','onion','strict')][string]$Readiness = 'local',
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

    # Resolve the relay onion before starting Torka. A compose environment is
    # fixed at container creation time, so starting the peer before this point
    # would give it an empty or stale TORCHAT_ONION_URL after an onion rotate.
    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('up','-d','--remove-orphans','relay','tor') -LogName 'docker-up.log')
    [void](Wait-TorChatHttpHealth -Context $Context -Url ("http://127.0.0.1:{0}/health" -f $EnvironmentState.Values['TORCHAT_HTTP_PORT']) -TimeoutSeconds 90)

    $previousOnion = [string]$EnvironmentState.Values['TORCHAT_ONION_URL']
    $hostname = Get-TorChatOnionHostname -Context $Context -ComposeContext $compose
    $onionUrl = "http://$hostname"
    Set-TorChatEnvironmentOnion -EnvironmentState $EnvironmentState -OnionUrl $onionUrl
    Import-TorChatEnvironmentState -EnvironmentState $EnvironmentState -RequireOnion

    if ($previousOnion -ne $onionUrl) {
        [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('up','-d','--force-recreate','relay','torka') -LogName 'docker-relay-recreate.log')
        [void](Wait-TorChatHttpHealth -Context $Context -Url ("http://127.0.0.1:{0}/health" -f $EnvironmentState.Values['TORCHAT_HTTP_PORT']) -TimeoutSeconds 90)
    } else {
        # Torka is a stateful development client. `docker compose up -d` does
        # not recreate an existing container merely because its locally built
        # image changed, leaving a stale bot runtime after an engine/Python
        # fix. Recreate only Torka; its volume preserves identity and test
        # contacts while server, Tor and client applications remain untouched.
        [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('up','-d','--force-recreate','torka') -LogName 'docker-torka-up.log')
    }

    if ($Readiness -in @('bootstrap','onion','strict')) {
        [void](Wait-TorChatBootstrap -Context $Context -ComposeContext $compose -TimeoutSeconds 300 -Required:($Readiness -eq 'strict'))
    }
    if ($Readiness -in @('onion','strict')) {
        $probeTimeoutSeconds = if ($Readiness -eq 'strict') { 240 } else { 60 }
        $probe = Test-TorChatOnionReachability -Context $Context -OnionUrl $onionUrl -SocksPort ([int]$EnvironmentState.Values['TORCHAT_SOCKS_PORT']) -TimeoutSeconds $probeTimeoutSeconds -Required:($Readiness -eq 'strict')
        if ($probe.State -eq 'Warning') { return $probe }
    }

    [pscustomobject]@{
        State = 'Ready'
        Code = 'STACK_READY'
        Message = "Local stack is running with onion $hostname"
        OnionUrl = $onionUrl
        Compose = $compose
    }
}

function Stop-TorChatStack {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState
    )
    $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('down','--remove-orphans') -LogName 'docker-down.log')
    [pscustomobject]@{
        State = 'Ready'
        Code = 'STACK_STOPPED'
        Message = 'Stack stopped; volumes preserved'
    }
}

function Restart-TorChatStack {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [ValidateSet('local','development','bootstrap','onion','strict')][string]$Readiness = 'local'
    )
    [void](Stop-TorChatStack -Context $Context -EnvironmentState $EnvironmentState)
    Start-TorChatStack -Context $Context -EnvironmentState $EnvironmentState -Readiness $Readiness
}

function Repair-TorChatOnion {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState
    )
    $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
    [void](Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('restart','tor') -LogName 'docker-tor-repair.log')
    $bootstrap = Wait-TorChatBootstrap -Context $Context -ComposeContext $compose -TimeoutSeconds 300
    if ($bootstrap.State -eq 'Warning') { return $bootstrap }
    Test-TorChatOnionReachability -Context $Context -OnionUrl ([string]$EnvironmentState.Values['TORCHAT_ONION_URL']) -SocksPort ([int]$EnvironmentState.Values['TORCHAT_SOCKS_PORT']) -TimeoutSeconds 60
}

function Get-TorChatStackStatus {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState
    )
    try {
        [void](Assert-TorChatDockerEngine -Context $Context)
    } catch {
        return [pscustomobject]@{
            State = 'Warning'
            Code = 'DOCKER_ENGINE_UNAVAILABLE'
            Message = $_.Exception.Message
            RelayHealthy = $false
            TorBootstrap = $null
            OnionUrl = [string]$EnvironmentState.Values['TORCHAT_ONION_URL']
            ProcessOutput = @()
        }
    }
    $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
    $ps = Invoke-TorChatCompose -Context $Context -ComposeContext $compose -Arguments @('ps') -LogName 'docker-status.log'
    $bootstrap = Get-TorChatBootstrapSnapshot -ComposeContext $compose
    $localHealth = $false
    try {
        $health = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/health" -f $EnvironmentState.Values['TORCHAT_HTTP_PORT']) -TimeoutSec 3
        # The current ephemeral relay deliberately returns the minimal text
        # response `ok`; older deployments returned JSON `{ status: "ok" }`.
        $localHealth = $health -eq 'ok' -or $health.status -eq 'ok'
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
    'Assert-TorChatDockerEngine',
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
