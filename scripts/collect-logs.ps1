[CmdletBinding()]
param(
    [ValidateSet('local')]
    [string]$Environment = 'local',
    [string]$DeviceAddress,
    [int]$Tail = 5000,
    [string]$OutputDirectory,
    [switch]$Full
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
    $domainLog = if ($service -eq 'server') { 'server.log' } else { "docker-$service.log" }
    Invoke-Capture (Join-Path $OutputDirectory $domainLog) {
        $logArguments = if ($Full) {
            @('logs', '--timestamps', '--no-color', $service)
        } else {
            @('logs', '--timestamps', '--no-color', '--tail', "$Tail", $service)
        }
        docker @($composeArgs + $logArguments)
    }
}

if ($Full) {
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
        docker events --since 24h --until (Get-Date).ToUniversalTime().ToString('o')
    }
}

$devices = @(if ($DeviceAddress) { $DeviceAddress } else { Get-ConnectedDevices })
if ($devices.Count -gt 0) {
    $device = $devices[0]
    Invoke-Capture (Join-Path $OutputDirectory 'adb-device.txt') {
        adb -s $device shell getprop ro.product.manufacturer
        adb -s $device shell getprop ro.product.model
        adb -s $device shell getprop ro.build.version.release
        adb -s $device shell pidof org.torchat.mobile
    }
    Invoke-Capture (Join-Path $OutputDirectory 'android.log') {
        $logcatArguments = @('-s', $device, 'logcat', '-d', '-v', 'threadtime', '-b', 'all')
        if (-not $Full) { $logcatArguments += @('-t', "$Tail") }
        adb @logcatArguments |
            Select-String -Pattern 'TorChat|AndroidRuntime|Flutter|peer|onion|relay|pairing|readonly database' -CaseSensitive:$false |
            ForEach-Object { $_.Line }
    }
    Invoke-Capture (Join-Path $OutputDirectory 'android-full.log') {
        $logcatArguments = @('-s', $device, 'logcat', '-d', '-v', 'threadtime', '-b', 'all')
        if (-not $Full) { $logcatArguments += @('-t', "$Tail") }
        adb @logcatArguments
    }
    $androidEngineLogs = @(
        adb -s $device shell run-as org.torchat.mobile ls no_backup/engine-logs 2>$null |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^(startup|platform)-[A-Za-z0-9_.-]+\.jsonl$' }
    )
    foreach ($logName in $androidEngineLogs) {
        Invoke-Capture (Join-Path $OutputDirectory "android-$logName") {
            adb -s $device exec-out run-as org.torchat.mobile cat "no_backup/engine-logs/$logName"
        }
    }
    if ($Full) {
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
        $bugreportDirectory = Join-Path $OutputDirectory 'android-bugreport'
        New-Item -ItemType Directory -Force -Path $bugreportDirectory | Out-Null
        Invoke-Capture (Join-Path $OutputDirectory 'android-bugreport-command.txt') {
            adb -s $device bugreport $bugreportDirectory
        }
    }
} else {
    Write-TextFile -Path (Join-Path $OutputDirectory 'android.log') -Text 'No connected ADB device found.'
}

$desktopLogRoot = Join-Path $repoRoot '.torchat\logs'
if (Test-Path -LiteralPath $desktopLogRoot) {
    $desktopLogs = @(Get-ChildItem -LiteralPath $desktopLogRoot -Recurse -Filter 'desktop*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if (-not $Full) { $desktopLogs = @($desktopLogs | Select-Object -First 1) }
    for ($index = 0; $index -lt $desktopLogs.Count; $index++) {
        $destinationName = if ($index -eq 0) { 'desktop.log' } else { "desktop-$($desktopLogs[$index].Name)-$index" }
        Copy-Item -LiteralPath $desktopLogs[$index].FullName -Destination (Join-Path $OutputDirectory $destinationName) -Force
    }
}
$desktopEngineLogRoot = Join-Path $repoRoot '.torchat\clients\desktop\engine-logs'
if (Test-Path -LiteralPath $desktopEngineLogRoot) {
    $engineLogs = @(Get-ChildItem -LiteralPath $desktopEngineLogRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if (-not $Full) { $engineLogs = @($engineLogs | Select-Object -First 10) }
    $engineLogs |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $OutputDirectory "desktop-$($_.Name)") -Force
        }
}

if ($Full) {
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
        Get-ChildItem -LiteralPath $commandLogRoot -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc |
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
        (Join-Path $OutputDirectory 'android.log'),
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

Write-Host "[torchat] Logs collected in $OutputDirectory"
