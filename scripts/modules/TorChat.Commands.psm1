Set-StrictMode -Version Latest

function Assert-TorChatCommandTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string[]]$Allowed
    )
    if ($Allowed -notcontains $Target) {
        throw "Unsupported target '$Target'. Allowed: $($Allowed -join ', ')."
    }
}

function Invoke-TorChatPreflight {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Target
    )
    Invoke-TorChatStage -Context $Context -Id 'preflight' -Name 'Preflight' -Action {
        $needsDocker = $Context.Environment -eq 'local' -and (
            $Command -in @('stack','deploy','clean') -or
            ($Command -eq 'status' -and $Target -in @('stack','all')) -or
            ($Command -eq 'logs' -and $Target -in @('collect','export'))
        )
        if ($needsDocker) { Assert-TorChatTool -Name docker }

        if (($Command -in @('build','deploy')) -and $Target -in @('android','windows','clients','all')) {
            if ($Context.Metadata['BuildPolicy'] -ne 'skip') {
                Assert-TorChatTool -Name cargo
                Assert-TorChatTool -Name flutter
                if ($Target -in @('android','clients','all')) { Assert-TorChatTool -Name rustup }
            }
        }

        $needsAdb = ($Command -in @('deploy','run','stop','clean','device')) -and
            $Target -in @('android','all','list','pair','connect','status','client-data')
        if ($needsAdb) { Assert-TorChatTool -Name adb }

        [pscustomobject]@{
            State = 'Ready'
            Code = 'PREFLIGHT_READY'
            Message = 'Required tools are available'
        }
    }
}

function Invoke-TorChatAndroidBuildPlan {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$BuildPolicy
    )
    $skip = $BuildPolicy -eq 'skip'
    Invoke-TorChatStage -Context $Context -Id 'build.android.engine' -Name 'Build Android Rust engine' -Skip:$skip -Action {
        Build-TorChatAndroidEngine -Context $Context -Policy $BuildPolicy
    }
    Invoke-TorChatStage -Context $Context -Id 'build.android.client' -Name 'Build Android APK' -Skip:$skip -Action {
        Build-TorChatAndroidClient -Context $Context -EnvironmentState $EnvironmentState -Policy $BuildPolicy
    }
}

function Invoke-TorChatWindowsBuildPlan {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$BuildPolicy
    )
    $skip = $BuildPolicy -eq 'skip'
    Invoke-TorChatStage -Context $Context -Id 'build.windows.engine' -Name 'Build Windows Rust engine' -Skip:$skip -Action {
        Build-TorChatDesktopEngine -Context $Context -EnvironmentState $EnvironmentState -Policy $BuildPolicy
    }
    Invoke-TorChatStage -Context $Context -Id 'build.windows.client' -Name 'Build Windows client' -Skip:$skip -Action {
        Build-TorChatWindowsClient -Context $Context -EnvironmentState $EnvironmentState -Policy $BuildPolicy
    }
}

function Invoke-TorChatStackCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$BuildPolicy,
        [Parameter(Mandatory = $true)][string]$OnionPolicy,
        [Parameter(Mandatory = $true)][string]$DatabasePolicy,
        [Parameter(Mandatory = $true)][string]$Readiness,
        [switch]$NoCache,
        [switch]$Confirm
    )
    Assert-TorChatCommandTarget -Target $Action -Allowed @('start','stop','restart','status','reset','repair')
    if ($OnionPolicy -eq 'rotate' -and -not $Confirm) {
        throw 'Onion rotation requires -Confirm.'
    }

    $stackReadiness = switch ($Readiness) {
        'development' { 'onion' }
        'onion' { 'onion' }
        'strict' { 'strict' }
        default { 'local' }
    }
    $imagePolicy = if ($BuildPolicy -eq 'rebuild') { 'rebuild' } else { 'use' }

    switch ($Action) {
        'start' {
            Invoke-TorChatStage -Context $Context -Id 'stack.start' -Name 'Start local stack' -Action {
                Start-TorChatStack -Context $Context -EnvironmentState $EnvironmentState -ImagePolicy $imagePolicy -DatabasePolicy $DatabasePolicy -OnionPolicy $OnionPolicy -Readiness $stackReadiness -NoCache:$NoCache
            }
        }
        'stop' {
            Invoke-TorChatStage -Context $Context -Id 'stack.stop' -Name 'Stop local stack' -Action {
                Stop-TorChatStack -Context $Context -EnvironmentState $EnvironmentState
            }
        }
        'restart' {
            Invoke-TorChatStage -Context $Context -Id 'stack.restart' -Name 'Restart local stack' -Action {
                Restart-TorChatStack -Context $Context -EnvironmentState $EnvironmentState -Readiness $stackReadiness
            }
        }
        'status' {
            Invoke-TorChatStage -Context $Context -Id 'stack.status' -Name 'Inspect local stack' -Required $false -Action {
                Get-TorChatStackStatus -Context $Context -EnvironmentState $EnvironmentState
            }
        }
        'reset' {
            if ($DatabasePolicy -eq 'preserve' -and $OnionPolicy -eq 'preserve') {
                throw 'stack reset requires -DatabasePolicy reset or -OnionPolicy rotate.'
            }
            Invoke-TorChatStage -Context $Context -Id 'stack.reset' -Name 'Reset selected stack state' -Action {
                Start-TorChatStack -Context $Context -EnvironmentState $EnvironmentState -ImagePolicy $imagePolicy -DatabasePolicy $DatabasePolicy -OnionPolicy $OnionPolicy -Readiness $stackReadiness -NoCache:$NoCache
            }
        }
        'repair' {
            Invoke-TorChatStage -Context $Context -Id 'stack.tor.repair' -Name 'Repair Tor without rotating onion' -Required $false -Action {
                Repair-TorChatOnion -Context $Context -EnvironmentState $EnvironmentState
            }
        }
    }
}

function Invoke-TorChatBuildCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$BuildPolicy,
        [switch]$NoCache
    )
    Assert-TorChatCommandTarget -Target $Target -Allowed @('server','android','windows','clients','all')

    if ($Target -in @('server','all')) {
        Invoke-TorChatStage -Context $Context -Id 'build.server' -Name 'Build relay server image' -Skip:($BuildPolicy -eq 'skip') -Action {
            Build-TorChatServerImage -Context $Context -EnvironmentState $EnvironmentState -NoCache:$NoCache
        }
    }
    if ($Target -in @('windows','clients','all')) {
        Invoke-TorChatWindowsBuildPlan -Context $Context -EnvironmentState $EnvironmentState -BuildPolicy $BuildPolicy
    }
    if ($Target -in @('android','clients','all')) {
        Invoke-TorChatAndroidBuildPlan -Context $Context -EnvironmentState $EnvironmentState -BuildPolicy $BuildPolicy
    }
}

function Invoke-TorChatPostBuildTorChecks {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$Readiness
    )
    if ($Context.Environment -ne 'local') { return }

    $compose = Get-TorChatComposeContext -RepositoryRoot $Context.RepositoryRoot -EnvironmentState $EnvironmentState
    $bootstrapRequired = $Readiness -eq 'strict'
    $bootstrapTimeout = if ($Readiness -eq 'development') { 180 } else { 300 }
    Invoke-TorChatStage -Context $Context -Id 'tor.bootstrap' -Name 'Tor bootstrap' -Required:$bootstrapRequired -Action {
        Wait-TorChatBootstrap -Context $Context -ComposeContext $compose -TimeoutSeconds $bootstrapTimeout -Required:$bootstrapRequired
    }

    $onionRequired = $Readiness -eq 'strict'
    $onionTimeout = switch ($Readiness) {
        'development' { 45 }
        'onion' { 120 }
        'strict' { 240 }
        default { 45 }
    }
    Invoke-TorChatStage -Context $Context -Id 'tor.onion' -Name 'Onion reachability' -Required:$onionRequired -Action {
        Test-TorChatOnionReachability -Context $Context -OnionUrl ([string]$EnvironmentState.Values['TORCHAT_ONION_URL']) -SocksPort ([int]$EnvironmentState.Values['TORCHAT_SOCKS_PORT']) -TimeoutSeconds $onionTimeout -Required:$onionRequired
    }
}

function Invoke-TorChatDeployCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$BuildPolicy,
        [Parameter(Mandatory = $true)][string]$OnionPolicy,
        [Parameter(Mandatory = $true)][string]$DatabasePolicy,
        [Parameter(Mandatory = $true)][string]$ClientDataPolicy,
        [Parameter(Mandatory = $true)][string]$StackPolicy,
        [Parameter(Mandatory = $true)][string]$InstallPolicy,
        [Parameter(Mandatory = $true)][string]$RunPolicy,
        [Parameter(Mandatory = $true)][string]$Readiness,
        [string]$Device,
        [switch]$NoCache,
        [switch]$Confirm
    )
    Assert-TorChatCommandTarget -Target $Target -Allowed @('android','windows','all')
    if ($OnionPolicy -eq 'rotate' -and -not $Confirm) {
        throw 'Onion rotation requires -Confirm.'
    }

    if ($Context.Environment -eq 'local' -and $StackPolicy -eq 'ensure') {
        Invoke-TorChatStage -Context $Context -Id 'stack.ensure' -Name 'Ensure local stack' -Action {
            Start-TorChatStack -Context $Context -EnvironmentState $EnvironmentState -ImagePolicy 'use' -DatabasePolicy $DatabasePolicy -OnionPolicy $OnionPolicy -Readiness 'local'
        }
    } else {
        Import-TorChatEnvironmentState -EnvironmentState $EnvironmentState -RequireOnion
    }

    if ($Target -in @('windows','all')) {
        Invoke-TorChatWindowsBuildPlan -Context $Context -EnvironmentState $EnvironmentState -BuildPolicy $BuildPolicy
    }
    if ($Target -in @('android','all')) {
        Invoke-TorChatAndroidBuildPlan -Context $Context -EnvironmentState $EnvironmentState -BuildPolicy $BuildPolicy
    }

    if ($Context.Environment -eq 'local' -and $StackPolicy -eq 'ensure') {
        Invoke-TorChatPostBuildTorChecks -Context $Context -EnvironmentState $EnvironmentState -Readiness $Readiness
    }

    if ($Target -in @('android','all')) {
        $deviceStage = Invoke-TorChatStage -Context $Context -Id 'device.android.resolve' -Name 'Resolve Android device' -Action {
            $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device
            [pscustomobject]@{
                State = 'Ready'
                Code = 'ANDROID_DEVICE_RESOLVED'
                Message = $resolved
                Device = $resolved
            }
        }
        $resolvedDevice = [string]$deviceStage.Data.Device
        $Context.Metadata['AndroidDevice'] = $resolvedDevice

        $artifact = Join-Path $Context.RepositoryRoot "mobile\build\app\outputs\flutter-apk\app-$($Context.Configuration).apk"
        $skipInstall = $InstallPolicy -eq 'skip'
        if ($InstallPolicy -eq 'if-changed') {
            $skipInstall = -not (Test-TorChatArtifactDeploymentRequired -RepositoryRoot $Context.RepositoryRoot -Platform 'android' -Target $resolvedDevice -Artifact $artifact)
        }
        $installResult = Invoke-TorChatStage -Context $Context -Id 'deploy.android.install' -Name 'Install Android APK' -Skip:$skipInstall -Action {
            Install-TorChatAndroidClient -Context $Context -Device $resolvedDevice -Artifact $artifact
        }
        if ($installResult.State -eq 'Ready') {
            Set-TorChatArtifactDeployed -RepositoryRoot $Context.RepositoryRoot -Platform 'android' -Target $resolvedDevice -Artifact $artifact -RunId $Context.RunId
        }

        $skipRun = $RunPolicy -eq 'skip'
        if ($RunPolicy -eq 'start' -and -not $skipRun) {
            try {
                $skipRun = (Get-TorChatAndroidStatus -Context $Context -Device $resolvedDevice).State -eq 'Ready'
            } catch {
                $skipRun = $false
            }
        }
        Invoke-TorChatStage -Context $Context -Id 'runtime.android' -Name 'Start Android client' -Skip:$skipRun -Action {
            Start-TorChatAndroidClient -Context $Context -Device $resolvedDevice -ClientDataPolicy $ClientDataPolicy
        }
    }

    if ($Target -in @('windows','all')) {
        $skipWindowsRun = $RunPolicy -eq 'skip'
        if ($RunPolicy -eq 'start' -and -not $skipWindowsRun) {
            $skipWindowsRun = (Get-TorChatWindowsStatus -Context $Context).State -eq 'Ready'
        }
        Invoke-TorChatStage -Context $Context -Id 'runtime.windows' -Name 'Start Windows client' -Skip:$skipWindowsRun -Action {
            Start-TorChatWindowsClient -Context $Context -EnvironmentState $EnvironmentState -ClientDataPolicy $ClientDataPolicy
        }
    }
}

function Invoke-TorChatRunCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ClientDataPolicy,
        [string]$Device
    )
    Assert-TorChatCommandTarget -Target $Target -Allowed @('android','windows','all')
    Import-TorChatEnvironmentState -EnvironmentState $EnvironmentState -RequireOnion
    if ($Target -in @('android','all')) {
        $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device
        Invoke-TorChatStage -Context $Context -Id 'runtime.android' -Name 'Start Android client' -Action {
            Start-TorChatAndroidClient -Context $Context -Device $resolved -ClientDataPolicy $ClientDataPolicy
        }
    }
    if ($Target -in @('windows','all')) {
        Invoke-TorChatStage -Context $Context -Id 'runtime.windows' -Name 'Start Windows client' -Action {
            Start-TorChatWindowsClient -Context $Context -EnvironmentState $EnvironmentState -ClientDataPolicy $ClientDataPolicy
        }
    }
}

function Invoke-TorChatStopCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Device
    )
    Assert-TorChatCommandTarget -Target $Target -Allowed @('android','windows','all')
    if ($Target -in @('android','all')) {
        $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device
        Invoke-TorChatStage -Context $Context -Id 'runtime.android.stop' -Name 'Stop Android client' -Action {
            Stop-TorChatAndroidClient -Context $Context -Device $resolved
        }
    }
    if ($Target -in @('windows','all')) {
        Invoke-TorChatStage -Context $Context -Id 'runtime.windows.stop' -Name 'Stop Windows client' -Action {
            Stop-TorChatWindowsClient -Context $Context
        }
    }
}

function Invoke-TorChatStatusCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Device
    )
    Assert-TorChatCommandTarget -Target $Target -Allowed @('stack','android','windows','all')
    if ($Target -in @('stack','all')) {
        Invoke-TorChatStage -Context $Context -Id 'status.stack' -Name 'Stack status' -Required $false -Action {
            Get-TorChatStackStatus -Context $Context -EnvironmentState $EnvironmentState
        }
    }
    if ($Target -in @('windows','all')) {
        Invoke-TorChatStage -Context $Context -Id 'status.windows' -Name 'Windows status' -Required $false -Action {
            Get-TorChatWindowsStatus -Context $Context
        }
    }
    if ($Target -in @('android','all')) {
        Invoke-TorChatStage -Context $Context -Id 'status.android' -Name 'Android status' -Required $false -Action {
            Get-TorChatAndroidStatus -Context $Context -Device $Device
        }
    }
}

function Invoke-TorChatCleanCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$OnionPolicy,
        [string]$Device,
        [switch]$Confirm
    )
    Assert-TorChatCommandTarget -Target $Target -Allowed @('build','server-data','client-data','all')
    if ($OnionPolicy -eq 'rotate' -and -not $Confirm) {
        throw 'Onion rotation requires -Confirm.'
    }

    if ($Target -in @('build','all')) {
        Invoke-TorChatStage -Context $Context -Id 'clean.build' -Name 'Clean build caches and artifacts' -Action {
            Clear-TorChatBuildState -RepositoryRoot $Context.RepositoryRoot -Artifacts
        }
    }
    if ($Target -in @('server-data','all')) {
        Invoke-TorChatStage -Context $Context -Id 'clean.server' -Name 'Reset server state' -Action {
            Start-TorChatStack -Context $Context -EnvironmentState $EnvironmentState -DatabasePolicy 'reset' -OnionPolicy $OnionPolicy -Readiness 'local'
        }
    }
    if ($Target -in @('client-data','all')) {
        Invoke-TorChatStage -Context $Context -Id 'clean.windows' -Name 'Reset Windows client state' -Required $false -Action {
            Reset-TorChatWindowsClientState -Context $Context
        }
        Invoke-TorChatStage -Context $Context -Id 'clean.android' -Name 'Reset Android client state' -Required $false -Action {
            $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device
            $output = @(& adb -s $resolved shell pm clear org.torchat.mobile 2>&1)
            if ($LASTEXITCODE -ne 0 -or (($output | Out-String) -notmatch 'Success')) {
                throw "Android state reset failed: $(($output -join ' ').Trim())"
            }
            [pscustomobject]@{
                State = 'Ready'
                Code = 'ANDROID_STATE_RESET'
                Message = "Android app data reset on $resolved"
            }
        }
    }
}

function Invoke-TorChatLogsCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Device
    )
    Assert-TorChatCommandTarget -Target $Action -Allowed @('show','collect','export')
    if ($Action -eq 'show') {
        Invoke-TorChatStage -Context $Context -Id 'logs.show' -Name 'Recent TorChat runs' -Action {
            $runs = @(Get-TorChatRecentRuns -RepositoryRoot $Context.RepositoryRoot -Limit 10)
            foreach ($run in $runs) {
                Write-Host ("     {0}  {1}  {2} {3}" -f $run.runId, $run.state, $run.command, $run.target)
            }
            [pscustomobject]@{
                State = 'Ready'
                Code = 'RUNS_LISTED'
                Message = "$($runs.Count) run(s)"
                Runs = $runs
            }
        }
        return
    }

    $collectStage = Invoke-TorChatStage -Context $Context -Id 'logs.collect' -Name 'Collect diagnostics' -Action {
        Collect-TorChatDiagnostics -Context $Context -EnvironmentState $EnvironmentState -Device $Device
    }
    if ($Action -eq 'export') {
        $sourceDirectory = [string]$collectStage.Data.Path
        Invoke-TorChatStage -Context $Context -Id 'logs.export' -Name 'Export diagnostics archive' -Action {
            Export-TorChatDiagnostics -Context $Context -SourceDirectory $sourceDirectory
        }
    }
}

function Invoke-TorChatDeviceCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Device,
        [string]$PairAddress,
        [string]$PairCode
    )
    Assert-TorChatCommandTarget -Target $Action -Allowed @('list','pair','connect','status')
    switch ($Action) {
        'list' {
            Invoke-TorChatStage -Context $Context -Id 'device.list' -Name 'List Android devices' -Action {
                $devices = @(Get-TorChatAndroidDevices)
                foreach ($item in $devices) { Write-Host "     $item" }
                [pscustomobject]@{
                    State = 'Ready'
                    Code = 'ANDROID_DEVICES_LISTED'
                    Message = "$($devices.Count) device(s)"
                    Devices = $devices
                }
            }
        }
        'pair' {
            if (-not $PairAddress -or -not $PairCode) {
                throw 'device pair requires -PairAddress and -PairCode.'
            }
            Invoke-TorChatStage -Context $Context -Id 'device.pair' -Name 'Pair Android device' -Action {
                Pair-TorChatAndroidDevice -Context $Context -Address $PairAddress -Code $PairCode
            }
        }
        'connect' {
            Invoke-TorChatStage -Context $Context -Id 'device.connect' -Name 'Connect Android device' -Action {
                $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device
                [pscustomobject]@{
                    State = 'Ready'
                    Code = 'ANDROID_CONNECTED'
                    Message = $resolved
                    Device = $resolved
                }
            }
        }
        'status' {
            Invoke-TorChatStage -Context $Context -Id 'device.status' -Name 'Android device status' -Required $false -Action {
                Get-TorChatAndroidStatus -Context $Context -Device $Device
            }
        }
    }
}

function Invoke-TorChatCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][hashtable]$Options
    )
    $Context.Metadata['BuildPolicy'] = $Options.BuildPolicy
    Invoke-TorChatPreflight -Context $Context -Command $Command -Target $Target

    switch ($Command) {
        'stack' {
            Invoke-TorChatStackCommand -Context $Context -EnvironmentState $EnvironmentState -Action $Target -BuildPolicy $Options.BuildPolicy -OnionPolicy $Options.OnionPolicy -DatabasePolicy $Options.DatabasePolicy -Readiness $Options.Readiness -NoCache:$Options.NoCache -Confirm:$Options.Confirm
        }
        'build' {
            Invoke-TorChatBuildCommand -Context $Context -EnvironmentState $EnvironmentState -Target $Target -BuildPolicy $Options.BuildPolicy -NoCache:$Options.NoCache
        }
        'deploy' {
            Invoke-TorChatDeployCommand -Context $Context -EnvironmentState $EnvironmentState -Target $Target -BuildPolicy $Options.BuildPolicy -OnionPolicy $Options.OnionPolicy -DatabasePolicy $Options.DatabasePolicy -ClientDataPolicy $Options.ClientDataPolicy -StackPolicy $Options.StackPolicy -InstallPolicy $Options.InstallPolicy -RunPolicy $Options.RunPolicy -Readiness $Options.Readiness -Device $Options.Device -NoCache:$Options.NoCache -Confirm:$Options.Confirm
        }
        'run' {
            Invoke-TorChatRunCommand -Context $Context -EnvironmentState $EnvironmentState -Target $Target -ClientDataPolicy $Options.ClientDataPolicy -Device $Options.Device
        }
        'stop' {
            Invoke-TorChatStopCommand -Context $Context -Target $Target -Device $Options.Device
        }
        'status' {
            Invoke-TorChatStatusCommand -Context $Context -EnvironmentState $EnvironmentState -Target $Target -Device $Options.Device
        }
        'clean' {
            Invoke-TorChatCleanCommand -Context $Context -EnvironmentState $EnvironmentState -Target $Target -OnionPolicy $Options.OnionPolicy -Device $Options.Device -Confirm:$Options.Confirm
        }
        'logs' {
            Invoke-TorChatLogsCommand -Context $Context -EnvironmentState $EnvironmentState -Action $Target -Device $Options.Device
        }
        'device' {
            Invoke-TorChatDeviceCommand -Context $Context -Action $Target -Device $Options.Device -PairAddress $Options.PairAddress -PairCode $Options.PairCode
        }
        default {
            throw "Unsupported command: $Command"
        }
    }
}

Export-ModuleMember -Function 'Invoke-TorChatCommand'
