Set-StrictMode -Version Latest

function Get-TorChatAndroidWifiDeviceRegex {
    # adb wireless debugging can appear either as host:port or as the mDNS
    # transport serial (adb-<id>._adb-tls-connect._tcp). Treat both as Wi-Fi
    # so auto-selection does not reject a USB + wireless duplicate.
    return '^(?:\d{1,3}(?:\.\d{1,3}){3}:\d+|adb-.+_adb-tls-connect\._tcp)$'
}

function Test-TorChatAndroidDeviceIsWifi {
    param(
        [Parameter(Mandatory = $true)][string]$Device
    )
    return $Device -match (Get-TorChatAndroidWifiDeviceRegex)
}

function Format-TorChatAndroidDeviceSummary {
    param(
        [string[]]$Devices
    )
    $wifiRegex = Get-TorChatAndroidWifiDeviceRegex
    $wifiDevices = @($Devices | Where-Object { $_ -match $wifiRegex })
    $usbDevices = @($Devices | Where-Object { $_ -notmatch $wifiRegex })
    $parts = @()
    if ($wifiDevices.Count -gt 0) { $parts += ('Wi-Fi: ' + ($wifiDevices -join ', ')) }
    if ($usbDevices.Count -gt 0) { $parts += ('USB: ' + ($usbDevices -join ', ')) }
    if ($parts.Count -eq 0) { return 'none' }
    return ($parts -join '; ')
}

function Get-TorChatAndroidDevices {
    Assert-TorChatTool -Name adb
    return @(
        adb devices 2>$null |
            Where-Object { $_ -match '^\S+\s+device$' } |
            ForEach-Object { ($_ -split '\s+')[0] }
    )
}

function Find-TorChatAndroidMdnsAddresses {
    Assert-TorChatTool -Name adb
    $text = adb mdns services 2>&1 | Out-String
    return @($text -split "`r?`n" | Where-Object {
        $_ -match '_adb-tls-connect' -and $_ -match '^\d{1,3}(?:\.\d{1,3}){3}:\d+'
    } | ForEach-Object {
        if ($_ -match '(\d{1,3}(?:\.\d{1,3}){3}:\d+)') { $Matches[1] }
    } | Select-Object -Unique)
}

function Connect-TorChatAndroidMdnsDevices {
    param(
        [Parameter(Mandatory = $true)]$Context
    )
    Assert-TorChatTool -Name adb
    $connected = New-Object System.Collections.Generic.List[string]
    foreach ($address in @(Find-TorChatAndroidMdnsAddresses)) {
        $output = @(& adb connect $address 2>&1)
        if ($Context.Verbosity -eq 'trace' -and $output) {
            $output | ForEach-Object { Write-TorChatInfo ([string]$_) }
        }
        if ($LASTEXITCODE -eq 0) {
            [void]$connected.Add($address)
        }
    }
    return @($connected)
}

function Resolve-TorChatAndroidDevice {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$Device,
        [int]$DiscoveryTimeoutSeconds = 20,
        [switch]$AllowMultiple
    )
    Assert-TorChatTool -Name adb
    $wifiRegex = Get-TorChatAndroidWifiDeviceRegex

    if ($Device -eq 'all' -and -not $AllowMultiple) {
        throw "Use -AllowMultiple with -Device all."
    }

    if ($Device -and $Device -ne 'auto') {
        if ((Get-TorChatAndroidDevices) -notcontains $Device) {
            if ($Device -match $wifiRegex) {
                [void](Invoke-TorChatNative -Context $Context -FilePath 'adb' -ArgumentList @('connect',$Device) -LogName 'adb-connect.log' -AllowedExitCodes @(0,1))
            } else {
                [void](Connect-TorChatAndroidMdnsDevices -Context $Context)
            }
        }
        $devices = @(Get-TorChatAndroidDevices)
        if ($devices -contains $Device) { return $Device }
        if ($AllowMultiple -and $Device -eq 'all') { return $devices }
        if ($devices.Count -eq 1) { return $devices[0] }
        throw "Android device is unavailable: $Device"
    }

    $devices = @(Get-TorChatAndroidDevices)
    if ($devices.Count -eq 1) { return $devices[0] }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($DiscoveryTimeoutSeconds)
    do {
        [void](Connect-TorChatAndroidMdnsDevices -Context $Context)
        $devices = @(Get-TorChatAndroidDevices)
        if ($devices.Count -eq 1) { return $devices[0] }
        if ($AllowMultiple) { return $devices }

        $wifiDevices = @($devices | Where-Object { $_ -match $wifiRegex })
        $usbDevices = @($devices | Where-Object { $_ -notmatch $wifiRegex })
        if ($wifiDevices.Count -eq 1) {
            return $wifiDevices[0]
        }

        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $wifiDevices = @($devices | Where-Object { $_ -match $wifiRegex })
    $usbDevices = @($devices | Where-Object { $_ -notmatch $wifiRegex })
    if ($wifiDevices.Count -gt 1 -and $usbDevices.Count -eq 0) {
        throw "Multiple Wi-Fi devices are connected. Provide -Device <serial-or-host:port> to select one explicitly. Available: $($wifiDevices -join ', ')"
    }
    if ($wifiDevices.Count -ge 1 -and $usbDevices.Count -ge 1) {
        throw "Multiple Android devices are connected (multiple transports). Prefer Wi-Fi one for default. Select one with -Device <serial-or-host:port>. Detected: $(Format-TorChatAndroidDeviceSummary -Devices $devices)"
    }
    if ($devices.Count -gt 1) { throw 'Multiple Android devices are connected. Select one with -Device <serial-or-host:port>.' }
    if ($devices.Count -eq 0) {
        throw 'No Android device is available. Enable USB or Wireless debugging and pair the device first.'
    }
    throw "Unable to resolve Android device. Available devices: $(Format-TorChatAndroidDeviceSummary -Devices $devices)"
}

function Pair-TorChatAndroidDevice {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Code
    )
    [void](Invoke-TorChatNative -Context $Context -FilePath 'adb' -ArgumentList @('pair',$Address,$Code) -LogName 'adb-pair.log')
    [pscustomobject]@{ State = 'Ready'; Code = 'ANDROID_PAIRED'; Message = "Paired with $Address"; Device = $Address }
}

function Get-TorChatAndroidAppPid {
    param([Parameter(Mandatory = $true)][string]$Device)
    $value = (& adb -s $Device shell pidof -s org.torchat.mobile 2>$null | Out-String).Trim()
    if ($value -match '^\d+$') { return [int]$value }
    return $null
}

function Test-TorChatAndroidActivityResumed {
    param([Parameter(Mandatory = $true)][string]$Device)
    $activity = (& adb -s $Device shell dumpsys activity activities 2>$null | Out-String)
    return $activity -match '(?m)\b(?:mResumedActivity|ResumedActivity|topResumedActivity|Resumed):.*org\.torchat\.mobile/.MainActivity'
}

function Test-TorChatAndroidServiceRunning {
    param([Parameter(Mandatory = $true)][string]$Device)
    $services = (& adb -s $Device shell dumpsys activity services org.torchat.mobile 2>$null | Out-String)
    return $services -match 'TorChatForegroundService'
}

function Test-TorChatAndroidEngineReady {
    param([Parameter(Mandatory = $true)][string]$Device, [Parameter(Mandatory = $true)][int]$AppPid)
    # The foreground service normally shares the application process, but OEMs
    # can briefly report a different PID while the service is being attached.
    # Check both the Activity PID and the engine/service tags so readiness does
    # not fail during that hand-off.
    $appLogs = (& adb -s $Device logcat -d --pid=$AppPid -v brief 2>$null | Out-String)
    $engineLogs = (& adb -s $Device logcat -d -v brief 'TorChat-Engine:*' 'TorChat-Lifecycle:*' '*:S' 2>$null | Out-String)
    $logs = "$appLogs`n$engineLogs"
    return ($logs -match 'engine_initialized' -or $logs -match 'Foreground service client engine initialized')
}

function Save-TorChatAndroidDiagnostics {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Device)
    $root = Join-Path $Context.RunDirectory 'android-diagnostics'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    & adb -s $Device shell dumpsys activity activities 2>&1 | Out-File -LiteralPath (Join-Path $root 'activity.txt') -Encoding utf8
    & adb -s $Device shell dumpsys activity services org.torchat.mobile 2>&1 | Out-File -LiteralPath (Join-Path $root 'services.txt') -Encoding utf8
    $appPid = Get-TorChatAndroidAppPid -Device $Device
    if ($appPid) {
        & adb -s $Device logcat -d --pid=$appPid -v threadtime 2>&1 | Out-File -LiteralPath (Join-Path $root 'app-logcat.txt') -Encoding utf8
    }
    & adb -s $Device logcat -d -v threadtime 'TorChat-Engine:*' 'TorChat-Tor:*' 'AndroidRuntime:E' 'ActivityManager:W' '*:S' 2>&1 |
        Out-File -LiteralPath (Join-Path $root 'filtered-logcat.txt') -Encoding utf8

    # Avoid `sh -c` here: PowerShell/adb quoting can consume the wildcard or
    # redirection before Android's shell sees it. Listing the private directory
    # directly is stable across USB and wireless adb transports.
    $journalListing = @(& adb -s $Device shell run-as org.torchat.mobile ls -t no_backup/engine-logs 2>$null) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '\.jsonl$' }
    $startupJournal = $journalListing | Where-Object { $_ -match 'startup-.*\.jsonl$' } | Select-Object -First 1
    $platformJournal = $journalListing | Where-Object { $_ -match 'platform-.*\.jsonl$' } | Select-Object -First 1
    foreach ($journal in @(
        @{ Entry = $startupJournal; Name = 'startup-journal.jsonl' },
        @{ Entry = $platformJournal; Name = 'platform-journal.jsonl' }
    )) {
        if ($journal.Entry) {
            $remotePath = "no_backup/engine-logs/$($journal.Entry.Trim())"
            & adb -s $Device shell run-as org.torchat.mobile cat $remotePath 2>&1 |
                Out-File -LiteralPath (Join-Path $root $journal.Name) -Encoding utf8
        } else {
            "missing Android engine journal: $($journal.Name)" |
                Out-File -LiteralPath (Join-Path $root $journal.Name) -Encoding utf8
        }
    }
    return $root
}

function Get-TorChatAndroidApplicationReadiness {
    param([Parameter(Mandatory = $true)][string]$Device)
    $listing = @(& adb -s $Device shell run-as org.torchat.mobile ls -t no_backup/engine-logs 2>$null) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^(?:startup|platform)-.*\.jsonl$' }
    $latest = $listing | Select-Object -First 1
    if (-not $latest) {
        return [pscustomobject]@{ Engine = $false; PeerEndpoint = $false; Ready = $false }
    }
    $events = @(& adb -s $Device shell run-as org.torchat.mobile cat "no_backup/engine-logs/$latest" 2>$null) |
        ForEach-Object {
            try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        }
    $engineReady = @($events | Where-Object {
        $_.component -eq 'engine' -and $_.message -eq 'client engine actor started for Android'
    }).Count -gt 0
    $peerEndpointReady = @($events | Where-Object {
        $_.component -eq 'peer' -and (
            ($_.eventCode -eq 'onion_ready' -and $_.state -eq 'ready') -or
            ($_.eventCode -eq 'peer_endpoint_changed' -and $_.message -match '(?:^|\s)status=Verified(?:\s|$)')
        )
    }).Count -gt 0
    [pscustomobject]@{
        Engine = $engineReady
        PeerEndpoint = $peerEndpointReady
        # The rendezvous relay is connected only while pairing. Normal
        # application readiness requires the local engine and onion endpoint.
        Ready = $engineReady -and $peerEndpointReady
    }
}

function Test-TorChatAndroidApplicationReady {
    param([Parameter(Mandatory = $true)][string]$Device)
    return (Get-TorChatAndroidApplicationReadiness -Device $Device).Ready
}

function Stop-TorChatAndroidClient {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Device)
    [void](Invoke-TorChatNative -Context $Context -FilePath 'adb' -ArgumentList @('-s',$Device,'shell','am','force-stop','org.torchat.mobile') -LogName 'adb-stop.log')
    [pscustomobject]@{ State = 'Ready'; Code = 'ANDROID_STOPPED'; Message = "Android client stopped on $Device"; Device = $Device }
}

function Install-TorChatAndroidClient {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Device,
        [string]$Artifact
    )
    if (-not $Artifact) {
        $Artifact = Join-Path $Context.RepositoryRoot "mobile\build\app\outputs\flutter-apk\app-$($Context.Configuration).apk"
    }
    if (-not (Test-Path -LiteralPath $Artifact)) { throw "Android APK not found: $Artifact" }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $apkArchive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Artifact).Path)
        $apkArchive.Dispose()
    } catch {
        throw "Android APK is invalid or incomplete: $Artifact. Rebuild with -BuildPolicy rebuild before installing. $($_.Exception.Message)"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& adb -s $Device install -r --no-streaming $Artifact 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    ($output | Out-String) | Set-Content -LiteralPath (Join-Path $Context.LogDirectory 'adb-install.log') -Encoding UTF8
    if ($exitCode -ne 0) {
        $details = ($output -join ' ').Trim()
        if ($details -match 'INSTALL_FAILED_USER_RESTRICTED') {
            $remote = "/data/local/tmp/torchat-$($Context.Configuration)-$($Context.RunId).apk"
            $pushErrorPath = Join-Path $Context.LogDirectory 'adb-push.stderr.log'
            $push = @(& adb -s $Device push $Artifact $remote 2>$pushErrorPath)
            if (Test-Path -LiteralPath $pushErrorPath) {
                $push += @(Get-Content -LiteralPath $pushErrorPath -ErrorAction SilentlyContinue)
            }
            if ($LASTEXITCODE -eq 0) {
                $pmErrorPath = Join-Path $Context.LogDirectory 'adb-pm-install.stderr.log'
                $install = @(& adb -s $Device shell pm install -r $remote 2>$pmErrorPath)
                $pmExit = $LASTEXITCODE
                if (Test-Path -LiteralPath $pmErrorPath) {
                    $install += @(Get-Content -LiteralPath $pmErrorPath -ErrorAction SilentlyContinue)
                }
                & adb -s $Device shell rm -f $remote *> $null
                if ($pmExit -eq 0) { $exitCode = 0 } else { $details = (($output + $push + $install) -join ' ').Trim() }
            }
        }
        if ($exitCode -ne 0) { throw "Android APK installation failed on ${Device}: $details" }
    }
    [pscustomobject]@{ State = 'Ready'; Code = 'ANDROID_INSTALLED'; Message = "APK installed on $Device"; Device = $Device; Artifact = $Artifact }
}

function Start-TorChatAndroidClient {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Device,
        [ValidateSet('preserve','reset')][string]$ClientDataPolicy = 'preserve',
        [int]$ReadyAttempts = 40,
        [int]$FunctionalReadyAttempts = 180
    )
    Assert-TorChatTool -Name adb
    $resolvedDevice = Resolve-TorChatAndroidDevice -Context $Context -Device $Device -DiscoveryTimeoutSeconds 20
    [void](Stop-TorChatAndroidClient -Context $Context -Device $resolvedDevice)
    & adb -s $resolvedDevice logcat -c *> $null

    $args = @('-s',$resolvedDevice,'shell','am','start','-W','-n','org.torchat.mobile/.MainActivity','--es','deploy_run_id',$Context.RunId)
    if ($ClientDataPolicy -eq 'reset') { $args += @('--ez','clean_state','true') }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $launch = @(& adb @args 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    ($launch | Out-String) | Set-Content -LiteralPath (Join-Path $Context.LogDirectory 'adb-start.log') -Encoding UTF8
    if ($exitCode -ne 0) { throw "Could not start Android client: $(($launch -join ' ').Trim())" }
    $launchText = $launch -join "`n"
    if ($launchText -notmatch '(?m)^Status:\s+ok\s*$') { throw "Android ActivityManager did not report Status: ok. $launchText" }

    $appPid = $null
    $activityReady = $false
    $serviceReady = $false
    $engineReady = $false
    for ($attempt = 1; $attempt -le $ReadyAttempts; $attempt++) {
        Start-Sleep -Milliseconds 500
        # A few OEM builds can leave the first Activity launch in a restore
        # transition without delivering onStart/onCreate's service request.
        # Relaunching the already-idempotent singleTask Activity is safe and
        # gives it a second opportunity to hand off to the foreground service.
        if ($attempt -eq 10 -and -not $serviceReady) {
            @(& adb -s $resolvedDevice shell am start -S -W -n org.torchat.mobile/.MainActivity `
                    --es deploy_run_id $Context.RunId 2>&1) |
                Out-File -LiteralPath (Join-Path $Context.LogDirectory 'adb-retry-start-10.log') -Encoding utf8
        } elseif ($attempt -eq 25 -and -not $serviceReady) {
            @(& adb -s $resolvedDevice shell am start -n org.torchat.mobile/.MainActivity 2>&1) |
                Out-File -LiteralPath (Join-Path $Context.LogDirectory 'adb-retry-start-25.log') -Encoding utf8
        }
        $appPid = Get-TorChatAndroidAppPid -Device $resolvedDevice
        $activityReady = Test-TorChatAndroidActivityResumed -Device $resolvedDevice
        $serviceReady = Test-TorChatAndroidServiceRunning -Device $resolvedDevice
        $engineReady = if ($appPid) { Test-TorChatAndroidEngineReady -Device $resolvedDevice -AppPid $appPid } else { $false }
        $percent = [Math]::Min(99, [int](100 * $attempt / [Math]::Max(1,$ReadyAttempts)))
        Write-TorChatStageProgress -Context $Context -Name 'Android runtime' -Percent $percent -Detail "pid=$appPid activity=$activityReady service=$serviceReady engine=$engineReady"
        if ($appPid -and $activityReady -and $serviceReady -and $engineReady) { break }
    }
    if (-not $appPid -or -not $activityReady -or -not $serviceReady -or -not $engineReady) {
        $diagnostics = Save-TorChatAndroidDiagnostics -Context $Context -Device $resolvedDevice
        throw "Android did not reach APP_READY/ENGINE_READY. Diagnostics: $diagnostics"
    }
    $applicationReadiness = $null
    $applicationReady = $false
    for ($attempt = 1; $attempt -le $FunctionalReadyAttempts; $attempt++) {
        $applicationReadiness = Get-TorChatAndroidApplicationReadiness -Device $resolvedDevice
        $applicationReady = $applicationReadiness.Ready
        $percent = [Math]::Min(99, [int](100 * $attempt / [Math]::Max(1,$FunctionalReadyAttempts)))
        Write-TorChatStageProgress -Context $Context -Name 'Android application readiness' -Percent $percent -Detail "engine=$($applicationReadiness.Engine) p2p=$($applicationReadiness.PeerEndpoint)"
        if ($applicationReady) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $applicationReady) {
        $diagnostics = Save-TorChatAndroidDiagnostics -Context $Context -Device $resolvedDevice
        throw "Android process started, but the engine/onion endpoint did not reach APPLICATION_READY. Diagnostics: $diagnostics"
    }
    $initialPid = $appPid
    Start-Sleep -Seconds 5
    $stablePid = Get-TorChatAndroidAppPid -Device $resolvedDevice
    if (-not $stablePid -or $stablePid -ne $initialPid) {
        $diagnostics = Save-TorChatAndroidDiagnostics -Context $Context -Device $resolvedDevice
        throw "Android process was not stable for five seconds. Diagnostics: $diagnostics"
    }
    [pscustomobject]@{ State = 'Ready'; Code = 'ANDROID_READY'; Message = "Android application ready on $resolvedDevice (PID $stablePid)"; Device = $resolvedDevice; Pid = $stablePid }
}

function Get-TorChatAndroidStatus {
    param([Parameter(Mandatory = $true)]$Context, [string]$Device)
    $resolved = Resolve-TorChatAndroidDevice -Context $Context -Device $Device -DiscoveryTimeoutSeconds 3
    $appPid = Get-TorChatAndroidAppPid -Device $resolved
    $ready = $false
    if ($appPid) {
        $ready = (Test-TorChatAndroidActivityResumed -Device $resolved) -and
            (Test-TorChatAndroidServiceRunning -Device $resolved) -and
            (Test-TorChatAndroidApplicationReady -Device $resolved)
    }
    [pscustomobject]@{
        State = if ($ready) { 'Ready' } else { 'Warning' }
        Code = if ($ready) { 'ANDROID_RUNNING' } else { 'ANDROID_NOT_READY' }
        Message = "device=$resolved pid=$appPid ready=$ready"
        Device = $resolved
        Pid = $appPid
    }
}

Export-ModuleMember -Function @(
    'Get-TorChatAndroidDevices','Find-TorChatAndroidMdnsAddresses','Resolve-TorChatAndroidDevice','Pair-TorChatAndroidDevice',
    'Install-TorChatAndroidClient','Start-TorChatAndroidClient','Stop-TorChatAndroidClient','Get-TorChatAndroidStatus','Save-TorChatAndroidDiagnostics',
    'Connect-TorChatAndroidMdnsDevices'
)
