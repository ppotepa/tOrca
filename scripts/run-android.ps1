[CmdletBinding()]
param(
    [string]$DeviceAddress,
    [switch]$ResetDevState,
    [switch]$Clean,
    [int]$ReadyAttempts = 30
)

$ErrorActionPreference = 'Stop'

function Get-ConnectedDevices {
    @(adb devices 2>$null | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
}

function Get-AppPid {
    param([string]$Device)
    $value = (& adb -s $Device shell pidof -s org.torchat.mobile 2>$null | Out-String).Trim()
    if ($value -match '^\d+$') { return [int]$value }
    return $null
}

function Test-MainActivityResumed {
    param([string]$Device)
    $activity = (& adb -s $Device shell dumpsys activity activities 2>$null | Out-String)
    return (
        $activity -match '(?m)\b(?:mResumedActivity|ResumedActivity|topResumedActivity|Resumed):.*org\.torchat\.mobile/.MainActivity'
    )
}

function Test-ForegroundServiceRunning {
    param([string]$Device)
    $services = (& adb -s $Device shell dumpsys activity services org.torchat.mobile 2>$null | Out-String)
    return $services -match 'TorChatForegroundService'
}

if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { throw 'Missing required tool: adb' }

if (-not $DeviceAddress) {
    $devices = @(Get-ConnectedDevices)
    if ($devices.Count -ne 1) {
        throw "Expected exactly one connected Android device, found $($devices.Count). Use -DeviceAddress."
    }
    $DeviceAddress = $devices[0]
}

if (-not ((Get-ConnectedDevices) -contains $DeviceAddress)) {
    adb connect $DeviceAddress
    if ($LASTEXITCODE -ne 0) { throw "Could not connect to $DeviceAddress." }
}

& adb -s $DeviceAddress shell am force-stop org.torchat.mobile
if ($LASTEXITCODE -ne 0) { throw 'Could not stop the previous Flutter mobile process.' }

$launchArgs = @('-s', $DeviceAddress, 'shell', 'am', 'start', '-W', '-n', 'org.torchat.mobile/.MainActivity')
if ($ResetDevState) { $launchArgs += @('--ez', 'reset_dev_state', 'true') }
if ($Clean) { $launchArgs += @('--ez', 'clean_state', 'true') }
$launchOutput = @(& adb @launchArgs 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Could not launch Flutter mobile app: $(($launchOutput -join ' ').Trim())"
}
$launchText = $launchOutput -join "`n"
if ($launchText -notmatch '(?m)^Status:\s+ok\s*$') {
    throw "Android ActivityManager did not report a successful launch: $launchText"
}

$appPid = $null
$activityReady = $false
$serviceReady = $false
for ($attempt = 1; $attempt -le $ReadyAttempts; $attempt++) {
    Start-Sleep -Milliseconds 500
    $appPid = Get-AppPid -Device $DeviceAddress
    $activityReady = Test-MainActivityResumed -Device $DeviceAddress
    $serviceReady = Test-ForegroundServiceRunning -Device $DeviceAddress
    if ($appPid -and $activityReady -and $serviceReady) { break }
}
if (-not $appPid) { throw 'Android process did not remain alive after launch.' }
if (-not $activityReady) { throw 'Android MainActivity did not reach the resumed state.' }
if (-not $serviceReady) { throw 'TorChatForegroundService did not start.' }

$initialPid = $appPid
Start-Sleep -Seconds 5
$stablePid = Get-AppPid -Device $DeviceAddress
if (-not $stablePid -or $stablePid -ne $initialPid) {
    throw "Android process was not stable for five seconds after launch (initial PID $initialPid, current PID $stablePid)."
}

Write-Host "[torchat] Android app ready on $DeviceAddress (PID $stablePid, Activity resumed, foreground service running)."
