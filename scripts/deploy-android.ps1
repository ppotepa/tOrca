[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$SkipServer,
    [switch]$SkipCoreBuild,
    [switch]$SkipApkBuild,
    [string]$DeviceAddress,
    [string]$PairingAddress,
    [string]$PairingCode,
    [ValidateSet("", "Alice", "Bob")][string]$DevProfile = "",
    [switch]$NoDevPair,
    [switch]$ResetDevState,
    [switch]$Release,
    [switch]$Clean,
    [ValidateSet('local','staging','production')][string]$Environment = 'local'
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$mobileRoot = Join-Path $repoRoot "mobile"
$variant = if ($Release) { "release" } else { "debug" }
$apk = Join-Path $mobileRoot "build\app\outputs\flutter-apk\app-$variant.apk"
. (Join-Path $PSScriptRoot "internal\environment.ps1")
$environmentState = Ensure-TorChatEnvironment $repoRoot $Environment

function Get-ConnectedDevices {
    @(adb devices 2>$null | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
}

function Find-MdnsConnectAddresses {
    $text = adb mdns services 2>&1 | Out-String
    @($text -split "`r?`n" | Where-Object {
        $_ -match '_adb-tls-connect' -and $_ -match '\d{1,3}(?:\.\d{1,3}){3}:\d+'
    } | ForEach-Object {
        if ($_ -match '(\d{1,3}(?:\.\d{1,3}){3}:\d+)') { $Matches[1] }
    } | Select-Object -Unique)
}

function Wait-ConnectedMdnsDevice {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        foreach ($address in @(Find-MdnsConnectAddresses)) {
            if ((Get-ConnectedDevices) -contains $address) { return $address }
            $connectOutput = adb connect $address 2>&1 | Out-String
            Write-Host $connectOutput.Trim()
            if ($LASTEXITCODE -eq 0 -and (Get-ConnectedDevices) -contains $address) {
                return $address
            }
        }
        if ($attempt -lt 10) { Start-Sleep -Seconds 2 }
    }
    return $null
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
    return $activity -match 'mResumedActivity.*org\.torchat\.mobile/.MainActivity'
}

function Test-ForegroundServiceRunning {
    param([string]$Device)
    $services = (& adb -s $Device shell dumpsys activity services org.torchat.mobile 2>$null | Out-String)
    return $services -match 'TorChatForegroundService'
}

if ($PairingAddress) {
    if (-not $PairingCode) { throw "PairingCode is required with PairingAddress." }
    adb pair $PairingAddress $PairingCode
    if ($LASTEXITCODE -ne 0) { throw "ADB pairing failed." }
}

if (-not $DeviceAddress) {
    $devices = @(Get-ConnectedDevices)
    $wifiDevices = @($devices | Where-Object {
        $_ -match '^\d{1,3}(?:\.\d{1,3}){3}:\d+$'
    })
    if ($wifiDevices.Count -eq 1) {
        $DeviceAddress = $wifiDevices[0]
    } elseif ($wifiDevices.Count -gt 1) {
        $discovered = @(Find-MdnsConnectAddresses)
        $connectedDiscovery = @($wifiDevices | Where-Object { $discovered -contains $_ })
        if ($connectedDiscovery.Count -gt 0) {
            $DeviceAddress = $connectedDiscovery[0]
        } else {
            throw "Multiple Wi-Fi devices detected. Use -DeviceAddress to select one."
        }
    } elseif ($devices.Count -eq 1) {
        $DeviceAddress = $devices[0]
    } elseif ($devices.Count -gt 1) {
        $DeviceAddress = Wait-ConnectedMdnsDevice
        if (-not $DeviceAddress) {
            throw "Multiple devices detected and no Wi-Fi endpoint could be resolved. Use -DeviceAddress."
        }
    } else {
        $DeviceAddress = Wait-ConnectedMdnsDevice
        if (-not $DeviceAddress) {
            throw "No paired Wireless Debugging device found after 20 seconds. Enable Wireless debugging on the unlocked phone."
        }
    }
}

if (-not ((Get-ConnectedDevices) -contains $DeviceAddress)) {
    adb connect $DeviceAddress
    if ($LASTEXITCODE -ne 0) { throw "Could not connect to $DeviceAddress." }
}

if ($Clean) {
    Write-Host "[torchat] Scheduling Android client state reset on $DeviceAddress"
    & adb -s $DeviceAddress shell am force-stop org.torchat.mobile
    if ($LASTEXITCODE -ne 0) { throw "Could not stop TorChat before cleaning Android state." }
}

if (-not $SkipServer) {
    if ($Environment -ne 'local') { throw "Android deployment for '$Environment' uses its remote host; use -SkipServer." }
    & (Join-Path $PSScriptRoot 'start-dev.ps1') -Rebuild:$Rebuild -Environment local
    if ($LASTEXITCODE -ne 0) { throw "Development stack failed to start." }
}

if (-not $SkipCoreBuild) {
    Write-Host "Building Rust client engine for Flutter Android..."
    & (Join-Path $PSScriptRoot "internal\build-android-core.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Rust Android engine build failed." }
}

if (-not $SkipApkBuild) {
    Push-Location $mobileRoot
    try {
        Import-TorChatEnvironment $environmentState -RequireOnion
        $previousConfigFile = $env:TORCHAT_CONFIG_FILE
        $env:TORCHAT_CONFIG_FILE = $environmentState.Paths.RuntimeEnvironment
        $previousProfile = $env:TORCHAT_DEV_PROFILE
        $previousPair = $env:TORCHAT_DEV_PAIR
        if (-not $Release) {
            $fixturesEnabled = $environmentState.Values['TORCHAT_FIXTURES'] -eq 'true' -and -not $NoDevPair
            $selectedDevProfile = if ($fixturesEnabled) {
                if ($DevProfile) { $DevProfile } else { "Alice" }
            } else {
                ""
            }
            $env:TORCHAT_DEV_PROFILE = $selectedDevProfile
            $env:TORCHAT_DEV_PAIR = if ($fixturesEnabled) { "true" } else { "false" }
        } else {
            Remove-Item Env:TORCHAT_DEV_PROFILE -ErrorAction SilentlyContinue
            $env:TORCHAT_DEV_PAIR = "false"
        }
        flutter build apk --$variant
        if ($LASTEXITCODE -ne 0) { throw "Flutter APK build failed." }
    } finally {
        $env:TORCHAT_DEV_PROFILE = $previousProfile
        $env:TORCHAT_DEV_PAIR = $previousPair
        $env:TORCHAT_CONFIG_FILE = $previousConfigFile
        Pop-Location
    }
} elseif (-not (Test-Path -LiteralPath $apk)) {
    throw "APK not found at $apk. Run rebuild first or omit -SkipApkBuild."
}

$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$installArgs = @("-s", $DeviceAddress, "install", "-r")
$installArgs += @("--no-streaming", $apk)
$installOutput = @(& adb @installArgs 2>&1)
$installExitCode = $LASTEXITCODE
$ErrorActionPreference = $savedErrorActionPreference
if ($installExitCode -ne 0) {
    $details = ($installOutput -join " ").Trim()
    if ($details -match "INSTALL_FAILED_USER_RESTRICTED") {
        Write-Warning "ADB install was restricted; trying adb push + pm install on $DeviceAddress."
        $remoteApk = "/data/local/tmp/torchat-mobile-$variant.apk"
        $savedFallbackErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $pushOutput = @(& adb -s $DeviceAddress push $apk $remoteApk 2>&1)
        if ($LASTEXITCODE -eq 0) {
            $pmOutput = @(& adb -s $DeviceAddress shell pm install -r $remoteApk 2>&1)
            $pmExitCode = $LASTEXITCODE
            & adb -s $DeviceAddress shell rm -f $remoteApk *> $null
            if ($pmExitCode -eq 0) {
                Write-Host "TorChat APK installed through package manager on $DeviceAddress"
                $installExitCode = 0
            } else {
                $fallbackDetails = (($pushOutput + $pmOutput) -join " ").Trim()
                $details = (($installOutput + $fallbackDetails) -join " ").Trim()
            }
        } else {
            $pushDetails = ($pushOutput -join " ").Trim()
            $details = (($installOutput + $pushDetails) -join " ").Trim()
        }
        $ErrorActionPreference = $savedFallbackErrorActionPreference
    }
    if ($installExitCode -ne 0 -and $details -match "INSTALL_FAILED_USER_RESTRICTED") {
        $manufacturer = (& adb -s $DeviceAddress shell getprop ro.product.manufacturer 2>$null | Out-String).Trim()
        $deviceHint = if ($manufacturer -match "Xiaomi|Redmi|POCO") {
            "On Xiaomi/HyperOS enable Developer options > USB debugging (Security settings) and Install via USB; accept any Xiaomi-account/security confirmation and keep the phone unlocked."
        } else {
            "On the phone enable Developer options > Install via USB (and USB debugging security settings, if present), unlock the phone and accept the installation prompt."
        }
        throw "Android blocked APK installation from ADB (INSTALL_FAILED_USER_RESTRICTED). $deviceHint`nInstall diagnostics: $details`nThen run the script again."
    }
    if ($installExitCode -ne 0) { throw "Flutter APK installation failed: $details" }
}

& adb -s $DeviceAddress shell am force-stop org.torchat.mobile
if ($LASTEXITCODE -ne 0) { throw "Could not stop the previous Flutter mobile process." }

$launchArgs = @("-s", $DeviceAddress, "shell", "am", "start", "-W", "-n", "org.torchat.mobile/.MainActivity")
if ($ResetDevState) { $launchArgs += @("--ez", "reset_dev_state", "true") }
if ($Clean) { $launchArgs += @("--ez", "clean_state", "true") }
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
for ($attempt = 1; $attempt -le 30; $attempt++) {
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
