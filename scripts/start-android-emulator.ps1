[CmdletBinding()]
param(
    [string]$Avd,
    [switch]$RunApp,
    [switch]$SkipStack,
    [int]$BootTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

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

$running = @(adb devices | Select-String '^emulator-\d+\s+device$')
if ($running.Count -eq 0) {
    Write-Host "Uruchamiam emulator '$Avd'..."
    Start-Process -FilePath $emulatorPath -ArgumentList @('-avd', $Avd)
} else {
    Write-Host 'Emulator AVD juz dziala. Fizyczne telefony ADB sa ignorowane.'
}

$deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
do {
    Start-Sleep -Seconds 2
    $device = @(adb devices | Select-String '^emulator-\d+\s+device$')
    if ($device.Count -gt 0) { break }
    if ((Get-Date) -gt $deadline) {
        throw "Emulator nie pojawil sie w ADB w ciagu $BootTimeoutSeconds sekund."
    }
} while ($true)

$serial = (($device[0].ToString() -split '\s+')[0]).Trim()
Write-Host "Emulator gotowy: $serial"

if ($RunApp) {
    $args = @('run', 'android', '-Device', $serial)
    if ($SkipStack) { $args += '-StackPolicy'; $args += 'skip' }
    & (Join-Path $repoRoot 'scripts\torchat.ps1') @args
} else {
    Write-Host 'Emulator dziala niezaleznie. Uruchom aplikacje osobno:'
    Write-Host ("  Set-Location '{0}\mobile'; flutter run -d {1}" -f $repoRoot, $serial)
}
