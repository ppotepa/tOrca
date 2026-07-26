[CmdletBinding()]
param(
    [switch]$NoCache,
    [switch]$SkipChecks,
    [switch]$SkipMobileBuild
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$startScript = Join-Path $PSScriptRoot "start-dev.ps1"
$mobileRoot = Join-Path $repoRoot "apps\mobile"
. (Join-Path $PSScriptRoot "internal\dev-config.ps1")

function Assert-Tool {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' is not available in PATH."
    }
}

Assert-Tool docker
Assert-Tool cargo
if (-not $SkipMobileBuild) { Assert-Tool flutter }
Assert-Tool curl.exe

Push-Location $repoRoot
try {
    if (-not $SkipChecks) {
        Write-Host "[torchat] Checking and testing Rust workspace..."
        cargo fmt --all -- --check
        if ($LASTEXITCODE -ne 0) { throw "cargo fmt check failed." }
        cargo test --workspace
        if ($LASTEXITCODE -ne 0) { throw "Rust workspace tests failed." }
    }

    if (-not $SkipMobileBuild) {
        Write-Host "[torchat] Resolving, checking and building Flutter Android..."
        Push-Location $mobileRoot
        try {
            flutter pub get
            if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }
            if (-not $SkipChecks) {
                flutter analyze
                if ($LASTEXITCODE -ne 0) { throw "Flutter analysis failed." }
                flutter test
                if ($LASTEXITCODE -ne 0) { throw "Flutter tests failed." }
            }
            flutter build apk --debug
            if ($LASTEXITCODE -ne 0) { throw "Flutter debug APK build failed." }
        } finally {
            Pop-Location
        }
    }

    Write-Host "[torchat] Rebuilding and recreating the Docker development stack..."
    & $startScript -Rebuild -ForceRecreate -NoCache:$NoCache
    if ($LASTEXITCODE -ne 0) { throw "Development Docker rebuild failed." }

    Import-TorChatDevConfig $repoRoot
    Write-Host "[torchat] Verifying the public endpoint through Tor..."
    $onionHealth = $null
    for ($attempt = 1; $attempt -le 45; $attempt++) {
        $savedErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $response = & curl.exe --fail --silent --show-error --max-time 10 `
            --socks5-hostname 127.0.0.1:9050 "$($env:TORCHAT_ONION_URL)/health" 2>$null
        $curlExitCode = $LASTEXITCODE
        $ErrorActionPreference = $savedErrorActionPreference
        if ($curlExitCode -eq 0) {
            $onionHealth = $response | ConvertFrom-Json
            if ($onionHealth.status -eq "ok") { break }
        }
        Start-Sleep -Seconds 2
    }
    if ($onionHealth.status -ne "ok") {
        throw "Onion healthcheck did not become ready: $($env:TORCHAT_ONION_URL)"
    }

    Write-Host ""
    Write-Host "[torchat] Full development rebuild completed."
    Write-Host "[torchat] Onion: $env:TORCHAT_ONION_URL"
    Write-Host "[torchat] Android APK: apps\mobile\build\app\outputs\flutter-apk\app-debug.apk"
    Write-Host "[torchat] Next: .\scripts\deploy-android.ps1 -SkipCoreBuild"
    Write-Host "[torchat] Next: .\scripts\run-desktop.ps1 -SkipServer"
} finally {
    Pop-Location
}
