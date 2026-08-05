[CmdletBinding()]
param(
    [ValidateSet('all', 'core', 'android', 'windows')]
    [string]$Target = 'all',
    [string]$Device = '',
    [string]$OutputPath,
    [switch]$RequirePlatforms,
    [switch]$BuildAndroidBundle,
    [string]$UpdateKeyId,
    [string]$UpdatePublicKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).Path
$versionPath = Join-Path $repositoryRoot 'release/version.json'
$matrixPath = Join-Path $PSScriptRoot 'torca-release-matrix.json'
foreach ($required in @($versionPath, $matrixPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Release definition is missing: $required"
    }
}
$release = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
$matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json
$results = [System.Collections.Generic.List[object]]::new()
$artifacts = [System.Collections.Generic.List[object]]::new()

function Get-Commit {
    $value = (& git -C $repositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw 'Unable to resolve the release commit.'
    }
    $value.Trim()
}

function Get-ToolVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$Arguments = @('--version')
    )
    if (-not (Get-Command $Executable -ErrorAction SilentlyContinue)) { return $null }
    try {
        ((& $Executable @Arguments 2>&1 | Select-Object -First 1) | Out-String).Trim()
    } catch {
        $null
    }
}

function Invoke-Native {
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
        if ($LASTEXITCODE -ne 0) { throw "$Executable exited with code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][ValidateSet('passed', 'failed', 'skipped')][string]$Status,
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

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "[RUN] $Id ($Platform)"
    try {
        & $Action
        $watch.Stop()
        Add-Result $Id $Platform passed $watch.Elapsed.TotalSeconds 'Completed successfully.'
        Write-Host "[PASS] $Id"
    } catch {
        $watch.Stop()
        Add-Result $Id $Platform failed $watch.Elapsed.TotalSeconds $_.Exception.Message
        Write-Host "[FAIL] ${Id}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Skip-Step {
    param([string]$Id, [string]$Platform, [string]$Reason)
    Add-Result $Id $Platform skipped 0 $Reason
    Write-Host "[SKIP] ${Id}: $Reason" -ForegroundColor Yellow
}

function Add-Artifact {
    param([string]$Id, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Release artifact is missing: $Path"
    }
    $file = Get-Item -LiteralPath $Path
    $artifacts.Add([pscustomobject][ordered]@{
        id = $Id
        path = [IO.Path]::GetRelativePath($repositoryRoot, $file.FullName).Replace('\', '/')
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}

function Resolve-AndroidDevice {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { return $null }
    $devices = @(
        & adb devices 2>$null |
            Select-Object -Skip 1 |
            ForEach-Object { ($_ -split '\s+')[0] } |
            Where-Object { $_ }
    )
    if ($Device) { return $devices | Where-Object { $_ -eq $Device } | Select-Object -First 1 }
    $devices | Select-Object -First 1
}

function Assert-AndroidProcess {
    param([string]$DeviceId)
    Start-Sleep -Seconds 3
    $pidValue = (& adb -s $DeviceId shell pidof org.torchat.mobile 2>$null | Out-String).Trim()
    if (-not $pidValue) { throw 'Torca Android process did not remain alive after launch.' }
}

function Start-WindowsSmoke {
    param([string]$Executable, [string]$Profile)
    $process = Start-Process -FilePath $Executable -PassThru -WindowStyle Hidden `
        -Environment @{ APPDATA = $Profile; LOCALAPPDATA = $Profile }
    Start-Sleep -Seconds 5
    if ($process.HasExited -and $process.ExitCode -ne 0) {
        throw "Torca Windows client exited with code $($process.ExitCode)."
    }
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    }
}

$commit = Get-Commit
$buildsPlatformArtifact = $Target -in @('all', 'android', 'windows')
if ($buildsPlatformArtifact -and
    ([string]::IsNullOrWhiteSpace($UpdateKeyId) -or
     [string]::IsNullOrWhiteSpace($UpdatePublicKey))) {
    throw 'Platform release builds require UpdateKeyId and UpdatePublicKey.'
}
try {
    $decodedPublicKey = [Convert]::FromBase64String($UpdatePublicKey)
    if ($buildsPlatformArtifact -and $decodedPublicKey.Length -ne 32) {
        throw 'UpdatePublicKey must be a base64-encoded 32-byte Ed25519 public key.'
    }
} catch {
    if ($buildsPlatformArtifact) { throw 'UpdatePublicKey is not valid base64 Ed25519 key material.' }
}

$dartDefines = @(
    "--dart-define=TORCA_VERSION=$($release.version)",
    "--dart-define=TORCA_BUILD=$($release.build)",
    "--dart-define=TORCA_CHANNEL=$($release.channel)",
    "--dart-define=TORCA_COMMIT=$commit"
)
if (-not [string]::IsNullOrWhiteSpace($UpdateKeyId)) {
    $dartDefines += "--dart-define=TORCA_UPDATE_KEY_ID=$UpdateKeyId"
}
if (-not [string]::IsNullOrWhiteSpace($UpdatePublicKey)) {
    $dartDefines += "--dart-define=TORCA_UPDATE_PUBLIC_KEY=$UpdatePublicKey"
}

$runCore = $Target -in @('all', 'core')
$runAndroid = $Target -in @('all', 'android')
$runWindows = $Target -in @('all', 'windows')

if ($runCore) {
    Invoke-Step 'release-version' 'core' {
        & (Join-Path $PSScriptRoot 'check-release-version.ps1') -RepositoryRoot $repositoryRoot
    }
    Invoke-Step 'release-policy' 'core' {
        & (Join-Path $repositoryRoot 'scripts/internal/check-release-policy.ps1') -RepositoryRoot $repositoryRoot
    }
    Invoke-Step 'runtime-contract' 'core' {
        & (Join-Path $repositoryRoot 'scripts/internal/check-runtime-contract.ps1') -RepositoryRoot $repositoryRoot
    }
    Invoke-Step 'source-size' 'core' {
        & (Join-Path $repositoryRoot 'scripts/internal/check-source-size.ps1') -RepositoryRoot $repositoryRoot
    }
    Invoke-Step 'rust-format' 'core' { Invoke-Native cargo @('fmt', '--all', '--', '--check') $repositoryRoot }
    Invoke-Step 'runtime-tests' 'core' { Invoke-Native cargo @('test', '-p', 'torchat-runtime') $repositoryRoot }
    Invoke-Step 'engine-tests' 'core' { Invoke-Native cargo @('test', '-p', 'torchat-client-engine') $repositoryRoot }
    Invoke-Step 'ffi-tests' 'core' { Invoke-Native cargo @('test', '-p', 'torchat-client-engine-ffi') $repositoryRoot }
    Invoke-Step 'rust-clippy' 'core' {
        Invoke-Native cargo @(
            'clippy', '-p', 'torchat-runtime', '-p', 'torchat-client-engine',
            '-p', 'torchat-client-engine-ffi', '--all-targets', '--', '-D', 'warnings'
        ) $repositoryRoot
    }
    Invoke-Step 'rust-dependency-policy' 'core' { Invoke-Native cargo @('deny', 'check') $repositoryRoot }
    Invoke-Step 'diagnostic-sanitization' 'core' {
        & (Join-Path $repositoryRoot 'scripts/tests/test-diagnostic-sanitization.ps1')
        if ($LASTEXITCODE -notin @(0, $null)) { throw "Diagnostic sanitization exited with code $LASTEXITCODE." }
    }
    foreach ($entry in @(
        @{ id = 'flutter-mobile'; path = 'apps/mobile/flutter' },
        @{ id = 'flutter-desktop'; path = 'apps/desktop/flutter' }
    )) {
        $workingDirectory = Join-Path $repositoryRoot $entry.path
        Invoke-Step "$($entry.id)-format" $entry.id {
            Invoke-Native dart @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test') $workingDirectory
        }
        Invoke-Step "$($entry.id)-analyze" $entry.id {
            Invoke-Native flutter @('pub', 'get') $workingDirectory
            Invoke-Native flutter @('analyze') $workingDirectory
        }
        Invoke-Step "$($entry.id)-tests" $entry.id { Invoke-Native flutter @('test') $workingDirectory }
    }
}

if ($runAndroid) {
    $mobileRoot = Join-Path $repositoryRoot 'apps/mobile/flutter'
    Invoke-Step 'android-release-build' 'android' {
        Invoke-Native flutter @('pub', 'get') $mobileRoot
        Invoke-Native flutter (@('build', 'apk', '--release') + $dartDefines) $mobileRoot
        if ($BuildAndroidBundle) {
            Invoke-Native flutter (@('build', 'appbundle', '--release') + $dartDefines) $mobileRoot
        }
    }
    $apk = Join-Path $mobileRoot 'build/app/outputs/flutter-apk/app-release.apk'
    if (Test-Path -LiteralPath $apk) { Add-Artifact 'android-apk' $apk }
    $bundle = Join-Path $mobileRoot 'build/app/outputs/bundle/release/app-release.aab'
    if ($BuildAndroidBundle -and (Test-Path -LiteralPath $bundle)) { Add-Artifact 'android-aab' $bundle }

    $resolvedDevice = Resolve-AndroidDevice
    $deviceSteps = @('android-clean-install-smoke', 'android-upgrade-preserves-data', 'android-cold-start-recovery')
    if ($resolvedDevice) {
        Invoke-Step 'android-clean-install-smoke' 'android' {
            & adb -s $resolvedDevice uninstall org.torchat.mobile 2>$null | Out-Null
            & adb -s $resolvedDevice install $apk | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'adb install failed.' }
            & adb -s $resolvedDevice shell monkey -p org.torchat.mobile 1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Android launch failed.' }
            Assert-AndroidProcess $resolvedDevice
        }
        Invoke-Step 'android-upgrade-preserves-data' 'android' {
            & adb -s $resolvedDevice shell run-as org.torchat.mobile sh -c `
                'mkdir -p files && echo torca-release-upgrade-marker > files/torca-release-upgrade-marker'
            if ($LASTEXITCODE -ne 0) { throw 'Unable to seed Android upgrade marker.' }
            & adb -s $resolvedDevice install -r $apk | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'adb upgrade failed.' }
            $marker = (& adb -s $resolvedDevice shell run-as org.torchat.mobile `
                cat files/torca-release-upgrade-marker 2>$null | Out-String).Trim()
            if ($marker -ne 'torca-release-upgrade-marker') {
                throw 'Android application data was not preserved across upgrade.'
            }
        }
        Invoke-Step 'android-cold-start-recovery' 'android' {
            & adb -s $resolvedDevice shell am force-stop org.torchat.mobile | Out-Null
            & adb -s $resolvedDevice shell monkey -p org.torchat.mobile 1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Android cold start failed.' }
            Assert-AndroidProcess $resolvedDevice
        }
    } else {
        $reason = 'No authorized Android device is available.'
        foreach ($step in $deviceSteps) {
            if ($RequirePlatforms) { Add-Result $step android failed 0 $reason } else { Skip-Step $step android $reason }
        }
    }
}

if ($runWindows) {
    $desktopRoot = Join-Path $repositoryRoot 'apps/desktop/flutter'
    $windowsSteps = @('windows-release-build', 'windows-clean-profile-smoke', 'windows-profile-restart-preserves-data')
    if ($env:OS -eq 'Windows_NT') {
        Invoke-Step 'windows-release-build' 'windows' {
            Invoke-Native flutter @('config', '--enable-windows-desktop') $desktopRoot
            Invoke-Native flutter @('pub', 'get') $desktopRoot
            Invoke-Native flutter (@('build', 'windows', '--release') + $dartDefines) $desktopRoot
        }
        $executable = Join-Path $desktopRoot 'build/windows/x64/runner/Release/torchat_desktop.exe'
        if (Test-Path -LiteralPath $executable) { Add-Artifact 'windows-executable' $executable }
        Invoke-Step 'windows-clean-profile-smoke' 'windows' {
            $profile = Join-Path ([IO.Path]::GetTempPath()) ("torca-profile-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $profile | Out-Null
            try { Start-WindowsSmoke $executable $profile }
            finally { Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Invoke-Step 'windows-profile-restart-preserves-data' 'windows' {
            $profile = Join-Path ([IO.Path]::GetTempPath()) ("torca-upgrade-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $profile | Out-Null
            try {
                Start-WindowsSmoke $executable $profile
                $marker = Join-Path $profile 'torca-release-upgrade-marker.txt'
                'torca-release-upgrade-marker' | Set-Content -LiteralPath $marker -Encoding UTF8
                Start-WindowsSmoke $executable $profile
                if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'torca-release-upgrade-marker') {
                    throw 'Windows profile was not preserved across restart.'
                }
            } finally {
                Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        $reason = 'Windows release validation requires a Windows host.'
        foreach ($step in $windowsSteps) {
            if ($RequirePlatforms) { Add-Result $step windows failed 0 $reason } else { Skip-Step $step windows $reason }
        }
    }
}

if (-not $OutputPath) {
    $outputRoot = Join-Path $repositoryRoot '.torca/release'
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $OutputPath = Join-Path $outputRoot "torca-$($release.version)-matrix-$stamp.json"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
$failed = @($results | Where-Object status -eq 'failed')
$skipped = @($results | Where-Object status -eq 'skipped')
$report = [ordered]@{
    schema = 2
    product = $release.product
    version = $release.version
    build = [int]$release.build
    channel = $release.channel
    updateKeyId = $UpdateKeyId
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    commit = $commit
    host = [ordered]@{
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershell = $PSVersionTable.PSVersion.ToString()
    }
    tools = [ordered]@{
        rustc = Get-ToolVersion -Executable rustc
        cargo = Get-ToolVersion -Executable cargo
        flutter = Get-ToolVersion -Executable flutter
        dart = Get-ToolVersion -Executable dart
        adb = Get-ToolVersion -Executable adb -Arguments @('version')
    }
    target = $Target
    requirePlatforms = [bool]$RequirePlatforms
    passed = $failed.Count -eq 0 -and (-not $RequirePlatforms -or $skipped.Count -eq 0)
    summary = [ordered]@{
        passed = @($results | Where-Object status -eq 'passed').Count
        failed = $failed.Count
        skipped = $skipped.Count
    }
    artifacts = @($artifacts)
    steps = @($results)
    manual = @($matrix.manual)
}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($OutputPath, ($report | ConvertTo-Json -Depth 12), $utf8)
Write-Host "Torca release report: $OutputPath"
if (-not $report.passed) { exit 1 }
