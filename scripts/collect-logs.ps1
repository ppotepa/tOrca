[CmdletBinding()]
param(
    [ValidateSet('local')]
    [string]$Environment = 'local',
    [string]$DeviceAddress,
    [int]$Tail = 5000,
    [string]$OutputDirectory,
    [switch]$Full,
    [switch]$AllHistory,
    [switch]$IncludeBugreport
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'internal\environment.ps1')

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Text = ''
    )
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
}

function Invoke-Capture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )
    try {
        $output = & $Command 2>&1 | Out-String
        Write-TextFile -Path $Path -Text $output.TrimEnd()
    } catch {
        Write-TextFile -Path $Path -Text $_.Exception.ToString()
    }
}

function Get-ConnectedDevices {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { return @() }
    @(adb devices 2>$null | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
}

function Write-LogStage {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[torchat][logs] $Message"
}

function Get-LastRunStart {
    param([Parameter(Mandatory = $true)][string]$Root)
    $commandLogRoot = Join-Path $Root '.torchat\command-logs'
    $runLogs = @(Get-ChildItem -LiteralPath $commandLogRoot -File -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '-(run-desktop|redeploy|full-deploy|deploy-mobile|start-dev)-' } |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach ($runLog in $runLogs) {
        if ($runLog.Name -match '^(?<stamp>\d{8}-\d{6}-\d{3})-') {
            try {
                return [DateTime]::ParseExact(
                    $Matches['stamp'],
                    'yyyyMMdd-HHmmss-fff',
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeLocal
                )
            } catch { }
        }
    }
    # If no command transcript exists yet, limit diagnostics to a recent
    # window instead of silently exporting the entire Android log buffer.
    (Get-Date).AddHours(-6)
}

$date = Get-Date -Format 'yyyyMMdd'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputDirectory) {
    $dateDirectory = Join-Path $repoRoot ".torchat\logs\$date"
    New-Item -ItemType Directory -Force -Path $dateDirectory | Out-Null
    $existingRuns = @(Get-ChildItem -LiteralPath $dateDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^run-\d{4}$' } |
        ForEach-Object { [int]$_.Name.Substring(4) })
    [int]$nextRun = if ($existingRuns.Count -gt 0) {
        [int](($existingRuns | Measure-Object -Maximum).Maximum) + 1
    } else {
        1
    }
    $OutputDirectory = Join-Path $dateDirectory ("run-{0:D4}" -f $nextRun)
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$lastRunStart = if ($AllHistory) { $null } else { Get-LastRunStart $repoRoot }
$lastRunStartIso = if ($lastRunStart) { $lastRunStart.ToUniversalTime().ToString('o') } else { $null }
$adbLogcatSince = if ($lastRunStart) { $lastRunStart.ToString('MM-dd HH:mm:ss.fff') } else { $null }
$lastRunEpochMs = if ($lastRunStart) {
    ([DateTimeOffset]$lastRunStart.ToUniversalTime()).ToUnixTimeMilliseconds()
} else { $null }
$collectionMode = if ($AllHistory) { 'all-history' } else { 'latest-run' }
$runWindow = @(
    "mode=$collectionMode"
    "start=$([string]$lastRunStart)"
    "startUtc=$([string]$lastRunStartIso)"
    "includeBugreport=$IncludeBugreport"
) -join [Environment]::NewLine
Write-TextFile -Path (Join-Path $OutputDirectory 'run-window.txt') -Text $runWindow

Write-LogStage "Output directory: $OutputDirectory"
Write-LogStage 'Collecting sanitized environment and Docker state...'
$environmentState = Ensure-TorChatEnvironment $repoRoot $Environment
$compose = Join-Path $repoRoot 'infra\docker\compose.dev.yml'
$composeArgs = @(
    'compose',
    '--project-name', $environmentState.Values['TORCHAT_COMPOSE_PROJECT'],
    '--env-file', $environmentState.Paths.RuntimeEnvironment,
    '-f', $compose
)

Invoke-Capture (Join-Path $OutputDirectory 'environment.txt') {
    $safe = $environmentState.Values.Clone()
    foreach ($key in @('TORCHAT_DATABASE_PASSWORD', 'TORCHAT_PAIRING_SECRET')) {
        if ($safe.ContainsKey($key)) { $safe[$key] = '<redacted>' }
    }
    $safe.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }
}

Invoke-Capture (Join-Path $OutputDirectory 'docker-ps.txt') {
    docker @($composeArgs + @('ps'))
}
Invoke-Capture (Join-Path $OutputDirectory 'docker-inspect.txt') {
    docker @($composeArgs + @('ps', '-a'))
    foreach ($service in @('tor', 'server', 'postgres')) {
        docker @($composeArgs + @('ps', '-q', $service))
        docker @($composeArgs + @('inspect', '--format', '{{json .State}}', "$($environmentState.Values['TORCHAT_COMPOSE_PROJECT'])-$service-1") )
    }
}
Invoke-Capture (Join-Path $OutputDirectory 'health.txt') {
    $httpUrl = 'http://127.0.0.1:{0}/health' -f $environmentState.Values['TORCHAT_HTTP_PORT']
    try { Invoke-RestMethod -Uri $httpUrl -TimeoutSec 5 | ConvertTo-Json -Compress } catch { "HTTP health failed: $($_.Exception.Message)" }
    $onion = $environmentState.Values['TORCHAT_ONION_URL']
    if ($onion -match '^https?://[a-z2-7]{56}\.onion$') {
        try {
            curl.exe --silent --show-error --fail-with-body --max-time 20 --socks5-hostname "127.0.0.1:$($environmentState.Values['TORCHAT_SOCKS_PORT'])" "$onion/health"
        } catch { "Onion health failed: $($_.Exception.Message)" }
    } else { 'Onion health skipped: no valid TORCHAT_ONION_URL.' }
}
foreach ($service in @('tor', 'server', 'postgres')) {
    Write-LogStage "Collecting complete $service logs..."
    $domainLog = if ($service -eq 'server') { 'server.log' } else { "docker-$service.log" }
    Invoke-Capture (Join-Path $OutputDirectory $domainLog) {
        $logArguments = if ($Full) {
            if ($lastRunStartIso) {
                @('logs', '--timestamps', '--no-color', '--since', $lastRunStartIso, $service)
            } else {
                @('logs', '--timestamps', '--no-color', $service)
            }
        } else {
            @('logs', '--timestamps', '--no-color', '--tail', "$Tail", $service)
        }
        docker @($composeArgs + $logArguments)
    }
}

if ($Full) {
    Write-LogStage 'Collecting extended Docker diagnostics...'
    Invoke-Capture (Join-Path $OutputDirectory 'docker-info.txt') {
        docker info
        docker version
        docker system df -v
    }
    Invoke-Capture (Join-Path $OutputDirectory 'docker-container-inspect.jsonl') {
        $containerIds = @(docker @($composeArgs + @('ps', '-aq')))
        foreach ($containerId in $containerIds) {
            if ($containerId) {
                $inspection = @(docker inspect $containerId | ConvertFrom-Json)[0]
                if ($inspection.Config) {
                    $inspection.Config.Env = @('<redacted: container environment omitted>')
                }
                $inspection | ConvertTo-Json -Depth 20 -Compress
            }
        }
    }
    Invoke-Capture (Join-Path $OutputDirectory 'docker-events-last-24h.txt') {
        $eventsSince = if ($lastRunStartIso) { $lastRunStartIso } else { '24h' }
        docker events --since $eventsSince --until (Get-Date).ToUniversalTime().ToString('o')
    }
}

$devices = @(if ($DeviceAddress) { $DeviceAddress } else { Get-ConnectedDevices })
if ($devices.Count -gt 0) {
    $device = $devices[0]
    Write-LogStage "Collecting Android diagnostics from $device..."
    $appPid = (adb -s $device shell pidof org.torchat.mobile 2>$null | Out-String).Trim()
    $appPid = ($appPid -split '\s+')[0]
    $bufferDescription = if ($AllHistory) { 'main,system,crash' } else { 'main,system' }
    $androidFilterInfo = @(
        "package=org.torchat.mobile"
        "pid=$appPid"
        "buffers=$bufferDescription"
        "since=$lastRunStartIso"
        "mode=$collectionMode"
    ) -join [Environment]::NewLine
    Write-TextFile -Path (Join-Path $OutputDirectory 'android-filter.json') -Text $androidFilterInfo
    if ($appPid) {
        Write-LogStage "Android app PID $appPid; restricting logcat to the app process..."
    } else {
        Write-LogStage 'Android app PID is unavailable; using TorChat tags and crash buffer filters.'
    }
    Invoke-Capture (Join-Path $OutputDirectory 'adb-device.txt') {
        adb -s $device shell getprop ro.product.manufacturer
        adb -s $device shell getprop ro.product.model
        adb -s $device shell getprop ro.build.version.release
        adb -s $device shell pidof org.torchat.mobile
    }
    Invoke-Capture (Join-Path $OutputDirectory 'android-app.log') {
        $logcatArguments = @('-s', $device, 'logcat', '-d', '-v', 'threadtime', '-b', 'main,system')
        if ($appPid) { $logcatArguments += "--pid=$appPid" }
        if ($Full -and $adbLogcatSince) {
            $logcatArguments += @('-T', $adbLogcatSince)
        } elseif (-not $Full) {
            $logcatArguments += @('-t', "$Tail")
        }
        adb @logcatArguments |
            Select-String -Pattern 'TorChat|AndroidRuntime|Flutter|peer|onion|relay|pairing|readonly database' -CaseSensitive:$false |
            ForEach-Object { $_.Line }
    }
    Invoke-Capture (Join-Path $OutputDirectory 'android-crash.log') {
        $crashArguments = @('-s', $device, 'logcat', '-d', '-v', 'threadtime', '-b', 'crash')
        if ($Full -and $adbLogcatSince) {
            $crashArguments += @('-T', $adbLogcatSince)
        } elseif (-not $Full) {
            $crashArguments += @('-t', "$Tail")
        }
        adb @crashArguments |
            Select-String -Pattern 'org\.torchat\.mobile|torchat|AndroidRuntime|Flutter|rust|panic|abort|F DEBUG|Fatal signal|backtrace|HandleUsingDestroyedMutex' -CaseSensitive:$false |
            ForEach-Object { $_.Line }
    }
    if ($AllHistory) {
        Write-LogStage 'All-history mode: retaining the raw Android logcat buffer...'
        Invoke-Capture (Join-Path $OutputDirectory 'android-full.log') {
            adb -s $device logcat -d -v threadtime -b all
        }
    }
    $androidEngineLogs = @(
        adb -s $device shell run-as org.torchat.mobile ls -t no_backup/engine-logs 2>$null |
            ForEach-Object { $_.Trim() } |
            Where-Object {
                if ($_ -notmatch '^(startup|platform)-(?<epoch>\d+)-[A-Za-z0-9_.-]+\.jsonl$') { return $false }
                if ($AllHistory -or -not $lastRunEpochMs) { return $true }
                [int64]$Matches['epoch'] -ge [int64]$lastRunEpochMs
            } |
            ForEach-Object -Begin { $count = 0 } -Process {
                if ($AllHistory -or $count -lt 10) { $count++; $_ }
            }
    )
    if (-not $AllHistory -and $androidEngineLogs.Count -eq 0) {
        $androidEngineLogs = @(
            adb -s $device shell run-as org.torchat.mobile ls -t no_backup/engine-logs 2>$null |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match '^(startup|platform)-[A-Za-z0-9_.-]+\.jsonl$' } |
                Select-Object -First 4
        )
    }
    foreach ($logName in $androidEngineLogs) {
        Write-LogStage "Copying Android engine journal $logName..."
        Invoke-Capture (Join-Path $OutputDirectory "android-$logName") {
            adb -s $device exec-out run-as org.torchat.mobile cat "no_backup/engine-logs/$logName"
        }
    }
        if ($Full) {
        Write-LogStage 'Collecting Android power, network, process and scheduler state...'
        foreach ($diagnostic in @(
            @{ Name = 'android-dumpsys-activity.txt'; Args = @('dumpsys', 'activity', 'services', 'org.torchat.mobile') },
            @{ Name = 'android-dumpsys-package.txt'; Args = @('dumpsys', 'package', 'org.torchat.mobile') },
            @{ Name = 'android-dumpsys-power.txt'; Args = @('dumpsys', 'power') },
            @{ Name = 'android-dumpsys-deviceidle.txt'; Args = @('dumpsys', 'deviceidle') },
            @{ Name = 'android-dumpsys-connectivity.txt'; Args = @('dumpsys', 'connectivity') },
            @{ Name = 'android-dumpsys-jobscheduler.txt'; Args = @('dumpsys', 'jobscheduler') },
            @{ Name = 'android-dumpsys-alarm.txt'; Args = @('dumpsys', 'alarm') },
            @{ Name = 'android-processes.txt'; Args = @('ps', '-A') }
        )) {
            Invoke-Capture (Join-Path $OutputDirectory $diagnostic.Name) {
                adb -s $device shell @($diagnostic.Args)
            }
        }
        Invoke-Capture (Join-Path $OutputDirectory 'android-app-files.txt') {
            adb -s $device shell run-as org.torchat.mobile find . -maxdepth 4 -type f -printf '%p %s bytes %TY-%Tm-%TdT%TH:%TM:%TS\n'
        }
        if ($IncludeBugreport) {
            $bugreportDirectory = Join-Path $OutputDirectory 'android-bugreport'
            New-Item -ItemType Directory -Force -Path $bugreportDirectory | Out-Null
            $bugreportStatusPath = Join-Path $OutputDirectory 'android-bugreport-command.txt'
            Write-LogStage 'Generating full Android bugreport; this commonly takes several minutes...'
            $bugreportStartedAt = Get-Date
            $bugreportProcess = Start-Process -FilePath (Get-Command adb).Source `
                -ArgumentList @('-s', $device, 'bugreport', $bugreportDirectory) `
                -NoNewWindow `
                -PassThru
            while (-not $bugreportProcess.WaitForExit(1000)) {
                $elapsed = [int]((Get-Date) - $bugreportStartedAt).TotalSeconds
                Write-Progress -Activity 'TorChat snapshot logs' `
                    -Status "Android bugreport: ${elapsed}s elapsed" `
                    -PercentComplete -1
                if ($elapsed -gt 0 -and ($elapsed % 10) -eq 0) {
                    Write-Host "[torchat][logs] Android bugreport is still running (${elapsed}s)..."
                }
            }
            Write-Progress -Activity 'TorChat snapshot logs' -Completed
            if ($bugreportProcess.ExitCode -ne 0) {
                Write-TextFile -Path $bugreportStatusPath -Text "adb bugreport failed with exit code $($bugreportProcess.ExitCode)."
                throw "adb bugreport failed with exit code $($bugreportProcess.ExitCode)."
            }
            $elapsed = [int]((Get-Date) - $bugreportStartedAt).TotalSeconds
            Write-TextFile -Path $bugreportStatusPath -Text "adb bugreport completed in ${elapsed}s."
            Write-LogStage "Android bugreport completed in ${elapsed}s."
        } else {
            Write-LogStage 'Skipping Android bugreport (use -IncludeBugreport to collect it).'
        }
    }
} else {
    Write-TextFile -Path (Join-Path $OutputDirectory 'android-app.log') -Text 'No connected ADB device found.'
}

$desktopLogRoot = Join-Path $repoRoot '.torchat\logs'
Write-LogStage 'Collecting desktop runtime and engine journals...'
if (Test-Path -LiteralPath $desktopLogRoot) {
    $desktopLogs = @(Get-ChildItem -LiteralPath $desktopLogRoot -Recurse -Filter 'desktop*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if (-not $AllHistory -and $lastRunStart) {
        $latestWindowLogs = @($desktopLogs | Where-Object { $_.LastWriteTime -ge $lastRunStart })
        if ($latestWindowLogs.Count -gt 0) {
            $desktopLogs = @($latestWindowLogs)
        } else {
            $desktopLogs = @($desktopLogs | Select-Object -First 1)
        }
    } elseif (-not $Full) { $desktopLogs = @($desktopLogs | Select-Object -First 1) }
    $desktopLogs = @($desktopLogs)
    for ($index = 0; $index -lt $desktopLogs.Count; $index++) {
        $destinationName = if ($index -eq 0) { 'desktop.log' } else { "desktop-$($desktopLogs[$index].Name)-$index" }
        Copy-Item -LiteralPath $desktopLogs[$index].FullName -Destination (Join-Path $OutputDirectory $destinationName) -Force
    }
}
$desktopEngineLogRoot = Join-Path $repoRoot '.torchat\clients\desktop\engine-logs'
if (Test-Path -LiteralPath $desktopEngineLogRoot) {
    $engineLogs = @(Get-ChildItem -LiteralPath $desktopEngineLogRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if (-not $AllHistory -and $lastRunStart) {
        $latestWindowLogs = @($engineLogs | Where-Object { $_.LastWriteTime -ge $lastRunStart })
        if ($latestWindowLogs.Count -gt 0) {
            $engineLogs = @($latestWindowLogs)
        } else {
            $engineLogs = @($engineLogs | Select-Object -First 10)
        }
    } elseif (-not $Full) { $engineLogs = @($engineLogs | Select-Object -First 10) }
    $engineLogs = @($engineLogs)
    $engineLogs |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $OutputDirectory "desktop-$($_.Name)") -Force
        }
}

if ($Full) {
    Write-LogStage 'Collecting Windows system, network and event diagnostics...'
    Invoke-Capture (Join-Path $OutputDirectory 'windows-system.txt') {
        Get-ComputerInfo
    }
    Invoke-Capture (Join-Path $OutputDirectory 'windows-network.txt') {
        Get-NetAdapter | Format-List
        Get-NetIPConfiguration | Format-List
        Get-NetTCPConnection | Sort-Object LocalPort | Format-Table -AutoSize
    }
    Invoke-Capture (Join-Path $OutputDirectory 'windows-application-events.txt') {
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddHours(-24) } -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProviderName -match 'Application Error|Windows Error Reporting|torchat|flutter|rust|tor'
            } |
            Format-List TimeCreated, Id, LevelDisplayName, ProviderName, Message
    }
    $commandLogRoot = Join-Path $repoRoot '.torchat\command-logs'
    if (Test-Path -LiteralPath $commandLogRoot) {
        $commandLogDestination = Join-Path $OutputDirectory 'command-transcripts'
        New-Item -ItemType Directory -Force -Path $commandLogDestination | Out-Null
        $commandLogs = @(Get-ChildItem -LiteralPath $commandLogRoot -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending)
        if (-not $AllHistory) {
            $commandLogs = @($commandLogs | Where-Object { $_.LastWriteTime -ge $lastRunStart })
        }
        $commandLogs |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $commandLogDestination $_.Name) -Force
            }
    }
}

Invoke-Capture (Join-Path $OutputDirectory 'desktop-processes.txt') {
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -in @('torchat_mobile.exe', 'torchat-desktop.exe', 'tor.exe') } |
        Select-Object ProcessId, Name, ExecutablePath, CommandLine |
        Format-List
}

Invoke-Capture (Join-Path $OutputDirectory 'startup-summary.txt') {
        $sources = @(
            (Join-Path $OutputDirectory 'android-app.log'),
            (Join-Path $OutputDirectory 'android-crash.log'),
            (Join-Path $OutputDirectory 'desktop.log'),
        (Join-Path $OutputDirectory 'server.log'),
        (Join-Path $OutputDirectory 'docker-tor.log')
        (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'android-*.jsonl' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'desktop-*.jsonl' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $patterns = 'startup_|relay connect failed|relay disconnected|Host unreachable|onion service|Tor SOCKS|peer endpoint|pairing|error|failed'
    foreach ($source in $sources) {
        Write-Output "--- $([IO.Path]::GetFileName($source)) ---"
        Select-String -LiteralPath $source -Pattern $patterns -CaseSensitive:$false |
            Select-Object -Last 200 |
            ForEach-Object { $_.Line }
    }
}

Write-LogStage 'Log collection completed.'
Write-Host "[torchat] Logs collected in $OutputDirectory"
