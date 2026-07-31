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
        # Only commands that change or build the local stack require a healthy
        # Docker engine. Status and diagnostics must remain usable precisely
        # when Docker is broken, and local-only cleanup must work offline.
        $needsDocker = $Context.Environment -eq 'local' -and (
            ($Command -eq 'stack' -and $Target -ne 'status') -or
            $Command -eq 'deploy' -or
            ($Command -eq 'build' -and $Target -in @('server','all')) -or
            ($Command -eq 'clean' -and $Target -in @('server-data','all')) -or
            ($Command -eq 'run' -and $Context.Metadata['StackPolicy'] -eq 'ensure')
        )
        $dockerVersion = ''
        if ($needsDocker) { $dockerVersion = Assert-TorChatDockerEngine -Context $Context }

        if (($Command -eq 'build' -and $Target -eq 'desktop-runtime') -or
            ($Command -eq 'test' -and $Target -in @('runtime','windows','all'))) {
            Assert-TorChatTool -Name cargo
        }
        if (($Command -in @('build','deploy')) -and $Target -in @('android','windows','clients','all')) {
            if ($Context.Metadata['BuildPolicy'] -ne 'skip') {
                Assert-TorChatTool -Name cargo
                Assert-TorChatTool -Name flutter
                if ($Target -in @('android','clients','all')) { Assert-TorChatTool -Name rustup }
            }
        }
        if ($Command -eq 'test' -and $Target -in @('flutter','android','all')) {
            Assert-TorChatTool -Name flutter
        }
        if ($Command -eq 'test' -and $Target -in @('android','all')) {
            Assert-TorChatTool -Name (Join-Path $Context.RepositoryRoot 'mobile\\android\\gradlew.bat')
        }

        $needsAdb = ($Command -in @('deploy','run','stop','clean','device')) -and
            $Target -in @('android','all','list','pair','connect','status','client-data')
        if ($needsAdb) { Assert-TorChatTool -Name adb }

        [pscustomobject]@{
            State = 'Ready'
            Code = 'PREFLIGHT_READY'
            Message = if ($dockerVersion) { "Required tools and Docker engine are ready (server $dockerVersion)" } else { 'Required tools are available' }
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
    Assert-TorChatCommandTarget -Target $Target -Allowed @('server','desktop-runtime','android','windows','clients','all')

    if ($Target -in @('server','all')) {
        Invoke-TorChatStage -Context $Context -Id 'build.server' -Name 'Build relay server image' -Skip:($BuildPolicy -eq 'skip') -Action {
            Build-TorChatServerImage -Context $Context -EnvironmentState $EnvironmentState -NoCache:$NoCache
        }
    }
    if ($Target -eq 'all') {
        Invoke-TorChatStage -Context $Context -Id 'build.torka' -Name 'Build Torka P2P test peer image' -Skip:($BuildPolicy -eq 'skip') -Action {
            Build-TorChatTorkaImage -Context $Context -EnvironmentState $EnvironmentState -NoCache:$NoCache
        }
    }
    if ($Target -eq 'desktop-runtime') {
        Invoke-TorChatStage -Context $Context -Id 'build.windows.engine' -Name 'Build Windows Rust engine' -Skip:($BuildPolicy -eq 'skip') -Action {
            Build-TorChatDesktopEngine -Context $Context -EnvironmentState $EnvironmentState -Policy $BuildPolicy
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

    function Ensure-TorChatWindowsArtifacts {
        param(
            [Parameter(Mandatory = $true)]$Context,
            [Parameter(Mandatory = $true)]$EnvironmentState,
            [Parameter(Mandatory = $true)][string]$BuildPolicy
        )
        if ($env:OS -ne 'Windows_NT') { return }
        $variant = if ($Context.Configuration -eq 'release') { 'Release' } else { 'Debug' }
        $profile = if ($Context.Configuration -eq 'release') { 'release' } else { 'debug' }
        $engine = Join-Path $Context.RepositoryRoot "target\$profile\torchat-desktop.exe"
        $runner = Join-Path $Context.RepositoryRoot "mobile\build\windows\x64\runner\$variant\torchat_mobile.exe"
        if ((Test-Path -LiteralPath $engine) -and (Test-Path -LiteralPath $runner)) { return }

        if ($BuildPolicy -eq 'skip') {
            throw "Windows artifacts are missing (engine: $engine, runner: $runner) and BuildPolicy=skip; rerun with -BuildPolicy smart or -BuildPolicy rebuild."
        }

        Write-TorChatWarning 'Windows runtime artifacts are missing or stale. Rebuilding before start.'
        Build-TorChatDesktopEngine -Context $Context -EnvironmentState $EnvironmentState -Policy $BuildPolicy
        Build-TorChatWindowsClient -Context $Context -EnvironmentState $EnvironmentState -Policy $BuildPolicy
    }

    # Preflight is invoked by Invoke-TorChatCommand before this function. Keep
    # the relay build here so a broken Docker engine fails immediately instead
    # of wasting time in `docker compose build`.
    if ($Target -eq 'all') {
        Invoke-TorChatStage -Context $Context -Id 'build.server' -Name 'Build relay server image' -Skip:($BuildPolicy -eq 'skip') -Action {
            Build-TorChatServerImage -Context $Context -EnvironmentState $EnvironmentState -NoCache:$NoCache
        }
        Invoke-TorChatStage -Context $Context -Id 'build.torka' -Name 'Build Torka P2P test peer image' -Skip:($BuildPolicy -eq 'skip') -Action {
            Build-TorChatTorkaImage -Context $Context -EnvironmentState $EnvironmentState -NoCache:$NoCache
        }
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

    # All stages above deliberately become no-ops in a dry run. Do not try to
    # consume their output afterwards: skipped stages have no device payload.
    if ($Context.DryRun) { return }

    if ($Target -in @('android','all')) {
        $resolveResult = Invoke-TorChatStage -Context $Context -Id 'device.android.resolve' -Name 'Resolve Android device' -Action {
            $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device -AllowMultiple:($Device -eq 'all')
            [string[]]$devices = @($resolved)
            if ($devices.Count -eq 0) {
                throw 'No Android devices resolved.'
            }
            [pscustomobject]@{
                State = 'Ready'
                Code = 'ANDROID_DEVICE_RESOLVED'
                Message = if ($Device -eq 'all') { "all: $($devices -join ', ')" } else { $devices[0] }
                Devices = $devices
                Device = if ($Device -eq 'all') { 'all' } else { $devices[0] }
            }
        }
        $devices = @([string[]]$resolveResult.Data.Devices)
        $Context.Metadata['AndroidDevice'] = if ($Device -eq 'all') { 'all' } else { $devices[0] }

        $artifact = Join-Path $Context.RepositoryRoot "mobile\build\app\outputs\flutter-apk\app-$($Context.Configuration).apk"
        foreach ($resolvedDevice in $devices) {
            $safeDevice = ($resolvedDevice -replace '[^A-Za-z0-9]', '_')
            $Context.Metadata['AndroidDevice'] = $resolvedDevice
            $skipInstall = $InstallPolicy -eq 'skip'
            if ($InstallPolicy -eq 'if-changed') {
                $skipInstall = -not (Test-TorChatArtifactDeploymentRequired -RepositoryRoot $Context.RepositoryRoot -Platform 'android' -Target $resolvedDevice -Artifact $artifact)
            }
            $installResult = Invoke-TorChatStage -Context $Context -Id "deploy.android.install.$safeDevice" -Name "Install Android APK ($resolvedDevice)" -Skip:$skipInstall -Action {
                Install-TorChatAndroidClient -Context $Context -Device $resolvedDevice -Artifact $artifact
            }
            if ($installResult.State -eq 'Ready') {
                Set-TorChatArtifactDeployed -RepositoryRoot $Context.RepositoryRoot -Platform 'android' -Target $resolvedDevice -Artifact $artifact -RunId $Context.RunId
            }
        }

        if ($RunPolicy -ne 'skip') {
            $shouldAvoidRestart = $RunPolicy -eq 'start' -and $ClientDataPolicy -eq 'preserve'
            foreach ($resolvedDevice in $devices) {
                $safeDevice = ($resolvedDevice -replace '[^A-Za-z0-9]', '_')
                $skipRunForDevice = $false
                if ($shouldAvoidRestart) {
                    try {
                        $skipRunForDevice = (Get-TorChatAndroidStatus -Context $Context -Device $resolvedDevice).State -eq 'Ready'
                    } catch {
                        $skipRunForDevice = $false
                    }
                }

                if ($skipRunForDevice) {
                    Invoke-TorChatStage -Context $Context -Id "runtime.android.$safeDevice" -Name "Start Android client ($resolvedDevice)" -Skip:$true -Action {
                        [pscustomobject]@{ State = 'Ready'; Code = 'ANDROID_ALREADY_READY'; Message = "Android already ready on $resolvedDevice"; Device = $resolvedDevice }
                    }
                    continue
                }

                Invoke-TorChatStage -Context $Context -Id "runtime.android.$safeDevice" -Name "Start Android client ($resolvedDevice)" -Action {
                    Start-TorChatAndroidClient -Context $Context -Device $resolvedDevice -ClientDataPolicy $ClientDataPolicy
                }
            }
        }
    }

    if ($Target -in @('windows','all')) {
        $skipWindowsRun = $RunPolicy -eq 'skip'
        if ($RunPolicy -eq 'start' -and $ClientDataPolicy -eq 'preserve' -and -not $skipWindowsRun) {
            $skipWindowsRun = (Get-TorChatWindowsStatus -Context $Context).State -eq 'Ready'
        }
        Ensure-TorChatWindowsArtifacts -Context $Context -EnvironmentState $EnvironmentState -BuildPolicy $BuildPolicy
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
        [Parameter(Mandatory = $true)][string]$StackPolicy,
        [Parameter(Mandatory = $true)][string]$Readiness,
        [int]$ReadyAttempts = 0,
        [string]$Device
    )
    Assert-TorChatCommandTarget -Target $Target -Allowed @('android','windows','all')
    if ($Context.Environment -eq 'local' -and $StackPolicy -eq 'ensure') {
        Invoke-TorChatStage -Context $Context -Id 'stack.ensure' -Name 'Ensure local stack' -Action {
            Start-TorChatStack -Context $Context -EnvironmentState $EnvironmentState -ImagePolicy 'use' -DatabasePolicy 'preserve' -OnionPolicy 'preserve' -Readiness $Readiness
        }
    }
    Import-TorChatEnvironmentState -EnvironmentState $EnvironmentState -RequireOnion
    if ($Target -in @('android','all')) {
        $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device -AllowMultiple:($Device -eq 'all')
        $devices = @([string[]]$resolved)
        if ($devices.Count -eq 0) { throw 'No Android device is available to start.' }
        foreach ($resolvedDevice in $devices) {
            $safeDevice = ($resolvedDevice -replace '[^A-Za-z0-9]', '_')
            Invoke-TorChatStage -Context $Context -Id "runtime.android.$safeDevice" -Name "Start Android client ($resolvedDevice)" -Action {
                $arguments = @{ Context = $Context; Device = $resolvedDevice; ClientDataPolicy = $ClientDataPolicy }
                if ($ReadyAttempts -gt 0) { $arguments.ReadyAttempts = $ReadyAttempts }
                Start-TorChatAndroidClient @arguments
            }
        }
    }
    if ($Target -in @('windows','all')) {
        Invoke-TorChatStage -Context $Context -Id 'runtime.windows' -Name 'Start Windows client' -Action {
            $arguments = @{ Context = $Context; EnvironmentState = $EnvironmentState; ClientDataPolicy = $ClientDataPolicy }
            if ($ReadyAttempts -gt 0) { $arguments.ReadyAttempts = $ReadyAttempts }
            Start-TorChatWindowsClient @arguments
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
        $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device -AllowMultiple:($Device -eq 'all')
        $devices = @([string[]]$resolved)
        if ($devices.Count -eq 0) { throw 'No Android device is available to stop.' }
        foreach ($resolvedDevice in $devices) {
            $safeDevice = ($resolvedDevice -replace '[^A-Za-z0-9]', '_')
            Invoke-TorChatStage -Context $Context -Id "runtime.android.stop.$safeDevice" -Name "Stop Android client ($resolvedDevice)" -Action {
                Stop-TorChatAndroidClient -Context $Context -Device $resolvedDevice
            }
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
        if ($Device -eq 'all') {
            $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device -AllowMultiple:($Device -eq 'all')
            $devices = @([string[]]$resolved)
            if ($devices.Count -eq 0) { throw 'No Android device is available to check status.' }
            foreach ($resolvedDevice in $devices) {
                $safeDevice = ($resolvedDevice -replace '[^A-Za-z0-9]', '_')
                Invoke-TorChatStage -Context $Context -Id "status.android.$safeDevice" -Name "Android status ($resolvedDevice)" -Required $false -Action {
                    Get-TorChatAndroidStatus -Context $Context -Device $resolvedDevice
                }
            }
        } else {
            Invoke-TorChatStage -Context $Context -Id 'status.android' -Name 'Android status' -Required $false -Action {
                Get-TorChatAndroidStatus -Context $Context -Device $Device
            }
        }
    }
}

function Invoke-TorChatTestCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$EnvironmentState,
        [Parameter(Mandatory = $true)][string]$Target
    )
    Assert-TorChatCommandTarget -Target $Target -Allowed @('runtime','flutter','android','windows','all')

    if ($Target -in @('runtime','all')) {
        Invoke-TorChatStage -Context $Context -Id 'test.runtime' -Name 'Test shared runtime' -Action {
            [void](Invoke-TorChatNative -Context $Context -FilePath 'cargo' -ArgumentList @('test','-p','torchat-client-runtime') -WorkingDirectory $Context.RepositoryRoot -LogName 'cargo-test-runtime.log')
            [pscustomobject]@{ State = 'Ready'; Code = 'TEST_RUNTIME_OK'; Message = 'torchat-client-runtime tests passed' }
        }
    }

    if ($Target -in @('flutter','all')) {
        Invoke-TorChatStage -Context $Context -Id 'test.flutter' -Name 'Analyze Flutter client' -Action {
            [void](Invoke-TorChatNative -Context $Context -FilePath 'flutter' -ArgumentList @('analyze','lib') -WorkingDirectory (Join-Path $Context.RepositoryRoot 'mobile') -LogName 'flutter-analyze.log')
            [pscustomobject]@{ State = 'Ready'; Code = 'TEST_FLUTTER_OK'; Message = 'Flutter analyze passed' }
        }
    }

    if ($Target -in @('android','all')) {
        Invoke-TorChatStage -Context $Context -Id 'test.android' -Name 'Compile Android Kotlin' -Action {
            [void](Invoke-TorChatNative -Context $Context -FilePath (Join-Path $Context.RepositoryRoot 'mobile\\android\\gradlew.bat') -ArgumentList @(':app:compileDebugKotlin') -WorkingDirectory (Join-Path $Context.RepositoryRoot 'mobile\\android') -LogName 'android-compile-debug-kotlin.log')
            [pscustomobject]@{ State = 'Ready'; Code = 'TEST_ANDROID_OK'; Message = 'Android Kotlin compile passed' }
        }
    }

    if ($Target -in @('windows','all')) {
        Invoke-TorChatStage -Context $Context -Id 'test.windows' -Name 'Check Windows Rust/Desktop' -Action {
            [void](Invoke-TorChatNative -Context $Context -FilePath 'cargo' -ArgumentList @('check','-p','torchat-client-engine','-p','torchat-desktop') -WorkingDirectory $Context.RepositoryRoot -LogName 'cargo-check-windows-runtime.log')
            [pscustomobject]@{ State = 'Ready'; Code = 'TEST_WINDOWS_OK'; Message = 'Windows Rust/Desktop check passed' }
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
        $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device -AllowMultiple:($Device -eq 'all')
        $devices = @([string[]]$resolved)
        if ($devices.Count -eq 0) { throw 'No Android device is available to reset state.' }
        foreach ($resolved in $devices) {
            $safeDevice = ($resolved -replace '[^A-Za-z0-9]', '_')
            Invoke-TorChatStage -Context $Context -Id "clean.android.$safeDevice" -Name "Reset Android client state ($resolved)" -Required $false -Action {
                $output = @(& adb -s $resolved shell pm clear org.torchat.mobile 2>&1)
                if ($LASTEXITCODE -ne 0 -or (($output | Out-String) -notmatch 'Success')) {
                    throw "Android state reset failed on ${resolved}: $(($output -join ' ').Trim())"
                }
                [pscustomobject]@{
                    State = 'Ready'
                    Code = 'ANDROID_STATE_RESET'
                    Message = "Android app data reset on $resolved"
                }
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
                $command = if ($null -ne $run.PSObject.Properties['command'] -and $run.command) { $run.command } else { '-' }
                $target = if ($null -ne $run.PSObject.Properties['target'] -and $run.target) { $run.target } else { '-' }
                $state = if ($null -ne $run.PSObject.Properties['state'] -and $run.state) { $run.state } else { 'Unknown' }
                Write-Host ("     {0}  {1}  {2} {3}" -f $run.runId, $state, $command, $target)
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
    if ($Context.DryRun) { return }
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
    $Context.Metadata['StackPolicy'] = $Options.StackPolicy
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
            Invoke-TorChatRunCommand -Context $Context -EnvironmentState $EnvironmentState -Target $Target -ClientDataPolicy $Options.ClientDataPolicy -StackPolicy $Options.StackPolicy -Readiness $Options.Readiness -ReadyAttempts $Options.ReadyAttempts -Device $Options.Device
        }
        'stop' {
            Invoke-TorChatStopCommand -Context $Context -Target $Target -Device $Options.Device
        }
        'test' {
            Invoke-TorChatTestCommand -Context $Context -EnvironmentState $EnvironmentState -Target $Target
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
