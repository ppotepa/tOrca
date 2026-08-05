[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$ArtifactBaseUrl,
    [Parameter(Mandatory = $true)][string]$SigningPrivateKey,
    [Parameter(Mandatory = $true)][string]$SigningKeyId,
    [string]$ReleaseNotesUrl,
    [string]$MinimumSupportedVersion = '0.1.0',
    [switch]$Mandatory,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$ArtifactDirectory = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
$SigningPrivateKey = (Resolve-Path -LiteralPath $SigningPrivateKey).Path
if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    throw 'OpenSSL is required to sign the Torca update manifest.'
}
if ($ArtifactBaseUrl -notmatch '^https://[^\s]+/?$' -and
    $ArtifactBaseUrl -notmatch '^http://[a-z2-7]{56}\.onion(?::[0-9]+)?(?:/[^\s]*)?/?$') {
    throw 'ArtifactBaseUrl must be HTTPS or an explicit v3 onion HTTP URL.'
}

$release = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'release/version.json') -Raw |
    ConvertFrom-Json
$commit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
    throw 'Unable to resolve the release commit.'
}

$base = $ArtifactBaseUrl.TrimEnd('/')
$artifacts = [System.Collections.Generic.List[object]]::new()
foreach ($file in Get-ChildItem -LiteralPath $ArtifactDirectory -File | Sort-Object Name) {
    $kind = switch -Regex ($file.Name) {
        '\.apk$' { 'apk'; break }
        '\.aab$' { 'aab'; break }
        'windows.*\.zip$' { 'windows-zip'; break }
        default { continue }
    }
    $platform = if ($kind -in @('apk', 'aab')) { 'android' } else { 'windows' }
    $architecture = if ($platform -eq 'windows') { 'x64' } else { 'multi' }
    $artifacts.Add([pscustomobject][ordered]@{
        platform = $platform
        architecture = $architecture
        kind = $kind
        fileName = $file.Name
        url = "$base/$([uri]::EscapeDataString($file.Name))"
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}
if ($artifacts.Count -eq 0) {
    throw "No distributable Torca artifacts were found in $ArtifactDirectory"
}

$payload = [ordered]@{
    schema = 1
    product = 'Torca'
    version = $release.version
    build = [int]$release.build
    channel = $release.channel
    commit = $commit
    publishedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    minimumSupportedVersion = $MinimumSupportedVersion
    mandatory = [bool]$Mandatory
    releaseNotesUrl = if ([string]::IsNullOrWhiteSpace($ReleaseNotesUrl)) { $null } else { $ReleaseNotesUrl }
    artifacts = @($artifacts)
}
$payloadJson = $payload | ConvertTo-Json -Depth 10 -Compress
$utf8 = [Text.UTF8Encoding]::new($false)
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("torca-update-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
try {
    $payloadPath = Join-Path $temporaryRoot 'payload.json'
    $signaturePath = Join-Path $temporaryRoot 'signature.bin'
    [IO.File]::WriteAllText($payloadPath, $payloadJson, $utf8)
    & openssl pkeyutl -sign -rawin -inkey $SigningPrivateKey -in $payloadPath -out $signaturePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) {
        throw 'OpenSSL failed to sign the Torca update manifest.'
    }

    $envelope = [ordered]@{
        schema = 1
        algorithm = 'ed25519'
        keyId = $SigningKeyId
        payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($payloadPath))
        signature = [Convert]::ToBase64String([IO.File]::ReadAllBytes($signaturePath))
    }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path $ArtifactDirectory 'torca-update-manifest.json'
    }
    $outputDirectory = Split-Path -Parent $OutputPath
    if ($outputDirectory) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }
    [IO.File]::WriteAllText(
        $OutputPath,
        ($envelope | ConvertTo-Json -Depth 10),
        $utf8
    )
    Write-Host "Torca signed update manifest: $OutputPath"
} finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
