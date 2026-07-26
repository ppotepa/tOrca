param([Parameter(Mandatory = $true)][string]$RepoRoot)

$ErrorActionPreference = "Stop"
$manifestPath = Join-Path $RepoRoot "infra\config\desktop-tor-packages.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if ($architecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
    throw "Embedded Tor currently supports x86_64 desktop only (detected: $architecture)."
}
$platform = if ($IsLinux) { "linux-x86_64" } else { "windows-x86_64" }
$package = $manifest.packages.$platform
if (-not $package) { throw "No embedded Tor package for $platform." }

$cacheRoot = Join-Path $RepoRoot "tmp\tools\tor\$($manifest.version)\$platform"
$archive = Join-Path $cacheRoot "tor-expert-bundle.tar.gz"
$extractRoot = Join-Path $cacheRoot "bundle"
$binary = Join-Path $extractRoot ($package.binary -replace '/', [IO.Path]::DirectorySeparatorChar)
New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null

if (-not (Test-Path -LiteralPath $archive)) {
    Write-Host "[torchat] Downloading Tor Expert Bundle $($manifest.version) for $platform..."
    Invoke-WebRequest -Uri $package.url -OutFile $archive
}
$actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if ($actualHash -ne $package.sha256) {
    throw "Tor package checksum mismatch. Expected $($package.sha256), got $actualHash."
}
if (-not (Test-Path -LiteralPath $binary)) {
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    tar -xf $archive -C $extractRoot
    if ($LASTEXITCODE -ne 0) { throw "Could not extract Tor Expert Bundle." }
}
if (-not (Test-Path -LiteralPath $binary)) {
    throw "Tor executable is missing after extraction: $binary"
}
if ($IsLinux) { chmod +x $binary }

[pscustomobject]@{
    Binary = (Resolve-Path -LiteralPath $binary).Path
    DataDirectory = (Join-Path $RepoRoot "tmp\desktop-tor-data")
    Version = $manifest.tor_version
}
