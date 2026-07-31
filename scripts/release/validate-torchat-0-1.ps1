[CmdletBinding()]
param(
    [ValidateSet('all','core','android','windows')]
    [string]$Target = 'all',
    [string]$Device = '',
    [string]$OutputPath,
    [switch]$RequirePlatforms
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$matrixPath = Join-Path $PSScriptRoot 'torchat-0-1-matrix.json'
if (-not (Test-Path -LiteralPath $matrixPath)) {
    throw "Release matrix definition is missing: $matrixPath"
}
$matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json
$results = [System.Collections.Generic.List[object]]::new()

function Get-TorChatGitCommit {
    try {
        $value = (& git -C $repositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
        if ($LASTEXITCODE -eq 0 -and $value) { return $value }
    } catch { }
    return $null
}

function Invoke-TorChatNativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )
    if (-not (Get-Command $Executable -ErrorAction SilentlyContinue)) {
        throw "Required executable is unavailable: $Executable"
    }
    Push-Location $WorkingDirectory
    try {
        & $Executable @Arguments
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            throw "$Executable exited with code $code"
        }
    } finally {
        Pop-Location
    }
}

function Add-TorChatMatrixResult {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][ValidateSet('passed','failed','skipped')][string]$Status,
        [Parameter(Mandatory = $true)][double]$DurationSeconds,
        [string]$Message
    )
    $results.Add([pscustomobject][ordered]@{
        id = $Id
        platform = $Platform
        status = $Status
        durationSeconds = [Math]::Round($DurationSeconds, 3)
        message = $Message
    })
}

function Invoke-TorChatMatrixStep {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "[RUN] $Id ($Platform)"
    try {
        & $Action
        $watch.Stop()
        Add-TorChatMatrixResult -Id $Id -Platform $Platform -Status passed `
            -DurationSeconds $watch.Elapsed.TotalSeconds -Message 'Completed successfully.'
        Write-Host "[PASS] $Id"
    } catch {
        $watch.Stop()
        Add-TorChatMatrixResult -Id $Id -Platform $Platform -Status failed `
            -DurationSeconds $watch.Elapsed.TotalSeconds -Message $_.Exception.Message
        Write-Host "[FAIL] $Id: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Skip-TorChatMatrixStep {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    Add-TorChatMatrixResult -Id $Id -Platform $Platform -Status skipped `
        -DurationSeconds 0 -Message $Reason
    Write-Host "[SKIP] $Id: $Reason" -ForegroundColor Yellow
}

function Test-TorChatAndroidDevice {
    param([string]$RequestedDevice)
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { return $null }
    $devices = @(
        & adb devices 2>$null |
            Select-Object -Skip 1 |
            ForEach-Object { ($_ -split '\s+')[0] } |
            Where-Object { $_ }
    )
    if ($RequestedDevice) {
        return $devices | Where-Object { $_ -eq $RequestedDevice } | Select-Object -First 1
    }
    return $devices | Select-Object -First 1
}

function Assert-TorChatAndroidProcess {
    param([Parameter(Mandatory = $true)][string]$DeviceId)
    Start-Sleep -Seconds 3
    $pidValue = (& adb -s $DeviceId shell pidof org.torchat.mobile 2>$null | Out-String).Trim()
    if (-not $pidValue) {
        throw 'TorChat Android process did not remain alive after launch.'
    }
}

function Start-TorChatWindowsSmokeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Profile
    )
    $process = Start-Process -FilePath $Executable -PassThru -WindowStyle Hidden `
        -Environment @{ APPDATA = $Profile; LOCALAPPDATA = $Profile }
    Start-Sleep -Seconds 5
    if ($process.HasExited -and $process.ExitCode -ne 0) {
        throw "Windows client exited with code $($process.ExitCode)"
    }
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    }
}

$runCore = $Target -in @('all','core')
$runAndroid = $Target -in @('all','android')
$runWindows = $Target -in @('all','windows')

if ($runCore) {
    Invoke-TorChatMatrixStep 'rust-format' 'core' {
        Invoke-TorChatNativeCommand cargo @('fmt','--all','--','--check') $repositoryRoot
    }
    Invoke-TorChatMatrixStep 'runtime-tests' 'core' {
        Invoke-TorChatNativeCommand cargo @('test','-p','torchat-client-runtime') $repositoryRoot
    }
    Invoke-TorChatMatrixStep 'engine-tests' 'core' {
        Invoke-TorChatNativeCommand cargo @('test','-p','torchat-client-engine') $repositoryRoot
    }
    Invoke-TorChatMatrixStep 'ffi-tests' 'core' {
        Invoke-TorChatNativeCommand cargo @('test','-p','torchat-client-engine-ffi') $repositoryRoot
    }
    Invoke-TorChatMatrixStep 'rust-clippy' 'core' {
        Invoke-TorChatNativeCommand cargo @(
            'clippy','-p','torchat-client-runtime','-p','torchat-client-engine',
            '-p','torchat-client-engine-ffi','--all-targets','--','-D','warnings'
        ) $repositoryRoot
    }
    Invoke-TorChatMatrixStep 'diagnostic-sanitization' 'core' {
        & (Join-Path $repositoryRoot 'scripts\tests\test-diagnostic-sanitization.ps1')
        if ($LASTEXITCODE -notin @(0,$null)) {
            throw "Diagnostic sanitization test exited with code $LASTEXITCODE"
        }
    }
    Invoke-TorChatMatrixStep 'flutter-format' 'flutter' {
        Invoke-TorChatNativeCommand dart @(
            'format','--output=none','--set-exit-if-changed','lib','test','integration_test'
        ) (Join-Path $repositoryRoot 'mobile')
    }
    Invoke-TorChatMatrixStep 'flutter-analyze' 'flutter' {
        Invoke-TorChatNativeCommand flutter @('pub','get') (Join-Path $repositoryRoot 'mobile')
        Invoke-TorChatNativeCommand flutter @('analyze') (Join-Path $repositoryRoot 'mobile')
    }
    Invoke-TorChatMatrixStep 'flutter-tests' 'flutter' {
        Invoke-TorChatNativeCommand flutter @('test') (Join-Path $repositoryRoot 'mobile')
    }
}

if ($runAndroid) {
    Invoke-TorChatMatrixStep 'android-debug-build' 'android' {
        Invoke-TorChatNativeCommand flutter @('pub','get') (Join-Path $repositoryRoot 'mobile')
        Invoke-TorChatNativeCommand flutter @('build','apk','--debug') (Join-Path $repositoryRoot 'mobile')
    }

    $resolvedDevice = Test-TorChatAndroidDevice -RequestedDevice $Device
    $androidIds = @(
        'android-clean-install-smoke',
        'android-upgrade-preserves-data',
        'android-cold-start-recovery'
    )
    if ($resolvedDevice) {
        $apk = Join-Path $repositoryRoot 'mobile\build\app\outputs\flutter-apk\app-debug.apk'
        Invoke-TorChatMatrixStep 'android-clean-install-smoke' 'android' {
            if (-not (Test-Path -LiteralPath $apk)) { throw "Android APK is missing: $apk" }
            & adb -s $resolvedDevice uninstall org.torchat.mobile 2>$null | Out-Null
            & adb -s $resolvedDevice install $apk
            if ($LASTEXITCODE -ne 0) { throw "adb install failed with code $LASTEXITCODE" }
            & adb -s $resolvedDevice shell monkey -p org.torchat.mobile 1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Android launch failed with code $LASTEXITCODE" }
            Assert-TorChatAndroidProcess -DeviceId $resolvedDevice
        }
        Invoke-TorChatMatrixStep 'android-upgrade-preserves-data' 'android' {
            & adb -s $resolvedDevice shell run-as org.torchat.mobile sh -c `
                'mkdir -p files && echo release-upgrade-marker > files/release-upgrade-marker'
            if ($LASTEXITCODE -ne 0) { throw 'Unable to seed Android upgrade marker.' }
            & adb -s $resolvedDevice install -r $apk | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "adb upgrade failed with code $LASTEXITCODE" }
            $marker = (& adb -s $resolvedDevice shell run-as org.torchat.mobile `
                cat files/release-upgrade-marker 2>$null | Out-String).Trim()
            if ($marker -ne 'release-upgrade-marker') {
                throw 'Android application data was not preserved across upgrade.'
            }
        }
        Invoke-TorChatMatrixStep 'android-cold-start-recovery' 'android' {
            & adb -s $resolvedDevice shell am force-stop org.torchat.mobile | Out-Null
            & adb -s $resolvedDevice shell monkey -p org.torchat.mobile 1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Android cold start command failed.' }
            Assert-TorChatAndroidProcess -DeviceId $resolvedDevice
        }
    } else {
        $reason = 'No authorized Android device is available; build completed without device validation.'
        foreach ($id in $androidIds) {
            if ($RequirePlatforms) {
                Add-TorChatMatrixResult $id 'android' failed 0 $reason
            } else {
                Skip-TorChatMatrixStep $id 'android' $reason
            }
        }
    }
}

if ($runWindows) {
    if ($env:OS -eq 'Windows_NT') {
        Invoke-TorChatMatrixStep 'windows-debug-build' 'windows' {
            Invoke-TorChatNativeCommand flutter @('config','--enable-windows-desktop') (Join-Path $repositoryRoot 'mobile')
            Invoke-TorChatNativeCommand flutter @('pub','get') (Join-Path $repositoryRoot 'mobile')
            Invoke-TorChatNativeCommand flutter @('build','windows','--debug') (Join-Path $repositoryRoot 'mobile')
        }
        $executable = Join-Path $repositoryRoot 'mobile\build\windows\x64\runner\Debug\torchat_mobile.exe'
        Invoke-TorChatMatrixStep 'windows-clean-profile-smoke' 'windows' {
            if (-not (Test-Path -LiteralPath $executable)) { throw "Windows executable is missing: $executable" }
            $profile = Join-Path ([System.IO.Path]::GetTempPath()) ("torchat-profile-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $profile | Out-Null
            try {
                Start-TorChatWindowsSmokeProcess -Executable $executable -Profile $profile
            } finally {
                Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Invoke-TorChatMatrixStep 'windows-profile-restart-preserves-data' 'windows' {
            if (-not (Test-Path -LiteralPath $executable)) { throw "Windows executable is missing: $executable" }
            $profile = Join-Path ([System.IO.Path]::GetTempPath()) ("torchat-upgrade-profile-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $profile | Out-Null
            try {
                Start-TorChatWindowsSmokeProcess -Executable $executable -Profile $profile
                $marker = Join-Path $profile 'torchat-release-upgrade-marker.txt'
                'release-upgrade-marker' | Set-Content -LiteralPath $marker -Encoding UTF8
                Start-TorChatWindowsSmokeProcess -Executable $executable -Profile $profile
                if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'release-upgrade-marker') {
                    throw 'Windows application profile was not preserved across restart.'
                }
            } finally {
                Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        $reason = 'Windows build and profile smoke tests require a Windows host.'
        foreach ($id in @(
            'windows-debug-build',
            'windows-clean-profile-smoke',
            'windows-profile-restart-preserves-data'
        )) {
            if ($RequirePlatforms) {
                Add-TorChatMatrixResult $id 'windows' failed 0 $reason
            } else {
                Skip-TorChatMatrixStep $id 'windows' $reason
            }
        }
    }
}

if (-not $OutputPath) {
    $outputRoot = Join-Path $repositoryRoot '.torchat\release'
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $OutputPath = Join-Path $outputRoot "torchat-0.1-matrix-$stamp.json"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

$failed = @($results | Where-Object status -eq 'failed')
$skipped = @($results | Where-Object status -eq 'skipped')
$report = [ordered]@{
    schema = 1
    release = '0.1'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    commit = Get-TorChatGitCommit
    host = [ordered]@{
        os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershell = $PSVersionTable.PSVersion.ToString()
    }
    target = $Target
    requirePlatforms = [bool]$RequirePlatforms
    passed = $failed.Count -eq 0 -and (-not $RequirePlatforms -or $skipped.Count -eq 0)
    summary = [ordered]@{
        passed = @($results | Where-Object status -eq 'passed').Count
        failed = $failed.Count
        skipped = $skipped.Count
    }
    steps = @($results)
    manual = @($matrix.manual)
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Release matrix report: $OutputPath"

if (-not $report.passed) { exit 1 }
