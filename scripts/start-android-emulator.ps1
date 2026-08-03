[CmdletBinding()]
param(
    [string]$Avd,
    [switch]$RunApp,
    [switch]$SkipStack,
    [int]$BootTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$emulatorLogDirectory = Join-Path $repoRoot '.torchat\logs'
New-Item -ItemType Directory -Force -Path $emulatorLogDirectory | Out-Null
$emulatorStdout = Join-Path $emulatorLogDirectory 'android-emulator.stdout.log'
$emulatorStderr = Join-Path $emulatorLogDirectory 'android-emulator.stderr.log'

$sdkRoot = $env:ANDROID_SDK_ROOT
if ([string]::IsNullOrWhiteSpace($sdkRoot)) { $sdkRoot = $env:ANDROID_HOME }
$emulatorPath = if (-not [string]::IsNullOrWhiteSpace($sdkRoot)) {
    Join-Path $sdkRoot 'emulator\emulator.exe'
} else { $null }
if (-not $emulatorPath -or -not (Test-Path -LiteralPath $emulatorPath)) {
    $emulatorPath = (Get-Command emulator.exe -ErrorAction SilentlyContinue).Source
}
if (-not $emulatorPath -or -not (Test-Path -LiteralPath $emulatorPath)) {
    throw 'Nie znaleziono emulator.exe. Ustaw ANDROID_SDK_ROOT albo dodaj Android SDK emulator do PATH.'
}

$avdManagerPath = if (-not [string]::IsNullOrWhiteSpace($sdkRoot)) {
    Join-Path $sdkRoot 'cmdline-tools\latest\bin\avdmanager.bat'
} else { $null }

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Nie znaleziono '$Name'. Dodaj Android SDK/platform-tools i emulator do PATH."
    }
}

Require-Command 'adb'

if ([string]::IsNullOrWhiteSpace($Avd)) {
    $avds = @(& $emulatorPath -list-avds | Where-Object { $_.Trim() })
    if ($avds.Count -eq 0) {
        throw 'Brak skonfigurowanych AVD. Utworz emulator w Android Studio -> Device Manager.'
    }

    if ($avds.Count -eq 1) {
        $Avd = $avds[0].Trim()
    } else {
        Write-Host 'Dostepne emulatory:'
        for ($index = 0; $index -lt $avds.Count; $index++) {
            Write-Host ("[{0}] {1}" -f ($index + 1), $avds[$index].Trim())
        }
        $choice = Read-Host 'Wybierz numer emulatora'
        if (-not [int]::TryParse($choice, [ref]$selectedIndex) -or
            $selectedIndex -lt 1 -or $selectedIndex -gt $avds.Count) {
            throw 'Nieprawidlowy wybor emulatora.'
        }
        $Avd = $avds[$selectedIndex - 1].Trim()
    }
}

if ($RunApp) {
    Write-Host 'Buduje TorChat APK (arm64 + x86_64)...'
    $buildParameters = @{
        Command = 'build'
        Target = 'android'
        BuildPolicy = 'smart'
    }
    if ($SkipStack) { $buildParameters.StackPolicy = 'skip' }
    & (Join-Path $repoRoot 'scripts\torchat.ps1') @buildParameters
    if (-not $?) { throw 'Build TorChat APK zakonczyl sie bledem.' }
}

$running = @(adb devices | Select-String '^emulator-\d+\s+device$')
if ($running.Count -eq 0) {
    # A failed emulator boot can leave only its lightweight launcher alive.
    # It still owns the AVD lock but has no adb device or QEMU child. Stop only
    # launchers for this exact AVD before retrying.
    $staleLaunchers = @(Get-CimInstance Win32_Process -Filter "Name = 'emulator.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*-avd $Avd*" })
    foreach ($launcher in $staleLaunchers) {
        Stop-Process -Id $launcher.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Uruchamiam emulator '$Avd'..."
    # Redirecting the console launcher's streams prevents extra cmd windows.
    # The Android emulator GUI remains visible.
    $emulatorProcess = Start-Process -FilePath $emulatorPath `
        -ArgumentList @('-avd', $Avd, '-no-snapshot-load', '-no-snapshot-save') `
        -WindowStyle Hidden `
        -RedirectStandardOutput $emulatorStdout `
        -RedirectStandardError $emulatorStderr `
        -PassThru
} else {
    Write-Host 'Emulator AVD juz dziala. Fizyczne telefony ADB sa ignorowane.'
}

$deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
do {
    Start-Sleep -Seconds 2
    $device = @(adb devices | Select-String '^emulator-\d+\s+device$')
    if ($device.Count -gt 0) { break }
    if ($emulatorProcess -and $emulatorProcess.HasExited) {
        $details = if (Test-Path -LiteralPath $emulatorStderr) {
            (Get-Content -LiteralPath $emulatorStderr -Tail 20 | Out-String).Trim()
        } else { 'brak logu emulatora' }
        throw "Emulator zakonczyl dzialanie przed rejestracja w ADB. $details"
    }
    if ((Get-Date) -gt $deadline) {
        throw "Emulator nie pojawil sie w ADB w ciagu $BootTimeoutSeconds sekund."
    }
} while ($true)

$serial = (($device[0].ToString() -split '\s+')[0]).Trim()
$bootDeadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
do {
    $bootCompleted = (& adb -s $serial shell getprop sys.boot_completed 2>$null | Out-String).Trim()
    $bootAnimation = (& adb -s $serial shell getprop init.svc.bootanim 2>$null | Out-String).Trim()
    if ($bootCompleted -eq '1' -and $bootAnimation -eq 'stopped') { break }
    if ((Get-Date) -gt $bootDeadline) {
        throw "Android nie zakonczyl uruchamiania w ciagu $BootTimeoutSeconds sekund."
    }
    Start-Sleep -Seconds 2
} while ($true)

& adb -s $serial wait-for-device | Out-Null
Write-Host "Emulator gotowy: $serial ($Avd)"

if ($RunApp) {
    # `run android` assumes that an APK is already installed. `deploy android`
    # owns the complete build -> install -> launch flow and pins every adb
    # operation to this emulator, regardless of connected physical phones.
    $deployParameters = @{
        Command = 'deploy'
        Target = 'android'
        Device = $serial
        BuildPolicy = 'skip'
        InstallPolicy = 'always'
        RunPolicy = 'restart'
    }
    if ($SkipStack) { $deployParameters.StackPolicy = 'skip' }
    & (Join-Path $repoRoot 'scripts\torchat.ps1') @deployParameters
    if (-not $?) {
        throw "Deploy TorChat na $serial zakonczyl sie bledem."
    }
} else {
    Write-Host 'Emulator dziala niezaleznie. Uruchom aplikacje osobno:'
    Write-Host ("  .\scripts\start-android-emulator.ps1 -Avd {0} -RunApp -SkipStack" -f $Avd)
}
