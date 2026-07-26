[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$SkipServer,
    [switch]$SkipCoreBuild,
    [switch]$SkipApkBuild,
    [string]$DeviceAddress,
    [string]$PairingAddress,
    [string]$PairingCode,
    [ValidateSet("Alice", "Bob")][string]$DevProfile = "Alice",
    [switch]$NoDevPair,
    [switch]$ResetDevState
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$mobileRoot = Join-Path $repoRoot "apps\mobile"
$apk = Join-Path $mobileRoot "build\app\outputs\flutter-apk\app-debug.apk"

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
        # ADB can expose the same phone twice: once as an mDNS service name
        # and once as its concrete Wi-Fi endpoint. Prefer the routable address.
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

if (-not $SkipServer) {
    & (Join-Path $PSScriptRoot "start-dev.ps1") -Rebuild:$Rebuild
    if ($LASTEXITCODE -ne 0) { throw "Development stack failed to start." }
}

if (-not $SkipCoreBuild) {
    Write-Host "Building Rust identity/MLS core for Flutter Android..."
    & (Join-Path $PSScriptRoot "internal\build-android-core.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Rust Android core build failed." }
}

if (-not $SkipApkBuild) {
    Push-Location $mobileRoot
    try {
        $previousProfile = $env:TORCHAT_DEV_PROFILE
        $previousPair = $env:TORCHAT_DEV_PAIR
        $env:TORCHAT_DEV_PROFILE = $DevProfile
        $env:TORCHAT_DEV_PAIR = if ($NoDevPair) { "false" } else { "true" }
        flutter build apk --debug
        if ($LASTEXITCODE -ne 0) { throw "Flutter APK build failed." }
    } finally {
        $env:TORCHAT_DEV_PROFILE = $previousProfile
        $env:TORCHAT_DEV_PAIR = $previousPair
        Pop-Location
    }
} elseif (-not (Test-Path -LiteralPath $apk)) {
    throw "APK not found at $apk. Run rebuild first or omit -SkipApkBuild."
}

$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$installOutput = @(adb -s $DeviceAddress install -r --no-streaming $apk 2>&1)
$installExitCode = $LASTEXITCODE
$ErrorActionPreference = $savedErrorActionPreference
if ($installExitCode -ne 0) {
    $details = ($installOutput -join " ").Trim()
    throw "Flutter APK installation failed: $details`nOn the phone enable Developer options > Install via USB (and USB debugging security settings, if present), unlock the phone and accept the installation prompt, then run the script again."
}
adb -s $DeviceAddress shell am force-stop org.torchat.mobile
if ($LASTEXITCODE -ne 0) { throw "Could not stop the previous Flutter mobile process." }
$launchArgs = @("-s", $DeviceAddress, "shell", "am", "start", "-n", "org.torchat.mobile/.MainActivity")
if ($ResetDevState) {
    # Reset from inside the debug app after a successful install. This keeps
    # the old working APK intact when Android rejects an installation.
    $launchArgs += @("--ez", "reset_dev_state", "true")
}
& adb @launchArgs
if ($LASTEXITCODE -ne 0) { throw "Could not launch Flutter mobile app." }
Write-Host "TorChat Flutter mobile deployed to $DeviceAddress"
