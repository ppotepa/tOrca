[CmdletBinding()]
param(
    [ValidateSet('local')]
    [string]$Environment = 'local',
    [string]$DeviceAddress,
    [int]$Tail = 5000,
    [string]$OutputDirectory
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
foreach ($service in @('tor', 'server', 'postgres')) {
    $domainLog = if ($service -eq 'server') { 'server.log' } else { "docker-$service.log" }
    Invoke-Capture (Join-Path $OutputDirectory $domainLog) {
        docker @($composeArgs + @('logs', '--tail', "$Tail", $service))
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
        adb -s $device logcat -d -v time -t $Tail `
            'TorChat-Runtime:V' 'TorChat-Tor:V' 'TorChat-SOCKS:V' 'TorChat-Pairing:V' 'TorChat-Onion:V' `
            'TorChat-Relay:V' 'AndroidRuntime:E' 'Flutter:V' 'ActivityTaskManager:I' '*:S'
    }
} else {
    Write-TextFile -Path (Join-Path $OutputDirectory 'android.log') -Text 'No connected ADB device found.'
}

$desktopLogRoot = Join-Path $repoRoot '.torchat\logs'
if (Test-Path -LiteralPath $desktopLogRoot) {
    Get-ChildItem -LiteralPath $desktopLogRoot -Recurse -Filter 'desktop*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $OutputDirectory 'desktop.log') -Force }
}

Invoke-Capture (Join-Path $OutputDirectory 'desktop-processes.txt') {
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -in @('torchat_mobile.exe', 'torchat-desktop.exe', 'tor.exe') } |
        Select-Object ProcessId, Name, ExecutablePath, CommandLine |
        Format-List
}

Write-Host "[torchat] Logs collected in $OutputDirectory"
